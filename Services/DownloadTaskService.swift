import Combine
import Foundation

// MARK: - Static image download presentation
@MainActor
class DownloadTaskService: ObservableObject {
  static let shared = DownloadTaskService()

  @Published var tasks: [DownloadTask] = []
  /// Presentation-only revision used when toast suppression changes without a
  /// transfer-state mutation.
  @Published private(set) var toastPresentationRevision = 0

  private let userDefaultsKey = "download_tasks"
  private var saveTask: Task<Void, Never>?
  private var lastProgressUpdateTimes: [String: Date] = [:]
  private let progressUpdateMinInterval: TimeInterval = 0.15
  private var suppressedToastTaskIDs = Set<String>()

  // MARK: - Active Download Tasks Management

  private init() {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.observe { [weak self] snapshot in
        guard let bytes = snapshot["downloads"] as? Data,
          let tasks = try? LegacyRecordReader.read(DownloadTask.self, from: bytes).records
        else { return }
        self?.tasks = tasks
      }
    }
    // ⚠️ 不在 init 中读 UserDefaults，避免 _CFXPreferences 递归栈溢出
    // 任务列表通过 restoreSavedTasks() 延迟恢复
  }

  /// 延迟恢复保存的下载任务（必须在 applicationDidFinishLaunching 中调用）
  func restoreSavedTasks() {
    guard BackgroundRuntimeRole.isHelper else { return }
    loadTasks()
  }

  // MARK: - Task Management

  func addTask(wallpaper: Wallpaper) -> DownloadTask {
    upsertTask(DownloadTask(wallpaper: wallpaper))
  }

  func updateWallpaper(_ wallpaper: Wallpaper, id: String? = nil) {
    let targetID = id ?? "wallpaper.\(wallpaper.id)"
    guard let index = tasks.firstIndex(where: { $0.id == targetID }) else { return }
    objectWillChange.send()
    tasks[index].wallpaper = wallpaper
    tasks[index].lastUpdatedAt = .now
    persistTasks()
  }

  private func upsertTask(_ task: DownloadTask) -> DownloadTask {
    objectWillChange.send()
    if let index = tasks.firstIndex(where: { $0.id == task.id }) {
      tasks[index] = task
    } else {
      tasks.insert(task, at: 0)
    }
    persistTasks()
    return task
  }

  func pauseTask(id: String) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send("download.pauseTask", ["id": id])
      return
    }

    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

    PersistentDownloadQueueService.shared.pause(jobID: id)

    // 取消正在进行的下载任务（但保留进度）

    objectWillChange.send()
    tasks[index].status = .paused
    tasks[index].lastUpdatedAt = .now
    persistTasks()

    print("[DownloadTaskService] Task \(id) paused")
  }

  func resumeTask(id: String) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send("download.resumeTask", ["id": id])
      return
    }

    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    guard
      tasks[index].status == .paused
        || tasks[index].status == .failed
    else { return }

    objectWillChange.send()
    tasks[index].status = .pending
    tasks[index].completedAt = nil
    tasks[index].lastUpdatedAt = .now
    persistTasks()

    PersistentDownloadQueueService.shared.resume(jobID: id)
    print("[DownloadTaskService] Task \(id) resumed")
  }

  func cancelTask(id: String) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send("download.cancelTask", ["id": id])
      return
    }

    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

    PersistentDownloadQueueService.shared.cancel(jobID: id)

    // 取消正在进行的下载任务

    objectWillChange.send()
    tasks[index].status = .cancelled
    tasks[index].completedAt = Date()
    tasks[index].lastUpdatedAt = .now
    lastProgressUpdateTimes.removeValue(forKey: id)
    let removedSuppression = suppressedToastTaskIDs.remove(id) != nil
    persistTasks()
    if removedSuppression { publishToastPresentationChange() }

    print("[DownloadTaskService] Task \(id) cancelled")
  }

  /// 取消所有活动的下载
  func cancelAllActiveDownloads() {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send("download.cancelAll")
      return
    }

    let activeTaskIDs =
      tasks
      .filter(\.isRunning)
      .map(\.id)
    for id in activeTaskIDs {
      cancelTask(id: id)
    }
  }

  func removeTask(id: String) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send("download.removeTask", ["id": id])
      return
    }

    objectWillChange.send()
    tasks.removeAll { $0.id == id }
    lastProgressUpdateTimes.removeValue(forKey: id)
    suppressedToastTaskIDs.remove(id)
    persistTasks()
  }

  func task(for id: String) -> DownloadTask? {
    tasks.first { $0.id == id }
  }

  func task(for itemID: String, kind: DownloadTaskKind) -> DownloadTask? {
    tasks.first { $0.kind == kind && $0.itemID == itemID }
  }

  func markToastSuppressed(for id: String) {
    guard suppressedToastTaskIDs.insert(id).inserted else { return }
    publishToastPresentationChange()
  }

  /// 批量抑制所有正在运行的下载任务的 toast（"后台继续"按钮使用）
  func suppressAllRunningToasts() {
    var changed = false
    for task in tasks where task.isRunning {
      changed = suppressedToastTaskIDs.insert(task.id).inserted || changed
    }
    if changed { publishToastPresentationChange() }
  }

  func clearToastSuppression(for id: String) {
    guard suppressedToastTaskIDs.remove(id) != nil else { return }
    publishToastPresentationChange()
  }

  func restoreAllRunningToasts() {
    let runningIDs = Set(tasks.filter(\.isRunning).map(\.id))
    guard !runningIDs.isEmpty else { return }
    let before = suppressedToastTaskIDs.count
    suppressedToastTaskIDs.subtract(runningIDs)
    if suppressedToastTaskIDs.count != before {
      publishToastPresentationChange()
    }
  }

  func isToastSuppressed(for id: String) -> Bool {
    suppressedToastTaskIDs.contains(id)
  }

  private func publishToastPresentationChange() {
    toastPresentationRevision &+= 1
  }

  func updateProgress(id: String, progress: Double) {
    guard progress.isFinite else { return }
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    let currentProgress = tasks[index].progress
    // 一个 Job 内的多阶段回调可能延迟到达，UI 进度只能单调递增。
    let clampedProgress = max(currentProgress, min(max(progress, 0.0), 1.0))

    // 防抖优化：如果进度变化小于 0.5% 且不是开始/结束，跳过更新
    let isStart = currentProgress == 0 && clampedProgress > 0
    let isComplete = clampedProgress >= 1.0
    if abs(clampedProgress - currentProgress) < 0.005 && !isStart && !isComplete {
      return
    }

    // 节流优化：限制高频进度发布，减少主线程重绘压力（约 6.7fps）
    let now = Date()
    if !isStart && !isComplete,
      let lastTime = lastProgressUpdateTimes[id],
      now.timeIntervalSince(lastTime) < progressUpdateMinInterval
    {
      return
    }

    objectWillChange.send()
    tasks[index].progress = clampedProgress
    if tasks[index].status != .paused {
      tasks[index].status = .downloading
    }
    tasks[index].lastUpdatedAt = .now
    lastProgressUpdateTimes[id] = now
    schedulePersistTasks()
  }

  func markCompleted(id: String) {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    objectWillChange.send()
    tasks[index].status = .completed
    tasks[index].progress = 1.0
    tasks[index].completedAt = Date()
    tasks[index].lastUpdatedAt = .now
    lastProgressUpdateTimes.removeValue(forKey: id)
    let removedSuppression = suppressedToastTaskIDs.remove(id) != nil
    persistTasks()
    if removedSuppression { publishToastPresentationChange() }
    scheduleVisibilityRefresh()
  }

  func markDownloading(id: String) {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    objectWillChange.send()
    tasks[index].status = .downloading
    tasks[index].lastUpdatedAt = .now
    persistTasks()
  }

  func markPending(id: String) {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    objectWillChange.send()
    tasks[index].status = .pending
    tasks[index].completedAt = nil
    tasks[index].lastUpdatedAt = .now
    persistTasks()
  }

  func markPaused(id: String) {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    objectWillChange.send()
    tasks[index].status = .paused
    tasks[index].lastUpdatedAt = .now
    persistTasks()
  }

  func markCancelled(id: String) {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    tasks[index].status = .cancelled
    tasks[index].lastUpdatedAt = .now
    persistTasks()
  }

  func markFailed(id: String) {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    objectWillChange.send()
    tasks[index].status = .failed
    tasks[index].completedAt = Date()
    tasks[index].lastUpdatedAt = .now
    lastProgressUpdateTimes.removeValue(forKey: id)
    let removedSuppression = suppressedToastTaskIDs.remove(id) != nil
    persistTasks()
    if removedSuppression { publishToastPresentationChange() }
  }

  // MARK: - Persistence

  /// 后台持久化队列，避免 JSON 编码 + UserDefaults 写入阻塞主线程
  private static let persistQueue = DispatchQueue(
    label: "com.waifux.downloadTask.persist", qos: .utility)

  func flushPendingPersistence() {
    saveTask?.cancel()
    persistTasks()
    Self.persistQueue.sync {}
  }

  private func persistTasks() {
    saveTask?.cancel()
    // ⚡ 在主线程捕获数据副本，后台编码写入
    let currentTasks = tasks
    let key = userDefaultsKey
    Self.persistQueue.async {
      if let encoded = try? JSONEncoder().encode(currentTasks) {
        WaifuXPreferences.shared.set(encoded, forKey: key)
      }
    }
  }

  private func schedulePersistTasks() {
    saveTask?.cancel()
    saveTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
      guard !Task.isCancelled else { return }
      persistTasks()
    }
  }

  private func scheduleVisibilityRefresh() {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_900_000_000)  // 1.9s
      objectWillChange.send()
    }
  }

  private func loadTasks() {
    if let data = WaifuXPreferences.shared.data(forKey: userDefaultsKey),
      let loadedTasks = try? LegacyRecordReader.read(DownloadTask.self, from: data).records
    {
      if WaifuXPreferences.shared.data(forKey: "wallhaven_static_backup_download_tasks_v1") == nil {
        WaifuXPreferences.shared.set(data, forKey: "wallhaven_static_backup_download_tasks_v1")
      }
      // Reset interrupted presentation state; the persistent queue owns resumption.
      tasks = loadedTasks.map { task in
        var modifiedTask = task
        if task.status == .downloading || task.status == .pending {
          modifiedTask.status = .paused
          modifiedTask.lastUpdatedAt = .now
        }
        return modifiedTask
      }
    }
  }

  // MARK: - Statistics

  var activeTasks: [DownloadTask] {
    tasks.filter {
      $0.status == .downloading
        || $0.status == .pending
        || $0.status == .paused
    }
  }

  var runningTasks: [DownloadTask] {
    tasks
      .filter(\.isRunning)
      .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
  }

  var libraryVisibleTasks: [DownloadTask] {
    tasks
      .filter(\.shouldAppearInLibrary)
      .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
  }

  var latestOverlayTask: DownloadTask? {
    if let runningTask = runningTasks.first {
      return runningTask
    }

    return
      tasks
      .filter { $0.status == .completed }
      .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
      .first(where: { Date().timeIntervalSince($0.lastUpdatedAt) < 1.8 })
  }

  var compactOverlayTask: DownloadTask? {
    tasks
      .filter { $0.isRunning && suppressedToastTaskIDs.contains($0.id) }
      .sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
      }
      .first
  }

  var completedTasks: [DownloadTask] {
    tasks.filter { $0.status == .completed }
  }

  var failedTasks: [DownloadTask] {
    tasks.filter { $0.status == .failed }
  }

  var latestTask: DownloadTask? {
    tasks.max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt })
  }
}

// MARK: - 统一可恢复下载执行队列

/// 所有下载入口共用的可执行事实源。`DownloadTaskService` 仅保留 UI 快照和历史；
/// 是否能在重启后恢复、当前是否占用下载槽位，一律以这里的 Job 为准。
@MainActor
final class PersistentDownloadQueueService {
  static let shared = PersistentDownloadQueueService()

  private enum Payload: Codable {
    case wallpaper(Wallpaper)
    var wallpaper: Wallpaper {
      switch self {
      case .wallpaper(let image): return image
      }
    }
    var taskID: String { "wallpaper.\(wallpaper.id)" }
    var itemID: String { wallpaper.id }
    var isSupported: Bool {
      WallhavenContentPolicy.isWallpaperRecord(
        id: wallpaper.id, detailURL: wallpaper.url, imagePath: wallpaper.path)
    }
    @MainActor var isAlreadyDownloaded: Bool {
      WallpaperLibraryService.shared.isDownloaded(wallpaper)
    }
  }

  private enum State: String, Codable {
    case queued
    case running
    case paused
    case failed
  }

  private enum Source: String, Codable {
    case manual
    case folderRedownload
    case legacyMigration
  }

  private struct Job: Codable, Identifiable {
    let id: String
    var payload: Payload
    var folderID: String?
    var state: State
    var source: Source
    let addedAt: Date
    var updatedAt: Date
    var attemptCount: Int
    var lastError: String?
  }

  private struct Snapshot: Codable {
    let version: Int
    let jobs: [Job]
    enum CodingKeys: String, CodingKey { case version, jobs }
    init(version: Int, jobs: [Job]) {
      self.version = version
      self.jobs = jobs
    }
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      version = try container.decode(Int.self, forKey: .version)
      guard (1...2).contains(version) else { throw CocoaError(.coderInvalidValue) }
      jobs = try LegacyRecordReader.read(Job.self, from: container.superDecoder(forKey: .jobs)) {
        $0.payload.isSupported && $0.id == $0.payload.taskID
      }.records
    }
  }

  private struct ActiveWorker {
    let token: UUID
    let task: Task<Void, Error>
  }

  private enum QueueError: LocalizedError {
    case notConfigured
    case missingResult
    case persistenceFailed

    var errorDescription: String? {
      switch self {
      case .notConfigured: return t("下载队列尚未完成启动配置")
      case .missingResult: return t("下载完成但没有返回本地文件")
      case .persistenceFailed: return t("无法将下载队列保存到本地")
      }
    }
  }

  private let maxConcurrentDownloads = 2
  private var jobs: [Job] = []
  private var activeWorkers: [String: ActiveWorker] = [:]
  private var completionWaiters: [String: [CheckedContinuation<URL?, Error>]] = [:]
  /// 覆盖“共享 Job 刚结束，新调用方尚未来得及挂起”的竞态窗口。
  private var terminalResults: [String: Result<URL?, Error>] = [:]
  private var terminalResultOrder: [String] = []
  private var didRestore = false
  var hasExecutableWork: Bool {
    !activeWorkers.isEmpty || jobs.contains { $0.state == .queued }
  }

  private weak var wallpaperViewModel: WallpaperViewModel?

  private init() {}

  /// 应用启动时注入长期存活的执行器，并恢复所有未完成 Job。
  var hasPersistedWork: Bool {
    guard let bytes = try? Data(contentsOf: checkpointURL),
      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: bytes)
    else { return false }
    return !snapshot.jobs.isEmpty
  }

  func submitWallpaper(_ wallpaper: Wallpaper, folderID: String?) throws -> String {
    let id = try upsert(
      payload: .wallpaper(wallpaper), folderID: folderID, source: .manual, persistImmediately: true)
    pump()
    return id
  }

  func waitForRemoteCompletion(id: String) async throws -> URL? {
    try await waitForCompletion(of: id)
  }

  func configure(wallpaperViewModel: WallpaperViewModel) {
    guard BackgroundRuntimeRole.isHelper else { return }
    self.wallpaperViewModel = wallpaperViewModel
    if !didRestore {
      didRestore = true
      restoreAndMigrateJobs()
    }
    pump()
  }

  func enqueueWallpaperAndWait(
    _ wallpaper: Wallpaper,
    folderID: String?,
    using viewModel: WallpaperViewModel
  ) async throws {
    if BackgroundRuntimeRole.isRemoteUI {
      let result = try await BackgroundRuntimeBridge.request(
        "download.submitWallpaper",
        ["wallpaper": try JSONEncoder().encode(wallpaper), "folderID": folderID])
      _ = try await BackgroundRuntimeBridge.request("download.wait", ["id": result["id"]])
      try await BackgroundRuntimeBridge.refreshLibrarySnapshot()
      return
    }

    wallpaperViewModel = viewModel
    let id = try upsert(
      payload: .wallpaper(wallpaper),
      folderID: folderID,
      source: .manual,
      persistImmediately: true
    )
    _ = try await waitForCompletion(of: id)
  }

  func pause(jobID: String) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send("download.pause", ["id": jobID])
      return
    }

    guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
    jobs[index].state = .paused
    jobs[index].updatedAt = .now
    DownloadTaskService.shared.markPaused(id: jobID)
    activeWorkers[jobID]?.task.cancel()
    persistJobs()
  }

  func resume(jobID: String) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send("download.resume", ["id": jobID])
      return
    }

    guard let index = jobs.firstIndex(where: { $0.id == jobID }),
      jobs[index].state == .paused
        || jobs[index].state == .failed
    else {
      return
    }
    jobs[index].state = .queued
    jobs[index].updatedAt = .now
    jobs[index].lastError = nil
    clearTerminalResult(for: jobID)
    DownloadTaskService.shared.markPending(id: jobID)
    persistJobs()
    pump()
  }

  func cancel(jobID: String) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send("download.cancel", ["id": jobID])
      return
    }

    activeWorkers[jobID]?.task.cancel()
    jobs.removeAll { $0.id == jobID }
    DownloadTaskService.shared.markCancelled(id: jobID)
    let result: Result<URL?, Error> = .failure(CancellationError())
    storeTerminalResult(result, for: jobID)
    resumeWaiters(for: jobID, with: result)
    persistJobs()
    pump()
  }

  func retry(_ task: DownloadTask) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send("download.retry", ["task": try? JSONEncoder().encode(task)])
      return
    }

    if jobs.contains(where: { $0.id == task.id }) {
      resume(jobID: task.id)
      return
    }

    let payload: Payload?
    switch task.kind {
    case .wallpaper:
      payload = task.wallpaper.map(Payload.wallpaper)
    }
    guard let payload else { return }
    do {
      _ = try upsert(
        payload: payload,
        folderID: nil,
        source: .manual,
        persistImmediately: true
      )
    } catch {
      DownloadTaskService.shared.markFailed(id: task.id)
      return
    }
    pump()
  }

  func retryAndWait(_ task: DownloadTask) async throws {
    if BackgroundRuntimeRole.isRemoteUI {
      _ = try await BackgroundRuntimeBridge.request(
        "download.retry", ["task": try JSONEncoder().encode(task)])
      _ = try await BackgroundRuntimeBridge.request("download.wait", ["id": task.id])
      return
    }

    retry(task)
    guard jobs.contains(where: { $0.id == task.id }) else {
      throw QueueError.missingResult
    }
    _ = try await waitForCompletion(of: task.id)
  }

  private func waitForCompletion(of jobID: String) async throws -> URL? {
    if let result = terminalResults[jobID] {
      return try result.get()
    }
    guard jobs.contains(where: { $0.id == jobID }) else {
      throw QueueError.missingResult
    }
    return try await withCheckedThrowingContinuation { continuation in
      completionWaiters[jobID, default: []].append(continuation)
      pump()
    }
  }

  @discardableResult
  private func upsert(
    payload: Payload,
    folderID: String?,
    source: Source,
    persistImmediately: Bool,
    updatePresentation: Bool = true
  ) throws -> String {
    guard payload.isSupported else { throw QueueError.missingResult }
    let originalJobs = jobs
    let id = payload.taskID
    let normalizedFolderID = folderID?.trimmingCharacters(in: .whitespacesAndNewlines)
    var shouldResetPresentation = false
    if let index = jobs.firstIndex(where: { $0.id == id }) {
      // 已运行的 worker 持有当时的 Job 快照，不在中途改写路径/参数。
      if jobs[index].state != .running {
        jobs[index].payload = payload
        jobs[index].folderID = normalizedFolderID?.isEmpty == false ? normalizedFolderID : nil
        jobs[index].source = source
      }
      if jobs[index].state == .failed || jobs[index].state == .paused {
        jobs[index].state = .queued
        jobs[index].lastError = nil
        shouldResetPresentation = true
      }
      jobs[index].updatedAt = .now
    } else {
      jobs.append(
        Job(
          id: id,
          payload: payload,
          folderID: normalizedFolderID?.isEmpty == false ? normalizedFolderID : nil,
          state: .queued,
          source: source,
          addedAt: .now,
          updatedAt: .now,
          attemptCount: 0,
          lastError: nil
        )
      )
      shouldResetPresentation = true
    }
    jobs.sort { $0.addedAt < $1.addedAt }
    // 相同下载的多个调用方共享一个 Job；不覆盖正在进展的 UI 快照，
    // 否则进度会被重置为 0 并表现为数字乱跳。
    if persistImmediately && !persistJobs() {
      jobs = originalJobs
      throw QueueError.persistenceFailed
    }
    if shouldResetPresentation {
      clearTerminalResult(for: id)
    }
    if updatePresentation && shouldResetPresentation {
      addPresentationTask(for: payload)
      DownloadTaskService.shared.markPending(id: id)
    }
    return id
  }

  /// 动态 worker pool：任意槽位结束后立即取下一个 FIFO Job。
  private func pump() {
    guard !isStopping, migrationSuspensions.isEmpty, wallpaperViewModel != nil else { return }
    while activeWorkers.count < maxConcurrentDownloads,
      let index = jobs.firstIndex(where: { $0.state == .queued && activeWorkers[$0.id] == nil })
    {
      jobs[index].state = .running
      jobs[index].updatedAt = .now
      jobs[index].attemptCount += 1
      let job = jobs[index]
      DownloadTaskService.shared.markDownloading(id: job.id)
      persistJobs()

      let workerToken = UUID()
      let worker = Task<Void, Error> { @MainActor [weak self] in
        guard let self else { return }
        do {
          let result = try await self.execute(job)
          try Task.checkCancellation()
          self.finish(jobID: job.id, workerToken: workerToken, result: result)
        } catch {
          let failure: Error = Task.isCancelled ? CancellationError() : error
          self.fail(jobID: job.id, workerToken: workerToken, error: failure)
          throw failure
        }
      }
      activeWorkers[job.id] = ActiveWorker(token: workerToken, task: worker)
    }
    NotificationCenter.default.post(name: .backgroundDownloadWorkersChanged, object: nil)
  }

  private func execute(_ job: Job) async throws -> URL? {
    switch job.payload {
    case .wallpaper(let wallpaper):
      guard let wallpaperViewModel else { throw QueueError.notConfigured }
      try await wallpaperViewModel.executeQueuedWallpaperDownload(
        wallpaper,
        folderID: job.folderID,
        taskID: job.id
      )
      return WallpaperLibraryService.shared.localFileURLIfAvailable(for: wallpaper)
    }
  }

  private func finish(jobID: String, workerToken: UUID, result: URL?) {
    guard activeWorkers[jobID]?.token == workerToken else { return }
    activeWorkers.removeValue(forKey: jobID)

    // 先从执行队列移除并补上下一个 Job，再发布当前 Job 的完成状态。
    // 否则 Toast 会先收到“已完成”并启动自动隐藏计时，随后才收到下一个
    // Job 开始，批量下载时就会出现弹窗逐项消失又重新弹出的闪烁。
    jobs.removeAll { $0.id == jobID }
    persistJobs()
    let terminalResult: Result<URL?, Error> = .success(result)
    storeTerminalResult(terminalResult, for: jobID)
    resumeWaiters(for: jobID, with: terminalResult)
    pump()

    // 队列已补位后再标记完成；若没有下一个 Job，这里仍会正常进入
    // 完成态并由 Toast 按原逻辑短暂展示后消失。
    DownloadTaskService.shared.markCompleted(id: jobID)
  }

  private func fail(jobID: String, workerToken: UUID, error: Error) {
    // 取消后同 ID 可能已经重新入队；旧 worker 绝不能删掉新 Job/worker。
    guard activeWorkers[jobID]?.token == workerToken else { return }
    activeWorkers.removeValue(forKey: jobID)

    if isStopping { return }
    guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
      let result: Result<URL?, Error> = .failure(error)
      storeTerminalResult(result, for: jobID)
      resumeWaiters(for: jobID, with: result)
      pump()
      return
    }

    if jobs[index].state == .paused {
      let result: Result<URL?, Error> = .failure(CancellationError())
      storeTerminalResult(result, for: jobID)
      resumeWaiters(for: jobID, with: result)
    } else if error is CancellationError {
      // 用户可能在旧 worker 退出前已点了“继续”。此时 Job 已回到
      // queued，必须保留并由 pump 立即重启，不能被旧 worker 删掉。
      if jobs[index].state != .queued {
        jobs.remove(at: index)
        let result: Result<URL?, Error> = .failure(error)
        storeTerminalResult(result, for: jobID)
        resumeWaiters(for: jobID, with: result)
      }
    } else {
      jobs[index].state = .failed
      jobs[index].updatedAt = .now
      jobs[index].lastError = error.localizedDescription
      DownloadTaskService.shared.markFailed(id: jobID)
      let result: Result<URL?, Error> = .failure(error)
      storeTerminalResult(result, for: jobID)
      resumeWaiters(for: jobID, with: result)
    }
    persistJobs()
    pump()
  }

  private func resumeWaiters(
    for jobID: String,
    with result: Result<URL?, Error>
  ) {
    let waiters = completionWaiters.removeValue(forKey: jobID) ?? []
    for waiter in waiters {
      switch result {
      case .success(let url): waiter.resume(returning: url)
      case .failure(let error): waiter.resume(throwing: error)
      }
    }
  }

  private func storeTerminalResult(_ result: Result<URL?, Error>, for jobID: String) {
    terminalResults[jobID] = result
    terminalResultOrder.removeAll { $0 == jobID }
    terminalResultOrder.append(jobID)
    while terminalResultOrder.count > 100 {
      let expiredID = terminalResultOrder.removeFirst()
      terminalResults.removeValue(forKey: expiredID)
    }
  }

  private func clearTerminalResult(for jobID: String) {
    terminalResults.removeValue(forKey: jobID)
    terminalResultOrder.removeAll { $0 == jobID }
  }

  private func addPresentationTask(for payload: Payload) {
    switch payload {
    case .wallpaper(let wallpaper):
      _ = DownloadTaskService.shared.addTask(wallpaper: wallpaper)
    }
  }

  private func restoreAndMigrateJobs() {
    jobs = loadSnapshotJobs()
    mergeLegacyPresentationTasks()

    var seen = Set<String>()
    jobs =
      jobs
      .sorted { $0.addedAt < $1.addedAt }
      .filter { seen.insert($0.id).inserted && !$0.payload.isAlreadyDownloaded }
      .map { job in
        var restored = job
        if restored.state == .running {
          restored.state = .queued
          restored.updatedAt = .now
        }
        return restored
      }

    for job in jobs {
      addPresentationTask(for: job.payload)
      switch job.state {
      case .queued, .running:
        DownloadTaskService.shared.markPending(id: job.id)
      case .paused:
        DownloadTaskService.shared.markPaused(id: job.id)
      case .failed:
        DownloadTaskService.shared.markFailed(id: job.id)
      }
    }
    _ = persistJobs()
  }

  private var checkpointIsCorrupt = false
  private var isStopping = false
  private var migrationSuspensions = Set<UUID>()

  private func loadSnapshotJobs() -> [Job] {
    let oldURL = checkpointURL.deletingLastPathComponent().appendingPathComponent(
      "download-queue-v2.json")
    let source = FileManager.default.fileExists(atPath: checkpointURL.path) ? checkpointURL : oldURL
    guard FileManager.default.fileExists(atPath: source.path) else { return [] }
    do {
      let data = try Data(contentsOf: source)
      if source == checkpointURL {
        let backup = source.appendingPathExtension("backup-\(UUID().uuidString)")
        try data.write(to: backup, options: .withoutOverwriting)
      }
      return try JSONDecoder().decode(Snapshot.self, from: data).jobs
    } catch {
      if source == checkpointURL { checkpointIsCorrupt = true }
      AppLogger.error(
        .download, "Download queue migration failed; original retained",
        metadata: ["path": source.path, "error": error.localizedDescription])
      return []
    }
  }

  /// Drain file writers without losing waiters or the user's pause state.
  func suspendForLibraryMigration() async -> UUID {
    if !didRestore {
      didRestore = true
      restoreAndMigrateJobs()
    }
    let token = UUID()
    migrationSuspensions.insert(token)
    let workers = activeWorkers
    for (jobID, worker) in workers {
      if let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].state == .running {
        jobs[index].state = .queued
        DownloadTaskService.shared.markPending(id: jobID)
      }
      worker.task.cancel()
    }
    _ = persistJobs()
    for worker in workers.values { _ = await worker.task.result }
    return token
  }
  func resumeAfterLibraryMigration(_ token: UUID) {
    guard migrationSuspensions.remove(token) != nil else { return }
    pump()
  }

  func prepareForProcessTermination() {
    isStopping = true
    for worker in activeWorkers.values { worker.task.cancel() }
    for id in Array(completionWaiters.keys) {
      resumeWaiters(for: id, with: .failure(CancellationError()))
    }
    // Running entries are queued again on next launch. Keep them durable.
    _ = persistJobs()
  }

  private func mergeLegacyPresentationTasks() {
    let unfinished = DownloadTaskService.shared.tasks.filter {
      $0.status == .pending
        || $0.status == .downloading
        || $0.status == .paused
    }
    for task in unfinished where !jobs.contains(where: { $0.id == task.id }) {
      let payload: Payload?
      switch task.kind {
      case .wallpaper:
        payload = task.wallpaper.map(Payload.wallpaper)
      }
      guard let payload, !payload.isAlreadyDownloaded else { continue }
      let restoredState: State
      switch task.status {
      case .paused:
        restoredState = .paused
      default:
        restoredState = .queued
      }
      jobs.append(
        Job(
          id: payload.taskID,
          payload: payload,
          folderID: nil,
          state: restoredState,
          source: .legacyMigration,
          addedAt: task.createdAt,
          updatedAt: .now,
          attemptCount: 0,
          lastError: nil
        )
      )
    }
  }

  @discardableResult
  private func persistJobs() -> Bool {
    guard !checkpointIsCorrupt else { return false }
    do {
      let directory = checkpointURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let data = try JSONEncoder().encode(Snapshot(version: 1, jobs: jobs))
      try data.write(to: checkpointURL, options: .atomic)
      return true
    } catch {
      AppLogger.error(
        .download, "下载队列快照写入失败",
        metadata: [
          "path": checkpointURL.path,
          "error": error.localizedDescription,
        ])
      return false
    }
  }

  private var checkpointURL: URL {
    if BackgroundRuntimeRole.isIsolatedTest,
      let root = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"]
    {
      return URL(fileURLWithPath: root).appendingPathComponent(
        "DownloadQueue/wallhaven-download-queue-v1.json")
    }
    return FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("com.waifux.app", isDirectory: true)
      .appendingPathComponent("DownloadQueue", isDirectory: true)
      .appendingPathComponent("wallhaven-download-queue-v1.json", isDirectory: false)
  }
}

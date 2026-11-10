#if WAIFUX_HELPER
  import AppKit
  import Combine

  @MainActor
  private struct AgentArguments {
    let values: [String: Any]
    func string(_ key: String) throws -> String {
      guard let value = values[key] as? String else { throw CocoaError(.coderValueNotFound) }
      return value
    }
    func optionalString(_ key: String) -> String? { values[key] as? String }
    func bool(_ key: String, default fallback: Bool = false) -> Bool {
      values[key] as? Bool ?? fallback
    }
    func double(_ key: String, default fallback: Double = 0) -> Double {
      (values[key] as? NSNumber)?.doubleValue ?? fallback
    }
    func integer(_ key: String) -> Int { (values[key] as? NSNumber)?.intValue ?? 0 }
    func optionalInteger(_ key: String) -> Int? { (values[key] as? NSNumber)?.intValue }
    func url(_ key: String) throws -> URL {
      guard let url = URL(string: try string(key)), url.isFileURL else {
        throw CocoaError(.fileReadInvalidFileName)
      }
      return url
    }
    func optionalURL(_ key: String) throws -> URL? { values[key] == nil ? nil : try url(key) }
    func screen(_ key: String) throws -> NSScreen {
      let screens = NSScreen.screens
      if let identity = values[key] as? [String: String], let fingerprint = identity["fingerprint"]
      {
        if let index = WallpaperScreenIdentity.commandTargetIndex(
          identifier: identity["id"], fingerprint: fingerprint,
          screens: screens.map { ($0.wallpaperScreenIdentifier, $0.wallpaperScreenFingerprint) }
        ) {
          return screens[index]
        }
      } else if let id = values[key] as? String,
        let screen = screens.first(where: { $0.wallpaperScreenIdentifier == id })
      {
        return screen
      }
      throw NSError(
        domain: "WaifuXHelper", code: 5,
        userInfo: [NSLocalizedDescriptionKey: t("目标显示器已变化或无法唯一识别，请重新选择")])
    }
    func optionalScreen(_ key: String) throws -> NSScreen? {
      values[key] == nil ? nil : try screen(key)
    }
    func screens(_ key: String) throws -> [NSScreen]? {
      guard let entries = values[key] else { return nil }
      guard let identities = entries as? [Any], !identities.isEmpty else {
        throw CocoaError(.coderInvalidValue)
      }
      return try identities.map { try AgentArguments(values: ["screen": $0]).screen("screen") }
    }
    func uuid(_ key: String) throws -> UUID {
      guard let value = UUID(uuidString: try string(key)) else {
        throw CocoaError(.coderInvalidValue)
      }
      return value
    }
    func decode<T: Decodable>(_ key: String, as type: T.Type) throws -> T {
      guard let data = values[key] as? Data else { throw CocoaError(.coderValueNotFound) }
      return try JSONDecoder().decode(type, from: data)
    }
  }

  @MainActor
  final class BackgroundAgentRuntime {
    static let shared = BackgroundAgentRuntime()
    private(set) var isReady = false
    private var observers: [ObjectIdentifier: NSXPCConnection] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var publishTask: Task<Void, Never>?
    private var shutdownRequested = false
    private var stopping = false
    private var stopAllStarted = false
    private var applicationQuitRequested = false
    private var quitFallbackTask: Task<Void, Never>?
    private var commandTail: Task<Data, Never>?
    private var inFlightReplies: [String: Task<Data, Never>] = [:]
    private var upgrading = false
    private var cachedReplyBytes = 0
    private var cachedReplies: [String: Data] = [:]
    private var replyOrder: [String] = []
    private var migrationProgress: MigrationProgress?
    private var libraryRevision: UInt64 = 0
    /// Helper 侧库记录是否已从磁盘恢复完（收藏/下载/文件夹三套都齐）。
    ///
    /// 这是 `library.snapshot` 快速读通道的闸门：没恢复完就读会返回空或半量
    /// 快照，UI 侧据此判「已到达」会把假空态换个理由复现（2026-10-26 复核指出）。
    /// 只有置 true 之后的读才被允许提前返回。
    private(set) var libraryRecordsAreRestored = false
    /// Helper 队列里在飞的库写操作数量（含已排队未执行）。
    ///
    /// 快速读通道只在它为 0 时越队：若队里还有一条删除/移动没跑，越队的读
    /// 会返回「还没有这次写」的快照，UI 整体覆盖后表现为已删记录复活、
    /// 刚建文件夹消失。
    private var pendingLibraryMutations = 0
    private var preferenceSequences: [String: UInt64] = [:]
    private var wallpaperDownloader: WallpaperViewModel?
    private var idleDownloadRelease: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var libraryRecoveryTask: Task<Void, Never>?
    private var logoutObserver: Any?
    private let sessionKey = "background_helper_active_session_v1"
    private var idleExitTask: Task<Void, Never>?
    #if DEBUG
      private(set) var regressionStaleIdentity = false
    #endif
    private init() {
      logoutObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
      ) { _ in
        WaifuXPreferences.shared.removeObject(forKey: "background_helper_active_session_v1")
        WaifuXPreferences.shared.synchronize()
      }
    }

    private var currentSession: String {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      process.arguments = ["managerpid"]
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      guard (try? process.run()) != nil else { return "" }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let manager =
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      var bootTime = timeval()
      var size = MemoryLayout<timeval>.size
      guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0, !manager.isEmpty else {
        return ""
      }
      return "\(bootTime.tv_sec):\(manager)"
    }

    func startAtLoginIfNeeded() async {
      guard !BackgroundRuntimeRole.isIsolatedTest else { return }
      let preferences = WaifuXPreferences.shared
      if preferences.bool(forKey: BackgroundAgentWire.migrationKey),
        preferences.bool(forKey: "launch_at_login")
          || (!currentSession.isEmpty && preferences.string(forKey: sessionKey) == currentSession)
      {
        await startRuntime()
      } else {
        idleExitTask = Task {
          try? await Task.sleep(for: .seconds(30))
          guard !Task.isCancelled, !isReady else { return }
          NSApp.terminate(nil)
        }
      }
    }

    private func startRuntime() async {
      guard !stopping, !upgrading else { return }
      if let startupTask {
        await startupTask.value
        return
      }
      idleExitTask?.cancel()
      startupTask = Task {
        ThemeManager.shared.restoreSavedSettings()
        LocalizationService.shared.restoreSavedSettings()
        await applyNetworkPreferences()
        guard !Task.isCancelled, !stopping, !upgrading else { return }
        WallpaperLibraryService.shared.restoreSavedData()
        LibraryFolderStore.shared.restoreSavedData()
        DownloadTaskService.shared.restoreSavedTasks()
        WallpaperSchedulerService.shared.restoreSavedConfig()
        WaifuXUIActions.handler = { [weak self] action in self?.openUI(action) }
        libraryRecordsAreRestored = true
        isReady = true
        if !BackgroundRuntimeRole.isIsolatedTest {
          WaifuXPreferences.shared.set(currentSession, forKey: sessionKey)
          WaifuXPreferences.shared.synchronize()
          await importLegacyWallpaperLibrary()
          await DirectoryMigrationService.shared.recoverIncompleteMigrationIfNeeded()
          guard !Task.isCancelled, !stopping, !upgrading else { return }
          await DirectoryMigrationService.shared.repairOrphanedPathsIfNeeded()
          guard !Task.isCancelled, !stopping, !upgrading else { return }
          prepareDownloadExecutors()
          WallpaperSchedulerService.shared.start()
          MenuBarQuickWallpaperRepository.shared.start()
          StatusBarController.shared.configure(
            showWindow: { WaifuXUIActions.perform(.main) },
            releaseMemory: { WaifuXUIActions.perform(.releaseMemory) },
            quit: { Task { await BackgroundAgentRuntime.shared.requestApplicationQuit() } })
          ExternalDisplayConnectionCoordinator.shared.start()
          DesktopWallpaperSyncManager.shared.syncOnAppActivation()
        }
        bindState()
        publish()
      }
      await startupTask?.value
    }

    private func importLegacyWallpaperLibrary() async {
      let key = "wallhaven_static_legacy_file_import_v1"
      guard !WaifuXPreferences.shared.bool(forKey: key) else { return }
      let directory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first!
      .appendingPathComponent("WaifuX/Library", isDirectory: true)
      do {
        let legacy = try await Task.detached(priority: .utility) {
          try LegacyWallhavenLibraryReader.read(from: directory)
        }.value
        guard !Task.isCancelled, !stopping, !upgrading else { return }
        let service = WallpaperLibraryService.shared
        let favoriteIDs = Set(service.favoriteRecords.map(\.id))
        let downloadIDs = Set(service.downloadRecords.map(\.id))
        let favorites = legacy.favorites.filter { !favoriteIDs.contains($0.id) }
        let downloads = legacy.downloads.filter { !downloadIDs.contains($0.id) }
        service.syncImportFavorites(favorites)
        service.syncImportDownloads(downloads)
        let cache = CachePersistenceService.shared
        let favoritesSaved = favorites.allSatisfy { record in
          let saved = cache.load(WallpaperFavoriteRecord.self, key: "wallpaper/fav/\(record.id)")
          return saved == record
        }
        let downloadsSaved = downloads.allSatisfy { record in
          let saved = cache.load(WallpaperDownloadRecord.self, key: "wallpaper/dl/\(record.id)")
          return saved == record
        }
        let favoriteIndex: [String] = cache.load([String].self, key: "index/wallpaper/fav") ?? []
        let downloadIndex: [String] = cache.load([String].self, key: "index/wallpaper/dl") ?? []
        let indicesSaved =
          Set(favorites.map(\.id)).isSubset(of: Set(favoriteIndex))
          && Set(downloads.map(\.id)).isSubset(of: Set(downloadIndex))
        if favoritesSaved && downloadsSaved && indicesSaved {
          WaifuXPreferences.shared.set(true, forKey: key)
        }
      } catch {
        AppLogger.warn(
          .wallpaper, "Legacy wallpaper library import failed; original files retained",
          metadata: ["error": error.localizedDescription])
      }
    }

    private func bindState() {
      let publishers: [AnyPublisher<Void, Never>] = [
        WallpaperSchedulerService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        CurrentWallpaperService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        DownloadTaskService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        CloudSyncService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
      ]
      for publisher in [
        WallpaperLibraryService.shared.objectWillChange.eraseToAnyPublisher(),
        LibraryFolderStore.shared.objectWillChange.eraseToAnyPublisher(),
      ] {
        publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in
          guard let self else { return }
          libraryRevision &+= 1
          schedulePublish()
        }.store(in: &subscriptions)
      }
      for publisher in publishers {
        publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.schedulePublish() }
          .store(in: &subscriptions)
      }
      NotificationCenter.default.publisher(for: .backgroundDownloadWorkersChanged)
        .receive(on: DispatchQueue.main).sink { [weak self] _ in
          self?.releaseIdleDownloadExecutors()
        }.store(in: &subscriptions)
      NotificationCenter.default.publisher(
        for: UserDefaults.didChangeNotification, object: WaifuXPreferences.shared
      )
      .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.schedulePublish() }.store(
        in: &subscriptions)
    }

    func subscribe(_ connection: NSXPCConnection) {
      observers[ObjectIdentifier(connection)] = connection
    }
    func unsubscribe(_ id: ObjectIdentifier) {
      observers.removeValue(forKey: id)
      if observers.isEmpty {
        if applicationQuitRequested && !stopAllStarted {
          Task { await stopAll() }
        }
      }
    }
    func snapshot() -> Data {
      let performanceStart = ProcessInfo.processInfo.systemUptime
      var snapshotBytes = 0
      defer {
        InteractionPerformanceLog.record(
          .helperSnapshot, since: performanceStart,
          metadata: [
            "ready": isReady ? "1" : "0",
            "subscribers": String(observers.count),
            "bytes": String(snapshotBytes),
          ])
      }
      var values: [String: Any] = [
        "ready": isReady, "pid": ProcessInfo.processInfo.processIdentifier,
      ]
      if isReady {
        values["appearance"] = ThemeManager.shared.backgroundSnapshot
        if !BackgroundRuntimeRole.isIsolatedTest {
          values["menuBar"] = StatusBarController.shared.backgroundSnapshot
        }
        values["desktop"] = DesktopWallpaperSyncManager.shared.backgroundSnapshot()
        values["scheduler"] = [
          "config": (try? JSONEncoder().encode(WallpaperSchedulerService.shared.config)) ?? Data(),
          "running": WallpaperSchedulerService.shared.isRunning,
        ]
        if let migrationProgress {
          values["migration"] = try? JSONEncoder().encode(migrationProgress)
        }
        values["libraryRevision"] = NSNumber(value: libraryRevision)
        values["downloads"] =
          (try? JSONEncoder().encode(DownloadTaskService.shared.tasks)) ?? Data()
        values["cloud"] = CloudSyncService.shared.backgroundSnapshot()
        values["current"] = CurrentWallpaperService.shared.activeURLByScreenID.mapValues(
          \.absoluteString)
      }
      let data = (try? BackgroundPropertyList.encode(values)) ?? Data()
      snapshotBytes = data.count
      return data
    }
    private func schedulePublish() {
      guard !stopping, !upgrading, !observers.isEmpty, publishTask == nil else { return }
      publishTask = Task {
        try? await Task.sleep(for: .milliseconds(30))
        publishTask = nil
        publish()
      }
    }
    private func publish() {
      guard !observers.isEmpty else { return }
      let data = snapshot() as NSData
      for (id, connection) in observers {
        let proxy =
          connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
            Task { @MainActor in BackgroundAgentRuntime.shared.unsubscribe(id) }
          } as? BackgroundAgentObserver
        proxy?.snapshotChanged(data)
      }
    }
    private func openUI(_ action: WaifuXUIActions.Action) {
      // Detail payloads are written by the Helper immediately before this
      // action. Commit them before an existing/new UI consumes the request.
      WaifuXPreferences.shared.synchronize()
      if action == .releaseMemory {
        for connection in observers.values {
          (connection.remoteObjectProxy as? BackgroundAgentObserver)?.openUI(action.rawValue)
        }
        return
      }

      // A URL event opens exactly the requested UI in both cold and warm
      // starts. Plain openApplication sends a reopen event, which also opens
      // the library window. Do not depend on potentially stale XPC observers.
      let request = WaifuXUIActions.Request(action: action)
      NSWorkspace.shared.open(
        [request.url],
        withApplicationAt: WaifuXHostBundle.bundleURL,
        configuration: request.openConfiguration()
      ) { _, error in
        if let error {
          AppLogger.error(
            .general, "Failed to open requested UI",
            metadata: [
              "action": action.rawValue, "error": error.localizedDescription,
            ])
        }
      }
    }

    func perform(_ bytes: Data) async -> Data {
      guard bytes.count <= BackgroundAgentWire.maximumCommandBytes,
        let command = try? JSONDecoder().decode(BackgroundAgentCommand.self, from: bytes)
      else {
        return encodeReply(
          BackgroundAgentReply(requestID: "", result: nil, error: "Invalid command"))
      }
      if let pending = inFlightReplies[command.requestID] { return await pending.value }
      guard !upgrading else {
        return encodeReply(
          BackgroundAgentReply(
            requestID: command.requestID, result: nil,
            error: LocalizationService.shared.t("后台服务正在更新，请稍后重试")))
      }
      // 库快照是纯读：允许越过队首那条 `bootstrap`（它会等整个 startRuntime，
      // 实测几十秒）。越过的前提是恢复已完成（见 execute 的闸门）且本进程内
      // 没有待提交的库写操作（UI 侧已按此条件选择是否走快速通道）。
      let isLibraryWrite =
        command.operation.hasPrefix("library.") && command.operation != "library.snapshot"
      if isLibraryWrite { pendingLibraryMutations += 1 }
      let isLibrarySnapshotRead =
        command.operation == "library.snapshot"
        && libraryRecordsAreRestored && pendingLibraryMutations == 0
      let previous = isLibrarySnapshotRead ? nil : commandTail
      let task = Task { @MainActor in
        defer { if isLibraryWrite { pendingLibraryMutations -= 1 } }
        _ = await previous?.value
        if let reply = cachedReplies[command.requestID] { return reply }
        let reply: BackgroundAgentReply
        do {
          guard !stopping || command.operation == "runtime.stop" else {
            throw CocoaError(.userCancelled)
          }
          guard command.protocolVersion == BackgroundAgentWire.protocolVersion else {
            throw CocoaError(.coderInvalidValue)
          }
          let a = AgentArguments(values: try BackgroundPropertyList.decode(command.arguments))
          var result = try await execute(command.operation, a)
          result["snapshot"] = snapshot()
          reply = BackgroundAgentReply(
            requestID: command.requestID, result: try BackgroundPropertyList.encode(result),
            error: nil)
        } catch {
          reply = BackgroundAgentReply(
            requestID: command.requestID, result: nil, error: error.localizedDescription)
        }
        let data = encodeReply(reply)
        if data.count <= 8 * 1024 * 1024 {
          cachedReplies[command.requestID] = data
          cachedReplyBytes += data.count
          replyOrder.append(command.requestID)
          while replyOrder.count > 64 || cachedReplyBytes > 8 * 1024 * 1024 {
            if let old = cachedReplies.removeValue(forKey: replyOrder.removeFirst()) {
              cachedReplyBytes -= old.count
            }
          }
        }
        schedulePublish()
        return data
      }
      if !command.operation.hasSuffix(".wait"), !isLibrarySnapshotRead { commandTail = task }
      inFlightReplies[command.requestID] = task
      let result = await task.value
      inFlightReplies.removeValue(forKey: command.requestID)
      return result
    }
    private func encodeReply(_ reply: BackgroundAgentReply) -> Data {
      (try? JSONEncoder().encode(reply)) ?? Data()
    }

    private func execute(_ operation: String, _ a: AgentArguments) async throws -> [String: Any] {
      guard BackgroundRuntimeRole.permitsOperation(operation) else {
        throw NSError(
          domain: "WaifuXHelper", code: 6,
          userInfo: [NSLocalizedDescriptionKey: "隔离回归默认禁止真实桌面渲染或系统壁纸操作"])
      }
      switch operation {
      case "cloud.syncOnUIExit":
        CloudSyncService.shared.syncOnAppTerminate()
        return [:]
      case "cloud.sync.wait":
        await CloudSyncService.shared.sync()
        return ["cloud": CloudSyncService.shared.backgroundSnapshot()]
      case "cloud.restore.wait":
        await CloudSyncService.shared.restoreFromCloud()
        return ["cloud": CloudSyncService.shared.backgroundSnapshot()]
      case "cloud.clearError":
        CloudSyncService.shared.clearError()
        return [:]
      case "desktop.capture":
        DesktopWallpaperSyncManager.shared.captureOriginalSystemWallpaperIfNeeded(
          for: try a.screens("screens") ?? NSScreen.screens)
        return [:]
      case "desktop.register":
        let options = Dictionary(
          uniqueKeysWithValues: (a.values["options"] as? [String: Any] ?? [:]).map {
            (NSWorkspace.DesktopImageOptionKey(rawValue: $0.key), $0.value)
          })
        DesktopWallpaperSyncManager.shared.registerWallpaperSet(
          try a.url("url"), for: try a.optionalScreen("screen"), options: options)
        return [:]
      case "desktop.clear":
        DesktopWallpaperSyncManager.shared.clearRegistration(for: try a.optionalScreen("screen"))
        return [:]
      case "desktop.clearIdentity":
        DesktopWallpaperSyncManager.shared.clearRegistration(
          screenID: try a.string("id"), fingerprint: try a.string("fingerprint"))
        return [:]
      case "desktop.activation":
        DesktopWallpaperSyncManager.shared.syncOnAppActivation()
        return [:]
      case "directory.repair.wait":
        guard !DirectoryMigrationService.shared.isMigrating else {
          throw NSError(
            domain: "WaifuXHelper", code: 8,
            userInfo: [NSLocalizedDescriptionKey: t("请等待目录迁移完成后再修复数据")])
        }
        return [
          "result": try JSONEncoder().encode(
            await DirectoryMigrationService.shared.repairBrokenRecords())
        ]
      case "preferences.migrate":
        WaifuXPreferences.shared.migrateLegacyDomainIfNeeded(
          a.values["preferences"] as? [String: Any] ?? [:])
        return [:]
      case "bootstrap":
        WaifuXPreferences.shared.migrateLegacyDomainIfNeeded(
          a.values["preferences"] as? [String: Any] ?? [:])
        await startRuntime()
        return [:]
      case "preferences.set":
        guard let bytes = a.values["mutation"] as? Data else {
          throw CocoaError(.coderValueNotFound)
        }
        let mutation = AgentArguments(values: try BackgroundPropertyList.decode(bytes))
        let key = try mutation.string("key")
        let writer = try mutation.string("writerID")
        let sequence = (mutation.values["sequence"] as? NSNumber)?.uint64Value ?? 0
        let identity = writer + ":" + key
        if sequence > preferenceSequences[identity, default: 0] {
          preferenceSequences[identity] = sequence
          if mutation.bool("removed") {
            WaifuXPreferences.shared.removeObject(forKey: key)
          } else {
            WaifuXPreferences.shared.set(mutation.values["value"], forKey: key)
          }
          WaifuXPreferences.shared.synchronize()
          if isReady { await refreshSettings(key: key) }
        }
        return ["key": key, "sequence": NSNumber(value: sequence)]
      case "runtime.refreshSettings":
        await refreshSettings()
        return [:]
      case "runtime.stop":
        stopping = true
        shutdownRequested = true
        return [:]
      case "wallpaper.apply":
        let success = try await LocalWallpaperApplyService.apply(
          localURL: a.url("url"), targetScreens: a.screens("screens"),
          options: a.decode("options", as: LocalWallpaperApplyService.Options.self))
        return ["success": success]
      case "scheduler.triggerNextWallpaperNow":
        try WallpaperSchedulerService.shared.triggerNextWallpaperNow(for: try a.string("screenID"))
        return [:]
      case "scheduler.triggerNextGlobalWallpaperNow":
        WallpaperSchedulerService.shared.triggerNextGlobalWallpaperNow()
        return [:]
      case "scheduler.triggerRandomWallpaperNow":
        try WallpaperSchedulerService.shared.triggerRandomWallpaperNow(
          for: try a.string("screenID"))
        return [:]
      case "scheduler.start":
        WallpaperSchedulerService.shared.start()
        return [:]
      case "scheduler.suppressAutoSwitch":
        try WallpaperSchedulerService.shared.suppressAutoSwitch(forScreen: try a.screen("screen"))
        return [:]
      case "scheduler.suppressAutoSwitchGlobally":
        WallpaperSchedulerService.shared.suppressAutoSwitchGlobally()
        return [:]
      case "scheduler.stop":
        WallpaperSchedulerService.shared.stop()
        return [:]
      case "scheduler.notifyManualWallpaperChange":
        WallpaperSchedulerService.shared.notifyManualWallpaperChange(
          screenID: a.optionalString("screenID"),
          itemID: a.optionalString("itemID")
        )
        return [:]
      case "scheduler.updateConfig":
        try WallpaperSchedulerService.shared.updateConfig(
          try a.decode("newConfig", as: SchedulerConfig.self))
        return [:]
      case "scheduler.updateGlobalDisplaySyncEnabled":
        WallpaperSchedulerService.shared.updateGlobalDisplaySyncEnabled(a.bool("enabled"))
        return [:]
      case "scheduler.updateGlobalDisplayEnabled":
        WallpaperSchedulerService.shared.updateGlobalDisplayEnabled(a.bool("enabled"))
        return [:]
      case "scheduler.updateGlobalDisplayInterval":
        WallpaperSchedulerService.shared.updateGlobalDisplayInterval(a.integer("minutes"))
        return [:]
      case "scheduler.updateGlobalDisplayOrder":
        try WallpaperSchedulerService.shared.updateGlobalDisplayOrder(
          ScheduleOrder(rawValue: try a.string("order")) ?? .random)
        return [:]
      case "scheduler.updateGlobalDisplayFolderIDs":
        WallpaperSchedulerService.shared.updateGlobalDisplayFolderIDs(
          a.values["folderIDs"] as? [String])
        return [:]
      case "scheduler.updateDisplayEnabled":
        try WallpaperSchedulerService.shared.updateDisplayEnabled(
          a.bool("enabled"), for: try a.screen("screen").wallpaperScreenIdentifier)
        return [:]
      case "scheduler.updateDisplayInterval":
        try WallpaperSchedulerService.shared.updateDisplayInterval(
          a.integer("minutes"), for: try a.screen("screen").wallpaperScreenIdentifier)
        return [:]
      case "scheduler.updateDisplayOrder":
        try WallpaperSchedulerService.shared.updateDisplayOrder(
          ScheduleOrder(rawValue: try a.string("order")) ?? .random,
          for: try a.screen("screen").wallpaperScreenIdentifier)
        return [:]
      case "scheduler.updateDisplayFolderIDs":
        try WallpaperSchedulerService.shared.updateDisplayFolderIDs(
          a.values["folderIDs"] as? [String], for: try a.screen("screen").wallpaperScreenIdentifier)
        return [:]
      case "scheduler.synchronizeCurrentGlobalWallpaperToConnectedDisplays":
        WallpaperSchedulerService.shared.synchronizeCurrentGlobalWallpaperToConnectedDisplays()
        return [:]
      case "scheduler.configureExternalDisplayForRandomAllWallpapers":
        try WallpaperSchedulerService.shared.configureExternalDisplayForRandomAllWallpapers(
          try a.screen("screen"))
        return [:]
      case "scheduler.configureExternalDisplayWithoutAutoSwitch":
        try WallpaperSchedulerService.shared.configureExternalDisplayWithoutAutoSwitch(
          try a.screen("screen"))
        return [:]
      case "scheduler.discardPersistedDisplayState":
        try WallpaperSchedulerService.shared.discardPersistedDisplayState(
          screenID: try a.string("screenID"), fingerprint: try a.string("fingerprint"))
        return [:]
      case "download.submitWallpaper":
        prepareDownloadExecutors()
        return [
          "id": try PersistentDownloadQueueService.shared.submitWallpaper(
            a.decode("wallpaper", as: Wallpaper.self), folderID: a.optionalString("folderID"))
        ]
      case "download.pause":
        PersistentDownloadQueueService.shared.pause(jobID: try a.string("id"))
        return [:]
      case "download.resume":
        prepareDownloadExecutors()
        PersistentDownloadQueueService.shared.resume(jobID: try a.string("id"))
        return [:]
      case "download.cancel":
        PersistentDownloadQueueService.shared.cancel(jobID: try a.string("id"))
        return [:]
      case "download.retry":
        prepareDownloadExecutors()
        PersistentDownloadQueueService.shared.retry(try a.decode("task", as: DownloadTask.self))
        return [:]
      case "download.pauseTask":
        DownloadTaskService.shared.pauseTask(id: try a.string("id"))
        return [:]
      case "download.resumeTask":
        DownloadTaskService.shared.resumeTask(id: try a.string("id"))
        return [:]
      case "download.cancelTask":
        DownloadTaskService.shared.cancelTask(id: try a.string("id"))
        return [:]
      case "download.removeTask":
        DownloadTaskService.shared.removeTask(id: try a.string("id"))
        return [:]
      case "download.cancelAll":
        DownloadTaskService.shared.cancelAllActiveDownloads()
        return [:]
      case "download.wait":
        let url = try await PersistentDownloadQueueService.shared.waitForRemoteCompletion(
          id: a.string("id"))
        return url.map { ["url": $0.absoluteString] } ?? [:]
      case "desktop.icons":
        DesktopIconManager.shared.setDesktopIconsHidden(a.bool("hidden"))
        return [:]
      case "desktop.restore":
        try DesktopWallpaperSyncManager.shared.restoreOriginalSystemWallpaper(
          for: a.screen("screen"))
        return [:]
      case "sleep.userSetting":
        SleepPreventer.shared.setPreventingSleep(a.bool("enabled"), reason: .userSetting)
        return [:]
      case "library.wallpaper.toggleFavorite0":
        try WallpaperLibraryService.shared.toggleFavorite(
          try a.decode("wallpaper", as: Wallpaper.self))
        return [:]
      case "library.wallpaper.recordDownload0":
        try WallpaperLibraryService.shared.recordDownload(
          try a.decode("wallpaper", as: Wallpaper.self), fileURL: try a.url("fileURL"),
          folderID: a.optionalString("folderID"))
        return [:]
      case "library.wallpaper.upsert0":
        try WallpaperLibraryService.shared.upsert(try a.decode("wallpaper", as: Wallpaper.self))
        return [:]
      case "library.wallpaper.upsertBatch0":
        try WallpaperLibraryService.shared.upsertBatch(
          try a.decode("wallpapers", as: [Wallpaper].self))
        return [:]
      case "library.wallpaper.updateDownloadPath0":
        try WallpaperLibraryService.shared.updateDownloadPath(
          for: try a.string("wallpaperID"), newURL: try a.url("newURL"))
        return [:]
      case "library.wallpaper.bulkUpdateDownloadPaths0":
        try WallpaperLibraryService.shared.bulkUpdateDownloadPaths(
          oldPrefix: try a.string("oldPrefix"), newPrefix: try a.string("newPrefix"))
        return [:]
      case "library.wallpaper.moveItemsToRoot0":
        try WallpaperLibraryService.shared.moveItemsToRoot(fromFolder: try a.string("folderID"))
        return [:]
      case "library.wallpaper.moveToFolder0":
        let scope: WallpaperLibraryService.FolderMembershipScope =
          try a.string("scope") == "favorites" ? .favorites : .downloads
        var fallback: (wallpaper: Wallpaper, fileURL: URL)? = nil
        if let wallpaperData = a.values["fallbackWallpaper"] as? Data,
          let fileURL = a.values["fallbackFileURL"] as? URL,
          let wallpaper = try? JSONDecoder().decode(Wallpaper.self, from: wallpaperData)
        {
          fallback = (wallpaper, fileURL)
        }
        WallpaperLibraryService.shared.moveWallpaperToFolder(
          wallpaperID: try a.string("wallpaperID"),
          folderID: a.optionalString("folderID"),
          scope: scope,
          fallback: fallback
        )
        return [:]
      case "library.wallpaper.repairDownloadPath0":
        try WallpaperLibraryService.shared.repairDownloadPath(
          recordID: try a.string("recordID"), newPath: try a.string("newPath"))
        return [:]
      case "library.wallpaper.deactivateDownloadRecord0":
        try WallpaperLibraryService.shared.deactivateDownloadRecord(
          recordID: try a.string("recordID"))
        return [:]
      case "library.wallpaper.syncImportFavorites0":
        try WallpaperLibraryService.shared.syncImportFavorites(
          try a.decode("records", as: [WallpaperFavoriteRecord].self))
        return [:]
      case "library.wallpaper.syncImportDownloads0":
        try WallpaperLibraryService.shared.syncImportDownloads(
          try a.decode("records", as: [WallpaperDownloadRecord].self))
        return [:]
      case "library.wallpaper.syncRemoveFavorites0":
        try WallpaperLibraryService.shared.syncRemoveFavorites(
          ids: try a.decode("ids", as: Set<String>.self))
        return [:]
      case "library.wallpaper.syncRemoveDownloads0":
        try WallpaperLibraryService.shared.syncRemoveDownloads(
          ids: try a.decode("ids", as: Set<String>.self))
        return [:]
      case "library.wallpaper.removeWallpaperFavorites0":
        try WallpaperLibraryService.shared.removeWallpaperFavorites(
          withIDs: try a.decode("ids", as: Set<String>.self))
        return [:]
      case "library.wallpaper.removeWallpaperDownloads0":
        try WallpaperLibraryService.shared.removeWallpaperDownloads(
          withIDs: try a.decode("ids", as: Set<String>.self))
        return [:]
      case "library.folder.create":
        LibraryFolderStore.shared.acceptCreatedFolder(
          try a.decode("folder", as: LibraryFolder.self))
        return [:]
      case "library.folder.renameFolder":
        try LibraryFolderStore.shared.renameFolder(
          id: try a.string("id"),
          contentType: try a.decode("contentType", as: LibraryFolder.FolderContentType.self),
          newName: try a.string("newName"))
        return [:]
      case "library.folder.toggleFolderLock":
        try LibraryFolderStore.shared.toggleFolderLock(
          id: try a.string("id"),
          contentType: try a.decode("contentType", as: LibraryFolder.FolderContentType.self))
        return [:]
      case "library.folder.setFolderLock":
        try LibraryFolderStore.shared.setFolderLock(
          id: try a.string("id"),
          contentType: try a.decode("contentType", as: LibraryFolder.FolderContentType.self),
          locked: a.bool("locked"))
        return [:]
      case "library.folder.deleteFolder":
        try LibraryFolderStore.shared.deleteFolder(
          id: try a.string("id"),
          contentType: try a.decode("contentType", as: LibraryFolder.FolderContentType.self))
        return [:]
      case "library.folder.syncImportWallpaperFolders":
        try LibraryFolderStore.shared.syncImportWallpaperFolders(
          try a.decode("folders", as: [LibraryFolder].self))
        return [:]
      case "library.snapshot":
        guard libraryRecordsAreRestored else {
          // 恢复未完成就应答会返回空/半量快照，UI 侧据此判「已到达」
          // 反而把假空态换个理由复现。让这次读明确失败，由调用方按拍重试。
          throw CocoaError(
            .featureUnsupported,
            userInfo: [
              NSLocalizedDescriptionKey: t("库记录尚未恢复完成")
            ])
        }
        return [
          "wallpaper": WallpaperLibraryService.shared.backgroundLibrarySnapshot(),
          "wallpaperFolders": try JSONEncoder().encode(LibraryFolderStore.shared.wallpaperFolders),
        ]
      case "directory.migrate.wait":
        let result = await DirectoryMigrationService.shared.migrate(
          from: try a.url("old"), to: try a.url("new")
        ) { [weak self] progress in
          self?.migrationProgress = progress
          self?.schedulePublish()
        }
        migrationProgress = nil
        return ["result": try JSONEncoder().encode(result)]
      default:
        throw CocoaError(
          .featureUnsupported,
          userInfo: [
            NSLocalizedDescriptionKey: "Unsupported static wallpaper command: \(operation)"
          ])
      }
    }

    private func releaseIdleDownloadExecutors() {
      idleDownloadRelease?.cancel()
      idleDownloadRelease = Task {
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled, !PersistentDownloadQueueService.shared.hasExecutableWork else {
          return
        }
        wallpaperDownloader = nil
        idleDownloadRelease = nil
      }
    }

    private func prepareDownloadExecutors() {
      idleDownloadRelease?.cancel()
      if wallpaperDownloader == nil { wallpaperDownloader = WallpaperViewModel() }
      PersistentDownloadQueueService.shared.configure(wallpaperViewModel: wallpaperDownloader!)
    }

    private func applyNetworkPreferences() async {
      let preferences = WaifuXPreferences.shared
      await NetworkService.shared.updateProxyConfiguration(
        enabled: preferences.bool(forKey: "proxy_enabled"),
        host: preferences.string(forKey: "proxy_host") ?? "",
        port: preferences.string(forKey: "proxy_port") ?? ""
      )
    }

    private func refreshSettings(key: String? = nil) async {
      guard !stopping, !upgrading else { return }
      if key == nil || key?.hasPrefix("proxy_") == true { await applyNetworkPreferences() }
      if key == nil || key == ThemeManager.preferencesKey
        || key == ThemeManager.legacyPreferencesKey
      {
        ThemeManager.shared.restoreSavedSettings()
      }
      if key == nil || key == "app_language" { LocalizationService.shared.restoreSavedSettings() }
      if key == nil || key == "pause_rotation_on_battery" {
        WallpaperSchedulerService.shared.reevaluateBatteryPolicy()
      }
      if key == nil || key == "prevent_system_sleep" {
        SleepPreventer.shared.setPreventingSleep(
          WaifuXPreferences.shared.bool(forKey: "prevent_system_sleep"), reason: .userSetting)
      }
    }

    func completeAcknowledgedCommand() {
      guard shutdownRequested else { return }
      shutdownRequested = false
      Task {
        // Flush the stop acknowledgement before teardown/connection loss.
        try? await Task.sleep(for: .milliseconds(100))
        await stopAll()
      }
    }

    func requestApplicationQuit() async {
      guard !applicationQuitRequested, !stopAllStarted else { return }
      applicationQuitRequested = true
      if observers.isEmpty {
        await stopAll()
        return
      }
      // An open UI gets a chance to submit its final settings. No UI is
      // launched when only the Helper/menu bar is running.
      let request = (try? BackgroundPropertyList.encode(["quitRequested": true])) ?? Data()
      for connection in observers.values {
        (connection.remoteObjectProxy as? BackgroundAgentObserver)?.snapshotChanged(
          request as NSData)
      }
      quitFallbackTask = Task {
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        // A connected UI owns its write drain and quit failure handling.
        // Do not stop its durable writer while final settings are queued.
        if observers.isEmpty { await stopAll() } else { applicationQuitRequested = false }
      }
    }

    func stopAll() async {
      guard !stopAllStarted else { return }
      stopAllStarted = true
      prepareForProcessExit(clearActiveSession: true)
      let stopped = (try? BackgroundPropertyList.encode(["stopped": true])) ?? Data()
      for connection in observers.values {
        (connection.remoteObjectProxy as? BackgroundAgentObserver)?.snapshotChanged(
          stopped as NSData)
      }
      try? await Task.sleep(for: .milliseconds(100))
      finishProcessExit()
      NSApp.terminate(nil)
    }

    /// Both explicit quit and code replacement own the same workers. Upgrades
    /// preserve the session marker so the replacement restores the current work.
    private func prepareForProcessExit(clearActiveSession: Bool) {
      stopping = true
      StaticWallpaperApplyService.prepareForProcessTermination()
      WallpaperSchedulerService.shared.prepareForProcessTermination()
      PersistentDownloadQueueService.shared.prepareForProcessTermination()
      quitFallbackTask?.cancel()
      idleExitTask?.cancel()
      publishTask?.cancel()
      startupTask?.cancel()
      libraryRecoveryTask?.cancel()
      idleDownloadRelease?.cancel()
      for task in inFlightReplies.values { task.cancel() }
      subscriptions.removeAll()
      if clearActiveSession { WaifuXPreferences.shared.removeObject(forKey: sessionKey) }
      WaifuXPreferences.shared.synchronize()
      prepareForTermination()
    }

    /// Catch workers created by a previously scheduled completion during the
    /// short acknowledgement flush, and recheck captured reparented workers.
    func finishProcessExit() {
      DownloadTaskService.shared.flushPendingPersistence()
      WaifuXPreferences.shared.synchronize()
    }
    func prepareForTermination() {
      isReady = false
    }

    func prepareForUpgrade() async {
      upgrading = true
      _ = await commandTail?.value
      // Existing queue and migration checkpoints remain intact. Do not clear
      // the user's desired wallpaper, pause settings or active-session marker.
      prepareForProcessExit(clearActiveSession: false)
    }
  }

  extension Notification.Name {
    static let backgroundAgentReleaseMemory = Notification.Name("com.waifux.helper.releaseMemory")
  }
#endif

import AppKit
import Combine
import Foundation

/// Rotates only verified downloaded Wallhaven images. Schedules and histories
/// are owned by physical display fingerprints, never by a recycled display ID.
@MainActor
final class WallpaperSchedulerService: ObservableObject {
  static let shared = WallpaperSchedulerService()
  @Published var config: SchedulerConfig = .default
  @Published private(set) var isRunning = false
  var isGlobalDisplaySyncEnabled: Bool { config.isGlobalDisplaySyncEnabled }
  var globalDisplayConfig: DisplaySchedulerConfig { config.globalDisplayConfig }
  private let configKey = "wallpaper_scheduler_config"
  private let historyKey = "wallhaven_static_rotation_state_v1"
  private let globalKey = "__global_display_sync__"
  private var states: [String: StaticWallpaperRotationState] = [:]
  private var legacyFingerprints: [String: String] = [:]
  private var retryAfter: [String: Date] = [:]
  private var unavailableUntil: [String: Date] = [:]
  private var rotations: [String: Task<Void, Never>] = [:]
  private var rotationIDs: [String: UUID] = [:]
  private var timer: DispatchSourceTimer?
  private var subscriptions = Set<AnyCancellable>()
  private var notificationTokens: [NSObjectProtocol] = []
  private var unlockToken: NSObjectProtocol?
  private var isStopping = false
  private var isStarted = false
  private var manualApplyInFlight = false
  private var didRestore = false

  private init() {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.observe { [weak self] snapshot in
        guard let self, let values = snapshot["scheduler"] as? [String: Any] else { return }
        if let data = values["config"] as? Data,
          let config = try? JSONDecoder().decode(SchedulerConfig.self, from: data)
        {
          self.config = config
        }
        isRunning = values["running"] as? Bool ?? false
      }
    }
  }
  func restoreSavedConfig() {
    guard BackgroundRuntimeRole.isHelper, !didRestore else { return }
    didRestore = true
    if let data = WaifuXPreferences.shared.data(forKey: configKey) {
      if WaifuXPreferences.shared.data(forKey: "wallhaven_static_backup_scheduler_v1") == nil {
        WaifuXPreferences.shared.set(data, forKey: "wallhaven_static_backup_scheduler_v1")
      }
      if let restored = try? JSONDecoder().decode(SchedulerConfig.self, from: data) {
        config = restored
      }
    }
    if let data = WaifuXPreferences.shared.data(
      forKey: "wallpaper_scheduler_display_fingerprints_v1")
    {
      legacyFingerprints =
        (try? PropertyListDecoder().decode([String: String].self, from: data))
        ?? (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
    for key in config.displayConfigs.keys
    where config.displayConfigs[key]?.displayFingerprint == nil {
      config.displayConfigs[key]?.displayFingerprint = legacyFingerprints[key]
    }
    if let data = WaifuXPreferences.shared.data(forKey: historyKey) {
      states =
        (try? JSONDecoder().decode([String: StaticWallpaperRotationState].self, from: data)) ?? [:]
    } else {
      restoreLegacyHistory()
    }
    relinkDisplayConfigsForCurrentScreens()
  }
  private func restoreLegacyHistory() {
    let preferences = WaifuXPreferences.shared
    let used =
      preferences.data(forKey: "wallpaper_scheduler_used_item_ids_v1").flatMap {
        try? JSONDecoder().decode([String: [String]].self, from: $0)
      } ?? [:]
    let current =
      preferences.data(forKey: "wallpaper_scheduler_last_changed_item_ids_v1").flatMap {
        try? PropertyListDecoder().decode([String: String].self, from: $0)
      } ?? [:]
    let times =
      preferences.data(forKey: "wallpaper_scheduler_last_change_times_v1").flatMap {
        try? PropertyListDecoder().decode([String: Date].self, from: $0)
      } ?? [:]
    for key in Set(used.keys).union(current.keys).union(times.keys) {
      let owner =
        key == globalKey
        ? globalKey : (config.displayConfigs[key]?.displayFingerprint ?? legacyFingerprints[key])
      guard let owner else { continue }
      states[owner] = StaticWallpaperRotationState(
        currentID: current[key], usedIDs: Set(used[key] ?? []), history: [],
        lastChangedAt: times[key])
    }
  }
  func resolvedDisplayConfig(for screen: NSScreen) -> DisplaySchedulerConfig {
    if config.isGlobalDisplaySyncEnabled { return config.globalDisplayConfig }
    guard let key = ownerKey(for: screen) else {
      return config.storedDisplayConfig(for: "unconfigured-display")
    }
    return config.storedDisplayConfig(for: key)
  }
  func displayConfigScreenID(for screen: NSScreen) -> String { screen.wallpaperScreenIdentifier }
  private func bindings() -> [String: String] {
    WallpaperScreenIdentity.schedulerBindings(
      fingerprints: config.displayConfigs.compactMapValues(\.displayFingerprint),
      screens: NSScreen.screens.map {
        ($0.wallpaperScreenIdentifier, $0.wallpaperScreenFingerprint)
      },
      allowRelativeRank: true)
  }
  private func ownerKey(for screen: NSScreen) -> String? {
    bindings().first { $0.value == screen.wallpaperScreenIdentifier }?.key
  }
  func relinkDisplayConfigsForCurrentScreens() {
    guard BackgroundRuntimeRole.isHelper else { return }
    let screens = NSScreen.screens
    let owners = bindings()
    let locations = WallpaperScreenIdentity.schedulerRelocations(
      keys: Set(config.displayConfigs.keys), bindings: owners,
      liveIDs: Set(screens.map(\.wallpaperScreenIdentifier)))
    let oldStates = states
    var movedStates: [String: StaticWallpaperRotationState] = [:]
    var previousStateKeys = Set<String>()
    var relocated: [String: DisplaySchedulerConfig] = [:]
    for (key, saved) in config.displayConfigs {
      var policy = saved
      if let liveID = owners[key],
        let screen = screens.first(where: { $0.wallpaperScreenIdentifier == liveID })
      {
        if let previous = policy.displayFingerprint, let state = oldStates[previous] {
          previousStateKeys.insert(previous)
          movedStates[screen.wallpaperScreenFingerprint] = state
        }
        policy.displayFingerprint = screen.wallpaperScreenFingerprint
      }
      relocated[locations[key] ?? key] = policy
    }
    for key in previousStateKeys { states.removeValue(forKey: key) }
    states.merge(movedStates) { _, newer in newer }
    config.displayConfigs = relocated
    persist()
  }
  func start() {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send("scheduler.start")
      return
    }
    guard !isStopping, BackgroundRuntimeRole.allowsDesktopRendering,
      !BackgroundRuntimeRole.isIsolatedTest
    else { return }
    restoreSavedConfig()
    isStarted = true
    if subscriptions.isEmpty {
      for publisher in [
        WallpaperLibraryService.shared.objectWillChange.eraseToAnyPublisher(),
        LibraryFolderStore.shared.objectWillChange.eraseToAnyPublisher(),
        FolderLockService.shared.objectWillChange.eraseToAnyPublisher(),
      ] {
        publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in
          self?.unavailableUntil.removeAll()
          self?.cancelRotations()
          self?.scheduleTimer()
        }.store(in: &subscriptions)
      }
      notificationTokens.append(
        NotificationCenter.default.addObserver(
          forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
          Task { @MainActor in
            self?.cancelRotations()
            self?.relinkDisplayConfigsForCurrentScreens()
            self?.scheduleTimer()
          }
        })
      notificationTokens.append(
        NSWorkspace.shared.notificationCenter.addObserver(
          forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
          Task { @MainActor in self?.tick() }
        })
      unlockToken = DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.unlocked() }
      }
    }
    scheduleTimer()
  }
  func stop() {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send("scheduler.stop")
      return
    }
    isStarted = false
    timer?.cancel()
    timer = nil
    cancelRotations()
    isRunning = false
  }
  func prepareForProcessTermination() {
    isStopping = true
    stop()
    GlobalWallpaperSyncCoordinator.shared.prepareForProcessExit()
    persist()
  }
  private func cancelRotations() {
    for task in rotations.values { task.cancel() }
    rotations.removeAll()
    rotationIDs.removeAll()
  }
  private func policies() -> [(String, [NSScreen], DisplaySchedulerConfig)] {
    let screens = NSScreen.screens
    if config.isGlobalDisplaySyncEnabled {
      return screens.isEmpty ? [] : [(globalKey, screens, config.globalDisplayConfig)]
    }
    return screens.map { ($0.wallpaperScreenFingerprint, [$0], resolvedDisplayConfig(for: $0)) }
  }
  private func dueDate(key: String, policy: DisplaySchedulerConfig) -> Date {
    let date = (states[key]?.lastChangedAt ?? Date()).addingTimeInterval(
      Double(policy.intervalMinutes) * 60)
    return max(date, retryAfter[key] ?? .distantPast)
  }
  private func scheduleTimer() {
    timer?.cancel()
    timer = nil
    guard isStarted, !isStopping, !manualApplyInFlight, BackgroundRuntimeRole.isHelper else {
      isRunning = false
      return
    }
    let enabled = policies().filter { $0.2.isEnabled }
    isRunning = !enabled.isEmpty
    for (key, _, _) in enabled where states[key]?.lastChangedAt == nil {
      states[key, default: .init()].lastChangedAt = Date()
    }
    let deadlines = enabled.filter { !$0.2.isOnUnlockMode && rotations[$0.0] == nil }.map {
      key, _, policy in dueDate(key: key, policy: policy)
    }
    guard let next = deadlines.min() else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now() + max(0.25, next.timeIntervalSinceNow), leeway: .milliseconds(250))
    timer.setEventHandler { [weak self] in Task { @MainActor in self?.tick() } }
    self.timer = timer
    timer.resume()
  }
  private func tick() {
    guard !isStopping, !manualApplyInFlight else { return }
    for (key, screens, policy) in policies() where policy.isEnabled && !policy.isOnUnlockMode {
      // An untouched schedule starts its interval now, rather than
      // moving the deadline on every timer or library notification.
      if states[key]?.lastChangedAt == nil { states[key, default: .init()].lastChangedAt = Date() }
      if dueDate(key: key, policy: policy) <= Date() {
        rotate(key: key, screens: screens, policy: policy)
      }
    }
    persist()
    scheduleTimer()
  }
  private func unlocked() {
    guard !manualApplyInFlight, !isStopping else { return }
    for (key, screens, policy) in policies() where policy.isEnabled && policy.isOnUnlockMode {
      rotate(key: key, screens: screens, policy: policy)
    }
  }
  private func candidates(for policy: DisplaySchedulerConfig) -> [WallpaperDownloadRecord] {
    let folders = LibraryFolderStore.shared.wallpaperFolders
    var allowed: Set<String>?
    if let selected = policy.folderIDs {
      var ids = Set(selected.isEmpty ? [""] : selected)
      var changed = true
      while changed {
        changed = false
        for folder in folders where folder.parentFolderID.map(ids.contains) == true {
          if ids.insert(folder.id).inserted { changed = true }
        }
      }
      allowed = ids
    }
    func isLocked(_ folderID: String?) -> Bool {
      var current = folderID
      var seen = Set<String>()
      while let id = current, seen.insert(id).inserted,
        let folder = folders.first(where: { $0.id == id })
      {
        if folder.isLocked && !FolderLockService.shared.isFolderUnlocked(id) { return true }
        current = folder.parentFolderID
      }
      return false
    }
    return WallpaperLibraryService.shared.downloadedWallpapers.filter {
      (allowed == nil || allowed!.contains($0.folderID ?? "")) && !isLocked($0.folderID)
        && WallhavenContentPolicy.isWallpaperRecord(
          id: $0.wallpaper.id, detailURL: $0.wallpaper.url, imagePath: $0.wallpaper.path)
    }.sorted {
      $0.downloadedAt == $1.downloadedAt ? $0.id < $1.id : $0.downloadedAt < $1.downloadedAt
    }
  }
  private func rotate(
    key: String, screens: [NSScreen], policy: DisplaySchedulerConfig, order: ScheduleOrder? = nil,
    previousID: String? = nil, manual: Bool = false
  ) {
    guard !isStopping, !manualApplyInFlight else { return }
    if manual { rotations[key]?.cancel() } else if rotations[key] != nil { return }
    let id = UUID()
    rotationIDs[key] = id
    rotations[key] = Task {
      defer {
        if rotationIDs[key] == id {
          rotations.removeValue(forKey: key)
          rotationIDs.removeValue(forKey: key)
          scheduleTimer()
        }
      }
      var records = candidates(for: policy).filter {
        (unavailableUntil[$0.id] ?? .distantPast) <= Date()
      }
      while !records.isEmpty {
        try? Task.checkCancellation()
        guard !Task.isCancelled, rotationIDs[key] == id else { return }
        let next =
          previousID
          ?? states[key, default: .init()].nextID(
            in: records.map(\.id), order: order ?? policy.order)
        guard let next, let record = records.first(where: { $0.id == next }) else { return }
        let url = record.localFileURL
        let exists = await Task.detached(priority: .utility) {
          FileManager.default.fileExists(atPath: url.path)
        }.value
        guard !Task.isCancelled, rotationIDs[key] == id else { return }
        if exists {
          do {
            var options = LocalWallpaperApplyService.Options()
            options.reason = "static-rotation"
            _ = try await LocalWallpaperApplyService.apply(
              localURL: url, targetScreens: screens, options: options)
            guard !Task.isCancelled, rotationIDs[key] == id else { return }
            if previousID != nil {
              states[key, default: .init()].recordPrevious(next)
            } else {
              states[key, default: .init()].recordSelection(
                next, candidates: Set(candidates(for: policy).map(\.id)))
            }
            retryAfter.removeValue(forKey: key)
            persist()
            return
          } catch {
            guard !Task.isCancelled else { return }
            AppLogger.warn(
              .wallpaper, "Static rotation failed",
              metadata: ["id": next, "error": error.localizedDescription])
          }
        }
        unavailableUntil[next] = Date().addingTimeInterval(20)
        records.removeAll { $0.id == next }
        if previousID != nil { break }
      }
      retryAfter[key] = Date().addingTimeInterval(20)
    }
  }
  func hasSchedulableItems(for screenID: String) -> Bool {
    guard let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID })
    else { return false }
    return !candidates(for: resolvedDisplayConfig(for: screen)).isEmpty
  }
  func triggerNextWallpaperNow(for screenID: String) { trigger(screenID, order: nil) }
  func triggerRandomWallpaperNow(for screenID: String) { trigger(screenID, order: .random) }
  func triggerNextGlobalWallpaperNow() {
    guard let screen = NSScreen.screens.first else { return }
    triggerNextWallpaperNow(for: screen.wallpaperScreenIdentifier)
  }
  private func trigger(_ screenID: String, order: ScheduleOrder?) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send(
        order == nil ? "scheduler.triggerNextWallpaperNow" : "scheduler.triggerRandomWallpaperNow",
        ["screenID": screenID])
      return
    }
    guard let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID })
    else { return }
    let policy = resolvedDisplayConfig(for: screen)
    rotate(
      key: config.isGlobalDisplaySyncEnabled ? globalKey : screen.wallpaperScreenFingerprint,
      screens: config.isGlobalDisplaySyncEnabled ? NSScreen.screens : [screen], policy: policy,
      order: order, manual: true)
  }
  func hasWallpaperHistory(for screenID: String) -> Bool {
    guard let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID })
    else { return false }
    let key = config.isGlobalDisplaySyncEnabled ? globalKey : screen.wallpaperScreenFingerprint
    return states[key]?.previousID(
      in: Set(candidates(for: resolvedDisplayConfig(for: screen)).map(\.id))) != nil
  }
  @discardableResult func triggerPreviousWallpaperNow(for screenID: String) -> Bool {
    guard BackgroundRuntimeRole.isHelper,
      let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID })
    else { return false }
    let key = config.isGlobalDisplaySyncEnabled ? globalKey : screen.wallpaperScreenFingerprint
    let policy = resolvedDisplayConfig(for: screen)
    guard let previous = states[key]?.previousID(in: Set(candidates(for: policy).map(\.id))) else {
      return false
    }
    rotate(
      key: key, screens: config.isGlobalDisplaySyncEnabled ? NSScreen.screens : [screen],
      policy: policy, previousID: previous, manual: true)
    return true
  }
  func beginManualWallpaperApply() async {
    if BackgroundRuntimeRole.isRemoteUI {
      _ = try? await BackgroundRuntimeBridge.request("scheduler.beginManualApply")
      return
    }
    manualApplyInFlight = true
    let pending = Array(rotations.values)
    cancelRotations()
    for task in pending { await task.value }
    await GlobalWallpaperSyncCoordinator.shared.drainBeforeLeavingGlobalMode()
    scheduleTimer()
  }
  func completeManualWallpaperApply(success: Bool, screenIDs: Set<String>) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send(
        "scheduler.completeManualApply", ["success": success, "screenIDs": screenIDs])
      return
    }
    manualApplyInFlight = false
    if success {
      for screen in NSScreen.screens where screenIDs.contains(screen.wallpaperScreenIdentifier) {
        suppressAutoSwitch(forScreen: screen)
      }
    }
    scheduleTimer()
  }
  func notifyManualWallpaperChange(screenID: String? = nil, itemID: String? = nil) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send(
        "scheduler.notifyManualWallpaperChange", ["screenID": screenID, "itemID": itemID])
      return
    }
    for screen in NSScreen.screens
    where screenID == nil || screen.wallpaperScreenIdentifier == screenID {
      let key = config.isGlobalDisplaySyncEnabled ? globalKey : screen.wallpaperScreenFingerprint
      if let itemID {
        states[key, default: .init()].recordSelection(
          itemID, candidates: Set(candidates(for: resolvedDisplayConfig(for: screen)).map(\.id)))
      } else {
        states[key, default: .init()].lastChangedAt = Date()
      }
    }
    persist()
    scheduleTimer()
  }
  func suppressAutoSwitch(forScreen screen: NSScreen) {
    notifyManualWallpaperChange(screenID: screen.wallpaperScreenIdentifier)
  }
  func suppressAutoSwitchGlobally() { notifyManualWallpaperChange() }
  func updateConfig(_ newConfig: SchedulerConfig) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send(
        "scheduler.updateConfig", ["newConfig": try? JSONEncoder().encode(newConfig)])
      return
    }
    config = newConfig
    relinkDisplayConfigsForCurrentScreens()
    changed()
  }
  private func changed() {
    cancelRotations()
    persist()
    if !isStarted, !isStopping { start() } else { scheduleTimer() }
  }
  private func persist() {
    guard BackgroundRuntimeRole.isHelper else { return }
    if let data = try? JSONEncoder().encode(config) {
      WaifuXPreferences.shared.set(data, forKey: configKey)
    }
    if let data = try? JSONEncoder().encode(states) {
      WaifuXPreferences.shared.set(data, forKey: historyKey)
    }
  }
  func updateGlobalDisplaySyncEnabled(_ enabled: Bool) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send("scheduler.updateGlobalDisplaySyncEnabled", ["enabled": enabled])
      return
    }
    config.isGlobalDisplaySyncEnabled = enabled
    changed()
    if enabled { GlobalWallpaperSyncCoordinator.shared.synchronizeCurrentWallpaperAfterEnabling() }
  }
  private func updateGlobal(
    _ operation: String, arguments: [String: Any?], change: (inout DisplaySchedulerConfig) -> Void
  ) {
    if BackgroundRuntimeRole.isRemoteUI {
      BackgroundRuntimeBridge.send(operation, arguments)
      return
    }
    change(&config.globalDisplayConfig)
    changed()
  }
  func updateGlobalDisplayEnabled(_ enabled: Bool) {
    updateGlobal("scheduler.updateGlobalDisplayEnabled", arguments: ["enabled": enabled]) {
      $0.isEnabled = enabled
    }
  }
  func updateGlobalDisplayInterval(_ minutes: Int) {
    guard SchedulerConfig.isSupportedInterval(minutes) else { return }
    updateGlobal("scheduler.updateGlobalDisplayInterval", arguments: ["minutes": minutes]) {
      $0.intervalMinutes = minutes
    }
  }
  func updateGlobalDisplayOrder(_ order: ScheduleOrder) {
    updateGlobal("scheduler.updateGlobalDisplayOrder", arguments: ["order": order.rawValue]) {
      $0.order = order
    }
  }
  func updateGlobalDisplayFolderIDs(_ folderIDs: [String]?) {
    updateGlobal("scheduler.updateGlobalDisplayFolderIDs", arguments: ["folderIDs": folderIDs]) {
      $0.folderIDs = folderIDs
    }
  }
  private func updateDisplay(
    _ screenID: String, operation: String, arguments: [String: Any?],
    change: (inout DisplaySchedulerConfig) -> Void
  ) {
    guard let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID })
    else { return }
    if BackgroundRuntimeRole.isRemoteUI {
      var args = arguments
      args["screen"] = screen
      BackgroundRuntimeBridge.send(operation, args)
      return
    }
    relinkDisplayConfigsForCurrentScreens()
    var policy = resolvedDisplayConfig(for: screen)
    if config.isGlobalDisplaySyncEnabled {
      policy = config.storedDisplayConfig(for: ownerKey(for: screen) ?? "unconfigured-display")
    }
    policy.displayFingerprint = screen.wallpaperScreenFingerprint
    change(&policy)
    config.displayConfigs[screenID] = policy
    changed()
  }
  func updateDisplayEnabled(_ enabled: Bool, for screenID: String) {
    updateDisplay(
      screenID, operation: "scheduler.updateDisplayEnabled", arguments: ["enabled": enabled]
    ) { $0.isEnabled = enabled }
  }
  func updateDisplayInterval(_ minutes: Int, for screenID: String) {
    guard SchedulerConfig.isSupportedInterval(minutes) else { return }
    updateDisplay(
      screenID, operation: "scheduler.updateDisplayInterval", arguments: ["minutes": minutes]
    ) { $0.intervalMinutes = minutes }
  }
  func updateDisplayOrder(_ order: ScheduleOrder, for screenID: String) {
    updateDisplay(
      screenID, operation: "scheduler.updateDisplayOrder", arguments: ["order": order.rawValue]
    ) { $0.order = order }
  }
  func updateDisplayFolderIDs(_ folderIDs: [String]?, for screenID: String) {
    updateDisplay(
      screenID, operation: "scheduler.updateDisplayFolderIDs", arguments: ["folderIDs": folderIDs]
    ) { $0.folderIDs = folderIDs }
  }
  func synchronizeCurrentGlobalWallpaperToConnectedDisplays() {
    if config.isGlobalDisplaySyncEnabled {
      GlobalWallpaperSyncCoordinator.shared.reapplyToConnectedDisplays()
    }
  }
  func configureExternalDisplayForRandomAllWallpapers(_ screen: NSScreen) {
    updateDisplay(
      screen.wallpaperScreenIdentifier,
      operation: "scheduler.configureExternalDisplayForRandomAllWallpapers", arguments: [:]
    ) {
      $0.isEnabled = true
      $0.order = .random
      $0.folderIDs = nil
    }
    triggerRandomWallpaperNow(for: screen.wallpaperScreenIdentifier)
  }
  func configureExternalDisplayWithoutAutoSwitch(_ screen: NSScreen) {
    updateDisplayEnabled(false, for: screen.wallpaperScreenIdentifier)
  }
  func discardPersistedDisplayState(screenID: String, fingerprint: String) {
    config.displayConfigs = config.displayConfigs.filter {
      $0.value.displayFingerprint != fingerprint
    }
    states.removeValue(forKey: fingerprint)
    changed()
  }
}

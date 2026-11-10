import AppKit
import Foundation

/// Orders static applications across all displays. Per-display rollback is
/// handled by StaticWallpaperApplyService before a transaction is committed.
@MainActor
final class GlobalWallpaperSyncCoordinator {
  static let shared = GlobalWallpaperSyncCoordinator()
  struct Snapshot: Codable, Equatable { let localPath: String }
  private let stateKey = "wallhaven_global_wallpaper_last_success_v1"
  private var tail: Task<Bool, Error>?
  private var requests: [UUID: Task<Bool, Error>] = [:]
  private var isStopping = false
  var lastSuccessfulApply: Snapshot? {
    guard let data = WaifuXPreferences.shared.data(forKey: stateKey) else { return nil }
    return try? JSONDecoder().decode(Snapshot.self, from: data)
  }
  func apply(
    localURL: URL, options: LocalWallpaperApplyService.Options,
    onStageChange: WallpaperApplyStageHandler? = nil
  ) async throws -> Bool {
    try Task.checkCancellation()
    guard !isStopping else { throw CancellationError() }
    let previous = tail
    let id = UUID()
    let task = Task { @MainActor in
      _ = await previous?.result
      try Task.checkCancellation()
      guard !isStopping else { throw CancellationError() }
      var options = options
      options.isGlobalTransaction = true
      let result = try await LocalWallpaperApplyService.apply(
        localURL: localURL, targetScreens: NSScreen.screens, options: options,
        onStageChange: onStageChange)
      if result, let data = try? JSONEncoder().encode(Snapshot(localPath: localURL.path)) {
        WaifuXPreferences.shared.set(data, forKey: stateKey)
      }
      return result
    }
    tail = task
    requests[id] = task
    defer {
      requests.removeValue(forKey: id)
      if requests.isEmpty { tail = nil }
    }
    return try await withTaskCancellationHandler(
      operation: { try await task.value }, onCancel: { task.cancel() })
  }
  func rebaseLibraryPath(from oldRoot: URL, to newRoot: URL) {
    guard let snapshot = lastSuccessfulApply,
      let next = WallpaperLibraryPath.rebase(snapshot.localPath, from: oldRoot.path, to: newRoot.path),
      FileManager.default.fileExists(atPath: next),
      WallpaperLibraryService.shared.downloadRecord(forLocalFilePath: next) != nil,
      let data = try? JSONEncoder().encode(Snapshot(localPath: next)) else { return }
    WaifuXPreferences.shared.set(data, forKey: stateKey)
  }
  func prepareForProcessExit() {
    isStopping = true
    for task in requests.values { task.cancel() }
  }
  func drainBeforeLeavingGlobalMode() async {
    let pending = Array(requests.values)
    for task in pending { task.cancel() }
    for task in pending { _ = await task.result }
  }
  func synchronizeCurrentWallpaperAfterEnabling() { reapplyToConnectedDisplays() }
  func reapplyToConnectedDisplays() {
    guard !isStopping, requests.isEmpty, !BackgroundRuntimeRole.isRemoteUI else { return }
    Task {
      guard requests.isEmpty else { return }
      var original = lastSuccessfulApply.map { URL(fileURLWithPath: $0.localPath) }
      if original.map({ WallpaperLibraryService.shared.downloadRecord(forLocalFilePath: $0.path) == nil || !FileManager.default.fileExists(atPath: $0.path) }) ?? true, let screen = NSScreen.screens.first,
        let current = CurrentWallpaperService.shared.activeURL(
          for: screen.wallpaperScreenIdentifier)
      {
        original =
          await PortraitBlurFillWallpaperService.shared.originalSourceURL(
            forDerivedWallpaperAt: current,
            derivedWallpapersDirectory: DownloadPathManager.shared.derivedWallpapersFolderURL)
          ?? current
      }
      guard let original,
        WallpaperLibraryService.shared.downloadRecord(forLocalFilePath: original.path) != nil
      else { return }
      guard requests.isEmpty else { return }
      var options = LocalWallpaperApplyService.Options()
      options.reason = "static-recovery"
      do { _ = try await apply(localURL: original, options: options) } catch {
        AppLogger.warn(
          .wallpaper, "Global static wallpaper recovery failed",
          metadata: ["error": error.localizedDescription])
      }
    }
  }
}

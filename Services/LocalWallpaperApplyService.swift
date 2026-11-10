import AppKit
import Foundation

@MainActor
enum LocalWallpaperApplyService {
  enum ApplyError: LocalizedError {
    case missingFile(String), unsupported(String), failed(String)
    var errorDescription: String? {
      switch self {
      case .missingFile(let path): return String(format: t("壁纸文件不存在：%@"), path)
      case .unsupported(let type): return String(format: t("暂不支持该类型壁纸：%@"), type)
      case .failed(let message): return message
      }
    }
  }
  struct Options: Codable {
    var animatedTransition = true
    var isGlobalTransaction = false
    var reason = "apply"
    var wallpaperTransitionToken: [String: UInt64]?
  }

  @discardableResult
  static func apply(
    localURL: URL, targetScreens: [NSScreen]?, options: Options = Options(),
    onStageChange: WallpaperApplyStageHandler? = nil
  ) async throws -> Bool {
    try Task.checkCancellation()
    onStageChange?(.preparing)
    if BackgroundRuntimeRole.isRemoteUI {
      return
        (try await BackgroundRuntimeBridge.request(
          "wallpaper.apply",
          [
            "url": localURL, "screens": targetScreens,
            "options": try JSONEncoder().encode(options),
          ])["success"] as? Bool) ?? false
    }
    let scheduler = WallpaperSchedulerService.shared
    let isManual = options.reason != "static-rotation" && options.reason != "static-recovery" && !options.isGlobalTransaction
    let lease = isManual ? await scheduler.beginManualWallpaperApply() : nil
    let screens = scheduler.isGlobalDisplaySyncEnabled ? NSScreen.screens : (targetScreens ?? NSScreen.screens)
    var success = false
    defer {
      if let lease {
        scheduler.completeManualWallpaperApply(
          lease: lease, success: success,
          screenIDs: Set(screens.map(\.wallpaperScreenIdentifier)),
          itemID: WallpaperLibraryService.shared.downloadRecord(forLocalFilePath: localURL.path)?.wallpaper.id)
      }
    }
    try Task.checkCancellation()
    if scheduler.isGlobalDisplaySyncEnabled && !options.isGlobalTransaction {
      success = try await GlobalWallpaperSyncCoordinator.shared.apply(
        localURL: localURL, options: options, onStageChange: onStageChange)
      return success
    }
    guard localURL.isFileURL, FileManager.default.fileExists(atPath: localURL.path) else {
      throw ApplyError.missingFile(localURL.path)
    }
    let token = options.wallpaperTransitionToken.map {
      StaticWallpaperRequestCoordinator.RequestToken(generationsByScreen: $0)
    }
    onStageChange?(.synchronizing)
    try await StaticWallpaperApplyService.apply(
      from: localURL, option: .desktop, targetScreens: targetScreens, requestToken: token)
    onStageChange?(.committing)
    success = true
    return true
  }
}

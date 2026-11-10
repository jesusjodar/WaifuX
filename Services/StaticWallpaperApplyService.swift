import AppKit
import Foundation

/// Applies verified downloaded Wallhaven images through the system desktop API.
@MainActor
enum StaticWallpaperApplyService {
  private static var isTerminating = false

  static func prepareForProcessTermination() { isTerminating = true }

  static func apply(
    from imageURL: URL, option: WallpaperOption, targetScreens: [NSScreen]? = nil,
    requestToken suppliedToken: StaticWallpaperRequestCoordinator.RequestToken? = nil
  ) async throws {
    try Task.checkCancellation()
    guard !isTerminating else { throw CancellationError() }
    if BackgroundRuntimeRole.isRemoteUI {
      _ = try await BackgroundRuntimeBridge.request(
        "wallpaper.apply",
        [
          "url": imageURL, "screens": targetScreens,
          "options": try JSONEncoder().encode(LocalWallpaperApplyService.Options()),
        ])
      return
    }
    guard BackgroundRuntimeRole.allowsDesktopRendering,
      imageURL.isFileURL,
      let record = WallpaperLibraryService.shared.downloadRecord(forLocalFilePath: imageURL.path),
      WallhavenContentPolicy.isWallpaperRecord(
        id: record.wallpaper.id, detailURL: record.wallpaper.url, imagePath: record.wallpaper.path),
      FileManager.default.fileExists(atPath: imageURL.path)
    else {
      throw LocalWallpaperApplyService.ApplyError.unsupported(imageURL.lastPathComponent)
    }
    let decoded = await Task.detached(priority: .userInitiated) {
      WallpaperBoundedImageDecoder.decode(url: imageURL)
    }.value
    try Task.checkCancellation()
    guard case .success = decoded else {
      throw LocalWallpaperApplyService.ApplyError.failed(t("壁纸图像尺寸无效"))
    }
    let live = NSScreen.screens
    var seen = Set<String>()
    let screens = (targetScreens ?? live).compactMap { preferred in
      live.first { $0.wallpaperScreenFingerprint == preferred.wallpaperScreenFingerprint }
    }.filter { seen.insert($0.wallpaperScreenIdentifier).inserted }
    guard !screens.isEmpty else { throw CancellationError() }
    let coordinator = StaticWallpaperRequestCoordinator.shared
    let token: StaticWallpaperRequestCoordinator.RequestToken
    if let suppliedToken {
      guard let subset = coordinator.subset(suppliedToken, screens: screens) else {
        throw CancellationError()
      }
      token = subset
    } else {
      token = coordinator.beginRequest(on: screens)
    }
    var prepared: [String: URL] = [:]
    for screen in screens {
      try Task.checkCancellation()
      var result = imageURL
      if WaifuXPreferences.shared.bool(forKey: "portrait_blur_fill_enabled") {
        result = try await PortraitBlurFillWallpaperService.shared.preparedWallpaperURL(
          for: imageURL,
          targetPixelSize: CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor),
          derivedWallpapersDirectory: DownloadPathManager.shared.derivedWallpapersFolderURL
        )
      }
      guard !isTerminating, coordinator.isCurrent(token) else { throw CancellationError() }
      prepared[screen.wallpaperScreenIdentifier] = result
    }
    let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
      .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
      .allowClipping: true,
    ]
    DesktopWallpaperSyncManager.shared.captureOriginalSystemWallpaperIfNeeded(for: screens)
    for screen in screens {
      try Task.checkCancellation()
      guard !isTerminating, coordinator.isCurrent(token),
        let image = prepared[screen.wallpaperScreenIdentifier]
      else { throw CancellationError() }
      try NSWorkspace.shared.setDesktopImageURLForAllSpaces(image, for: screen, options: options)
      DesktopWallpaperSyncManager.shared.registerWallpaperSet(
        image, for: screen, options: options, sourceURL: imageURL)
    }
  }

  static func apply(
    from imageURL: URL, option: WallpaperOption, for targetScreen: NSScreen?,
    requestToken: StaticWallpaperRequestCoordinator.RequestToken? = nil
  ) async throws {
    try await apply(
      from: imageURL, option: option, targetScreens: targetScreen.map { [$0] },
      requestToken: requestToken)
  }
}

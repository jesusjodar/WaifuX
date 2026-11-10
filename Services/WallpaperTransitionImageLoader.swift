import AppKit
import Kingfisher

/// A single selected wallpaper, decoded for the destination viewport while the liquid aperture
/// forms. Uses Kingfisher's shared processed cache and cancellation-aware async download path.
@MainActor
enum WallpaperTransitionImageLoader {
  static func targetPixelSize(viewportSize: CGSize, displayScale: CGFloat) -> CGSize {
    let width = max(1, viewportSize.width) * max(1, displayScale)
    let height = max(1, viewportSize.height) * max(1, displayScale)
    let reduction = min(1, 4096 / max(width, height), sqrt(8_000_000 / (width * height)))
    return CGSize(
      width: (width * reduction).rounded(.down), height: (height * reduction).rounded(.down))
  }

  private static var observers: [NSObjectProtocol] = []
  private final class DecodedVariant {
    let itemID: String?
    let url: URL
    let size: CGSize
    var isValid = true
    init(itemID: String?, url: URL, size: CGSize) {
      self.itemID = itemID
      self.url = url
      self.size = size
    }
  }
  private static var decodedVariants: [DecodedVariant] = []

  private static func imageProcessor(url: URL, size: CGSize) -> any ImageProcessor {
    DownsamplingImageProcessor(size: size)
  }

  private static func evict(_ variant: DecodedVariant) {
    variant.isValid = false
    KingfisherManager.shared.cache.removeImage(
      forKey: variant.url.cacheKey,
      processorIdentifier: imageProcessor(url: variant.url, size: variant.size).identifier)
  }

  private static func observeInvalidation() {
    guard observers.isEmpty else { return }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .appDidReceiveMemoryPressure, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          for variant in decodedVariants { evict(variant) }
          decodedVariants.removeAll()
        }
      })
  }

  static func load(url: URL?, viewportSize: CGSize, displayScale: CGFloat, itemID: String? = nil)
    async -> NSImage?
  {
    guard let url, !Task.isCancelled else { return nil }
    if url.isFileURL {
      let original = DesktopWallpaperSyncManager.shared.originalSourceURL(for: url)
      guard WallpaperLibraryService.shared.downloadRecord(forLocalFilePath: original.path) != nil
      else { return nil }
    } else {
      guard WallhavenContentPolicy.isImageURL(url) else { return nil }
    }
    observeInvalidation()
    let size = targetPixelSize(viewportSize: viewportSize, displayScale: displayScale)
    let variant: DecodedVariant
    if let existing = decodedVariants.first(where: {
      $0.itemID == itemID && $0.url == url && $0.size == size
    }) {
      variant = existing
    } else {
      if decodedVariants.count >= 2 { evict(decodedVariants.removeFirst()) }
      variant = DecodedVariant(itemID: itemID, url: url, size: size)
      decodedVariants.append(variant)
    }
    do {
      let source: Source =
        url.isFileURL
        ? .provider(LocalFileImageDataProvider(fileURL: url))
        : .network(KF.ImageResource(downloadURL: url))
      let result = try await KingfisherManager.shared.retrieveImage(
        with: source,
        options: [
          .processor(imageProcessor(url: url, size: size)),
          .scaleFactor(1), .backgroundDecode, .onlyLoadFirstFrame,
          .cacheMemoryOnly, .downloadPriority(0.8),
        ])
      guard variant.isValid else {
        evict(variant)
        return nil
      }
      guard !Task.isCancelled else { return nil }
      return result.image
    } catch {
      // The existing cover remains the reveal seed; the real detail can retry normally.
      return nil
    }
  }
}

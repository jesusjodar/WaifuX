import AppKit

/// Owns requests per display so a slow image preparation cannot overwrite a
/// newer selection. This coordinator has no rendering windows or snapshots.
@MainActor
final class StaticWallpaperRequestCoordinator {
  static let shared = StaticWallpaperRequestCoordinator()
  struct RequestToken: Sendable {
    let generationsByScreen: [String: UInt64]
  }
  private var ownership = WallpaperTransitionOwnership()

  func beginRequest(on screens: [NSScreen]) -> RequestToken {
    RequestToken(
      generationsByScreen: ownership.begin(screenIDs: Set(screens.map(\.wallpaperScreenIdentifier)))
    )
  }
  func isCurrent(_ token: RequestToken) -> Bool {
    ownership.isCurrent(token.generationsByScreen)
  }
  func subset(_ token: RequestToken, screens: [NSScreen]) -> RequestToken? {
    let ids = Set(screens.map(\.wallpaperScreenIdentifier))
    let values = token.generationsByScreen.filter { ids.contains($0.key) }
    let subset = RequestToken(generationsByScreen: values)
    return values.count == ids.count && isCurrent(subset) ? subset : nil
  }
  func request(_ token: RequestToken, for screen: NSScreen) -> RequestToken? {
    subset(token, screens: [screen])
  }
}

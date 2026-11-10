import Foundation

public enum MainTab: String, CaseIterable {
    case home, wallpaperExplore, myMedia

    var title: String {
        switch self {
        case .home: return t("nav.home")
        case .wallpaperExplore: return t("nav.wallpaper")
        case .myMedia: return t("nav.myMedia")
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .wallpaperExplore: return "photo"
        case .myMedia: return "heart"
        }
    }
}

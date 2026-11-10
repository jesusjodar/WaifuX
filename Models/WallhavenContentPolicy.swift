import Foundation

/// Content provenance is independent of transport proxies and user profiles.
/// These checks do not authorize arbitrary local files or infrastructure URLs.
enum WallhavenContentPolicy {
    static func isWallpaperID(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0)
        }
    }

    static func imageURL(_ value: String) -> URL? {
        guard let url = URL(string: value), isImageURL(url) else { return nil }
        return url
    }

    static func isImageURL(_ url: URL) -> Bool {
        guard isSecurePublicURL(url),
              ["w.wallhaven.cc", "th.wallhaven.cc"].contains(url.host?.lowercased() ?? "") else { return false }
        return ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased())
    }

    static func isWallpaperRecord(id: String, detailURL: String, imagePath: String) -> Bool {
        guard isWallpaperID(id), let detail = URL(string: detailURL),
              wallpaperID(from: detail) == id else { return false }
        // Legacy download metadata may store the original as an absolute local
        // path. Its verified Wallhaven identity is still required above.
        if imagePath.hasPrefix("/") { return true }
        guard let image = imageURL(imagePath) else { return false }
        let fileID = image.deletingPathExtension().lastPathComponent
        return fileID == "wallhaven-\(id)" || fileID == id
    }

    static func wallpaperID(from url: URL) -> String? {
        guard isSecurePublicURL(url) else { return nil }
        let parts = url.path.split(separator: "/")
        let host = url.host?.lowercased()
        let candidate: String
        if host == "whvn.cc", parts.count == 1 {
            candidate = String(parts[0])
        } else if host == "wallhaven.cc", parts.count == 2, parts[0] == "w" {
            candidate = String(parts[1])
        } else {
            return nil
        }
        return isWallpaperID(candidate) ? candidate : nil
    }

    private static func isSecurePublicURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }
}

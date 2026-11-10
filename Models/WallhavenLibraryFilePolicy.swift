import Foundation

/// A cloud manifest is not permission to read or overwrite arbitrary files.
/// Originals use the fixed download filename and must also have a live record.
enum WallhavenLibraryFilePolicy {
    static func originalFilename(id: String, recordedPath: String) -> String? {
        guard WallhavenContentPolicy.isWallpaperID(id), !recordedPath.isEmpty else { return nil }
        let filename = (recordedPath as NSString).lastPathComponent
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        guard ["jpg", "jpeg", "png", "webp"].contains(ext),
              stem == "wallhaven-\(id)" || stem == id else { return nil }
        return filename
    }

    static func wallpaperID(relativePath: String) -> String? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Wallpapers" else { return nil }
        let filename = String(parts[1])
        let stem = (filename as NSString).deletingPathExtension
        let id = stem.hasPrefix("wallhaven-") ? String(stem.dropFirst(10)) : stem
        guard originalFilename(id: id, recordedPath: filename) == filename else { return nil }
        return id
    }

    static func relativePath(id: String, recordedPath: String) -> String? {
        originalFilename(id: id, recordedPath: recordedPath).map { "Wallpapers/\($0)" }
    }

    static func destination(relativePath: String, root: URL) -> URL? {
        guard wallpaperID(relativePath: relativePath) != nil else { return nil }
        let destination = root.appendingPathComponent(relativePath).standardizedFileURL
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let expected = canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL.path
        guard destination.resolvingSymlinksInPath().path == expected else { return nil }
        return destination
    }

    static func isObjectHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

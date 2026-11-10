import Foundation

/// Path rebasing never treats a sibling directory (library-old, for example)
/// as part of the selected library.
enum WallpaperLibraryPath {
    static func rebase(_ path: String, from oldRoot: String, to newRoot: String) -> String? {
        guard path.hasPrefix("/"), oldRoot.hasPrefix("/"), newRoot.hasPrefix("/") else { return nil }
        func suffix(_ path: String, under root: String) -> String? {
            let root = root == "/" ? root : root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let prefix = root == "/" ? "/" : "/" + root
            if path == prefix { return "" }
            guard path.hasPrefix(prefix == "/" ? "/" : prefix + "/") else { return nil }
            return prefix == "/" ? path : String(path.dropFirst(prefix.count))
        }
        let tail = suffix(path, under: oldRoot) ?? suffix(
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path,
            under: URL(fileURLWithPath: oldRoot).standardizedFileURL.resolvingSymlinksInPath().path)
        guard let tail else { return nil }
        let normalized = newRoot == "/" ? "" : "/" + newRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let result = normalized + tail
        return result.isEmpty ? "/" : result
    }

    static func rebaseURLString(_ value: String, from oldRoot: String, to newRoot: String) -> String? {
        if value.hasPrefix("file:"), let url = URL(string: value), url.isFileURL,
           let path = rebase(url.path, from: oldRoot, to: newRoot) { return URL(fileURLWithPath: path).absoluteString }
        return rebase(value, from: oldRoot, to: newRoot)
    }

    static func isMigrationFile(_ relativePath: String) -> Bool {
        if WallhavenLibraryFilePolicy.wallpaperID(relativePath: relativePath) != nil { return true }
        if !relativePath.contains("/"), WallhavenLibraryFilePolicy.wallpaperID(relativePath: "Wallpapers/" + relativePath) != nil { return true }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "DerivedWallpapers" else { return false }
        let prefix: String
        switch parts[1] {
        case "PortraitBlurFill": prefix = "blur-fill-"
        case "StaticCrop": prefix = "crop-"
        default: return false
        }
        let filename = String(parts[2])
        guard filename.hasPrefix(prefix), filename.hasSuffix(".jpg") else { return false }
        let hash = String(filename.dropFirst(prefix.count).dropLast(4))
        // PortraitBlurFill uses the first 16 SHA-256 bytes (32 hex digits).
        return hash.utf8.count == 32 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

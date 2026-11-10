import Foundation
import Kingfisher

/// Regression helpers and UI previews never share the installed app's caches.
enum WallpaperCachePaths {
    static var base: URL {
        if BackgroundRuntimeRole.isIsolatedTest {
            let root = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("WaifuX-Isolated-\(getpid())")
            return root.appendingPathComponent("Caches", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
    static func directory(_ name: String) -> URL { base.appendingPathComponent(name, isDirectory: true) }
}

enum WallpaperImageCache {
    static let shared: ImageCache = make(name: "default")
    static func make(name: String) -> ImageCache {
        guard BackgroundRuntimeRole.isIsolatedTest else {
            return name == "default" ? ImageCache.default : ImageCache(name: name)
        }
        return try! ImageCache(name: "isolated-" + name, cacheDirectoryURL: WallpaperCachePaths.directory("Kingfisher"))
    }
}

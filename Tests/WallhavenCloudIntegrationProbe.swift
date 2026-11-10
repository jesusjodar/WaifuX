#if DEBUG && WAIFUX_HELPER
import AppKit
import CryptoKit
import Foundation

/// Runs inside the built helper, using its real stores and sync services.
/// The entry point requires the isolated preference suite and test root.
@MainActor
enum WallhavenCloudIntegrationProbe {
    struct Failed: Error { let detail: String }
    static func require(_ value: Bool, _ detail: String) throws {
        if !value { throw Failed(detail: detail) }
    }
    static func image(_ id: String) -> Wallpaper {
        let path = "https://w.wallhaven.cc/full/\(id.prefix(2))/wallhaven-\(id).png"
        return Wallpaper(id: id, title: nil, url: "https://wallhaven.cc/w/\(id)", shortUrl: nil,
            views: 0, favorites: 0, downloads: nil, source: nil, purity: "sfw", category: "anime",
            dimensionX: 1, dimensionY: 1, resolution: "1x1", ratio: "1", fileSize: nil,
            fileType: "image/png", createdAt: nil, colors: [], path: path,
            thumbs: .init(large: "https://th.wallhaven.cc/lg/\(id.prefix(2))/\(id).jpg", original: "", small: ""),
            tags: nil, uploader: nil)
    }
    static func run() async throws {
        guard BackgroundRuntimeRole.isIsolatedTest,
              let path = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"],
              ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_SUITE"]?.hasPrefix("waifux-cloud-integration-") == true else {
            throw Failed(detail: "Missing isolated test environment")
        }
        let root = URL(fileURLWithPath: path)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let library = WallpaperLibraryService.shared
        library.restoreSavedData()
        LibraryFolderStore.shared.restoreSavedData()
        let original = DownloadPathManager.shared.wallpaperFileURL(id: "aaa111", fileExtension: "png")
        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: original)
        library.syncImportDownloads([.init(wallpaper: image("aaa111"), localFilePath: original.path)])
        let timestamp = Date(timeIntervalSince1970: 10)
        library.syncImportFavorites([.init(wallpaper: image("abc123"), metadata: .init(recordID: "fav", entityType: "wallpaper.favorite", updatedAt: timestamp))])

        let config = CloudSyncConfiguration.shared
        config.syncDirectoryURL = root.appendingPathComponent("cloud")
        config.isEnabled = true
        config.conflictStrategy = .localPreferred
        let cloudRoot = config.syncRootURL!
        let currentMetadata = cloudRoot.appendingPathComponent(CloudSyncDirectoryLayout.metadataFileName)
        let currentManifest = cloudRoot.appendingPathComponent(CloudSyncDirectoryLayout.manifestFileName)
        try fm.createDirectory(at: config.objectsURL!, withIntermediateDirectories: true)
        let object = config.objectsURL!.appendingPathComponent(CloudSyncDirectoryLayout.objectSubpath(hash: hash))
        try fm.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: object)
        let retiredHash = String(repeating: "b", count: 64)
        let retiredObject = config.objectsURL!.appendingPathComponent(CloudSyncDirectoryLayout.objectSubpath(hash: retiredHash))
        try fm.createDirectory(at: retiredObject.deletingLastPathComponent(), withIntermediateDirectories: true)
        let retiredBytes = Data("legacy anime episode".utf8)
        try retiredBytes.write(to: retiredObject)
        var records = CloudSyncRecords()
        records.wallpaperFavorites = [.init(wallpaper: image("abc123"), metadata: .init(recordID: "fav", entityType: "wallpaper.favorite", updatedAt: Date(timeIntervalSince1970: 20), isDeleted: true))]
        records.wallpaperDownloads = [.init(wallpaper: image("def456"), localFilePath: "/another-device/Wallpapers/wallhaven-def456.png")]
        let remoteFolder = LibraryFolder(name: "Remote Wallhaven", contentType: .wallpaper)
        records.libraryFolders = .init(wallpaper: [remoteFolder])
        records.libraryGridOrder = ["wallpaper.favorites.root": ["abc123", "pixiv_999"], "media.downloads.root": ["episode"]]
        let payload = CloudSyncMetadataPayload(deviceID: "other-device", syncedAt: .now, records: records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(payload)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var mixed = legacy["records"] as! [String: Any]
        mixed["mediaDownloads"] = [["slug": "old-series", "localFilePath": "Media/episode.mp4"]]
        mixed["animeFavorites"] = ["old-series": ["title": "Legacy series"]]
        legacy["records"] = mixed
        let metadataBytes = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        let legacyMetadata = cloudRoot.appendingPathComponent(CloudSyncDirectoryLayout.legacyMetadataFileName)
        try metadataBytes.write(to: legacyMetadata)
        let legacyManifest = cloudRoot.appendingPathComponent(CloudSyncDirectoryLayout.legacyManifestFileName)
        let manifestBytes = try JSONSerialization.data(withJSONObject: ["version": 1, "updatedAt": 0, "files": [
            "Wallpapers/wallhaven-def456.png": ["hash": hash, "size": bytes.count, "mtime": 0],
            "Wallpapers/wallhaven-qqq999.png": ["hash": hash, "size": bytes.count, "mtime": 0],
            "Media/episode.mp4": ["hash": retiredHash, "size": retiredBytes.count, "mtime": 0],
            "../outside.png": ["hash": hash, "size": bytes.count, "mtime": 0],
        ]])
        try manifestBytes.write(to: legacyManifest)
        if let fixture = ProcessInfo.processInfo.environment["WAIFUX_TEST_WEBDAV_URL"],
           let url = URL(string: fixture) {
            try require(url.host == "127.0.0.1" && url.scheme == "http", "WebDAV probe requires a loopback fixture")
            config.webDAVURLString = fixture
            config.webDAVUsername = "fixture"
            config.webDAVPassword = "fixture"
            config.syncMode = .webDAV
        }
        let service = CloudSyncService.shared
        await service.sync()
        if let error = service.lastError { throw error }
        let restored = DownloadPathManager.shared.wallpaperFileURL(id: "def456", fileExtension: "png")
        try require(try Data(contentsOf: restored) == bytes, "Registered remote original not restored")
        try require(!fm.fileExists(atPath: DownloadPathManager.shared.wallpaperFileURL(id: "qqq999", fileExtension: "png").path), "Unregistered image was restored")
        try require(!fm.fileExists(atPath: DownloadPathManager.shared.rootFolderURL.appendingPathComponent("Media/episode.mp4").path), "Retired series was restored")
        try require(try Data(contentsOf: legacyMetadata) == metadataBytes, "Legacy metadata was overwritten")
        try require(try Data(contentsOf: legacyManifest) == manifestBytes, "Legacy manifest was overwritten")
        try require(try Data(contentsOf: retiredObject) == retiredBytes, "Retired object was removed")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(CloudSyncMetadataPayload.self, from: Data(contentsOf: currentMetadata))
        let tombstone = exported.records.wallpaperFavorites.first { $0.id == "abc123" }
        try require(tombstone?.metadata.isDeleted == true && tombstone?.metadata.updatedAt == Date(timeIntervalSince1970: 20), "Tombstone or original timestamp lost")
        try require(exported.records.libraryFolders?.wallpaper.contains { $0.id == remoteFolder.id } == true, "New folder was lost with local preference")
        try require(exported.records.wallpaperDownloads.allSatisfy { !$0.localFilePath.hasPrefix("/") }, "Device path leaked into cloud metadata")
        let newManifest = try JSONDecoder().decode(CloudSyncManifest.self, from: Data(contentsOf: currentManifest))
        try require(Set(newManifest.files.keys) == ["Wallpapers/wallhaven-aaa111.png", "Wallpapers/wallhaven-def456.png"], "Manifest contains unknown files or misses originals")
        try fm.removeItem(at: restored)
        await service.restoreFromCloud()
        if let error = service.lastError { throw error }
        try require(try Data(contentsOf: restored) == bytes, "Static restore failed")
        let lastSuccessful = service.lastSyncedAt
        try Data("corrupt new snapshot".utf8).write(to: currentMetadata)
        await service.sync()
        try require(service.lastError != nil && service.lastSyncedAt == lastSuccessful, "Failed sync claimed success")
        try require(try Data(contentsOf: legacyMetadata) == metadataBytes, "Legacy snapshot changed after failure")
        print("PASS: real helper cloud sync and restore, cross-device paths, tombstones, folders, unknown-file exclusion and legacy cloud preservation")
    }
}
#endif

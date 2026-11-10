import Foundation

func t(_ value: String) -> String { value }

@main
enum WallhavenCloudFileTests {
    static func assertFile(_ url: URL, equals expected: Data) throws {
        let actual = try Data(contentsOf: url)
        precondition(actual == expected)
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("waifux-cloud-files-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        let image = library.appendingPathComponent("Wallpapers/wallhaven-abc123.png")
        try fm.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
        try bytes.write(to: image)
        let unrelated = root.appendingPathComponent("private.png")
        try Data("private file".utf8).write(to: unrelated)
        let legacyMedia = library.appendingPathComponent("Media/episode.mp4")
        try fm.createDirectory(at: legacyMedia.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy series".utf8).write(to: legacyMedia)
        let linked = library.appendingPathComponent("Wallpapers/wallhaven-zzz999.png")
        try fm.createSymbolicLink(at: linked, withDestinationURL: unrelated)
        precondition(WallhavenLibraryFilePolicy.destination(relativePath: "Wallpapers/wallhaven-zzz999.png", root: library) == nil)

        let engine = CloudSyncFileEngine.shared
        let files = try await engine.scanLocalFiles([
            "Wallpapers/wallhaven-abc123.png": image,
            "Media/episode.mp4": legacyMedia,
            "Wallpapers/wallhaven-aaa111.png": unrelated,
            "Wallpapers/wallhaven-zzz999.png": linked,
            "../private.png": unrelated,
        ], root: library)
        precondition(Set(files.keys) == ["Wallpapers/wallhaven-abc123.png"])
        let hash = files["Wallpapers/wallhaven-abc123.png"]!.hash
        precondition(WallhavenLibraryFilePolicy.isObjectHash(hash))
        let objects = root.appendingPathComponent("sync/objects")
        try await engine.uploadFile(localURL: image, hash: hash, objectsDir: objects)
        let destination = root.appendingPathComponent("restored/wallhaven-abc123.png")
        try await engine.downloadFile(hash: hash, objectsDir: objects, destinationURL: destination)
        try assertFile(destination, equals: bytes)
        // An existing original is replaced only after a verified copy is staged.
        try Data("old original".utf8).write(to: destination)
        try await engine.downloadFile(hash: hash, objectsDir: objects, destinationURL: destination)
        try assertFile(destination, equals: bytes)
        let object = objects.appendingPathComponent(CloudSyncDirectoryLayout.objectSubpath(hash: hash))
        try Data("corrupt object".utf8).write(to: object)
        do {
            try await engine.downloadFile(hash: hash, objectsDir: objects, destinationURL: destination)
            preconditionFailure("Corrupt objects must fail")
        } catch CloudSyncError.fileHashFailed {}
        try assertFile(destination, equals: bytes)
        do {
            try await engine.uploadFile(localURL: unrelated, hash: hash, objectsDir: objects)
            preconditionFailure("A changed source must not be uploaded under an old hash")
        } catch CloudSyncError.fileHashFailed {}
        do {
            try await engine.downloadFile(hash: "../../escape", objectsDir: objects, destinationURL: destination)
            preconditionFailure("Invalid object hashes must fail")
        } catch CloudSyncError.fileHashFailed {}

        let manifestRoot = root.appendingPathComponent("sync")
        let legacy = manifestRoot.appendingPathComponent(CloudSyncDirectoryLayout.legacyManifestFileName)
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "version": 1, "updatedAt": 0,
            "files": [
                "Wallpapers/wallhaven-abc123.png": ["hash": hash, "size": bytes.count, "mtime": 0],
                "Media/episode.mp4": ["hash": String(repeating: "a", count: 64), "size": 10, "mtime": 0],
                "Wallpapers/wallhaven-zzz999.png": ["hash": "../escape", "size": 4, "mtime": 0],
                "Wallpapers/aaa111.jpg": ["hash": hash, "size": "invalid", "mtime": 0],
            ],
        ])
        try legacyData.write(to: legacy)
        let current = manifestRoot.appendingPathComponent(CloudSyncDirectoryLayout.manifestFileName)
        let imported = try await engine.readManifest(from: current)
        precondition(Set(imported.files.keys) == ["Wallpapers/wallhaven-abc123.png"])
        try await engine.writeManifest(imported, to: current)
        try assertFile(legacy, equals: legacyData)
        try assertFile(legacyMedia, equals: Data("legacy series".utf8))
        try assertFile(unrelated, equals: Data("private file".utf8))
        // A corrupt new snapshot must not silently fall back to the legacy snapshot.
        try Data("invalid JSON".utf8).write(to: current)
        do {
            _ = try await engine.readManifest(from: current)
            preconditionFailure("Corrupt manifests must fail")
        } catch CloudSyncError.manifestCorrupted {}
        print("PASS: production cloud file engine whitelist, symlink and hash guards, verified replacement, mixed legacy manifest and original preservation")
    }
}

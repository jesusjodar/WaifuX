// Exercise the production queue and models with a controllable transfer adapter.
// UI, XPC, and application preferences are isolated from the installed app.
import Foundation
import Combine

func t(_ value: String) -> String { value }
@MainActor enum BackgroundRuntimeBridge {
    static func refreshLibrarySnapshot() async throws {}
    static func observe(_ handler: @escaping ([String: Any]) -> Void) {}
    static func send(_ operation: String, _ values: [String: Any?] = [:]) {}
    static func request(_ operation: String, _ values: [String: Any?] = [:]) async throws -> [String: Any] {
        preconditionFailure("An isolated queue must not send XPC requests")
    }
}
enum AppLogger {
    enum Category { case download, wallpaper }
    static func warn(_ category: Category, _ message: String, metadata: [String: Any]) {}
    static func error(_ category: Category, _ message: String, metadata: [String: Any]) { print(message) }
}
@MainActor final class WallpaperLibraryService {
    static let shared = WallpaperLibraryService()
    var downloaded: Set<String> = []
    func isDownloaded(_ image: Wallpaper) -> Bool { downloaded.contains(image.id) }
    func localFileURLIfAvailable(for image: Wallpaper) -> URL? {
        downloaded.contains(image.id) ? URL(fileURLWithPath: "/test/\(image.id).jpg") : nil
    }
}
@MainActor final class WallpaperViewModel {
    var attempts: [String: Int] = [:]
    var failing = Set<String>()
    var running = 0
    var maximumRunning = 0
    var starts: [String] = []
    func executeQueuedWallpaperDownload(_ image: Wallpaper, folderID: String?, taskID: String) async throws {
        attempts[image.id, default: 0] += 1
        starts.append(image.id)
        running += 1
        maximumRunning = max(maximumRunning, running)
        defer { running -= 1 }
        try await Task.sleep(for: .milliseconds(40))
        if failing.remove(image.id) != nil { throw URLError(.cannotConnectToHost) }
        WallpaperLibraryService.shared.downloaded.insert(image.id)
    }
}

@main
@MainActor enum QueueTests {
    static func image(_ id: String) throws -> Wallpaper {
        let record: [String: Any] = [
            "id": id, "url": "https://wallhaven.cc/w/\(id)", "views": 1, "favorites": 1,
            "purity": "sfw", "category": "anime", "dimension_x": 1600, "dimension_y": 900,
            "resolution": "1600x900", "ratio": "1.78", "colors": ["000000"],
            "path": "https://w.wallhaven.cc/full/\(id.prefix(2))/wallhaven-\(id).jpg",
            "thumbs": ["small": "https://th.wallhaven.cc/small/\(id).jpg", "original": "https://th.wallhaven.cc/orig/\(id).jpg", "large": "https://th.wallhaven.cc/lg/\(id).jpg"]
        ]
        return try JSONDecoder().decode(Wallpaper.self, from: JSONSerialization.data(withJSONObject: record))
    }
    static func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        preconditionFailure("Queue condition timed out")
    }
    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"]!).appendingPathComponent("DownloadQueue")
    }
    static var checkpoint: URL { directory.appendingPathComponent("wallhaven-download-queue-v1.json") }
    static func main() async throws {
        let suite = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_SUITE"]!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        precondition(Wallpaper.normalizedImageURL(from: "https://pixiv.net/image.jpg") == nil)
        precondition(Wallpaper.normalizedImageURL(from: "http://th.wallhaven.cc/lg/aa/aa0001.jpg") == nil)
        precondition(Wallpaper.normalizedImageURL(from: "//th.wallhaven.cc/lg/aa/aa0001.jpg")?.host == "th.wallhaven.cc")
        let index = MenuBarQuickIndex.build([
            MenuBarQuickIndexEntry(id: "hidden", path: "/library/secret.jpg", folderKey: "private", downloadedAt: .now, visible: false),
            MenuBarQuickIndexEntry(id: "visible", path: "/library/original.jpg", folderKey: "chosen", downloadedAt: .now, visible: true)
        ])
        precondition(index.owner(of: "/library/secret.jpg") == nil)
        precondition(index.owner(of: "/library/original.jpg") == "visible")
        precondition(index.owner(of: "/library") == nil)
        precondition(index.owner(of: "/tmp/foreign-provider.jpg") == nil)
        precondition(index.sample(folderIDs: ["chosen"], excluding: [], limit: 16) == ["visible"])
        precondition(index.sample(folderIDs: ["private"], excluding: [], limit: 16).isEmpty)
        let mode = CommandLine.arguments[1]
        let queue = PersistentDownloadQueueService.shared
        let model = WallpaperViewModel()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if mode == "migration" {
            let image = try image("aa0001")
            let legacyDirectory = directory.appendingPathComponent("LegacyLibrary")
            try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
            let metadata = try JSONSerialization.data(withJSONObject: ["fullImageURL": image.path, "resolution": "1600x900", "purity": "sfw", "category": "anime"])
            let oldFavorite: [String: Any] = ["contentType": "wallpaper", "title": "Legacy favorite", "thumbnailURL": image.thumbs.large, "sourceURL": image.url, "metadata": ["type": "wallpaper", "data": metadata.base64EncodedString()]]
            let favoriteBytes = try JSONSerialization.data(withJSONObject: [oldFavorite, ["contentType": "anime"], NSNull(), ["damaged": true]])
            let favoritesURL = legacyDirectory.appendingPathComponent("wallpaper_favorites.json")
            try favoriteBytes.write(to: favoritesURL)
            let oldDownload: [String: Any] = ["contentType": "wallpaper", "itemId": image.id, "title": "Legacy download", "thumbnailURL": image.thumbs.large, "downloadURL": image.path, "localPath": "/missing/legacy/original.jpg", "downloadedAt": 0, "status": "completed"]
            try JSONSerialization.data(withJSONObject: [oldDownload, ["contentType": "video"]]).write(to: legacyDirectory.appendingPathComponent("downloads.json"))
            try Data("unsupported original is never parsed".utf8).write(to: legacyDirectory.appendingPathComponent("anime_favorites.json"))
            let recovered = try LegacyWallhavenLibraryReader.read(from: legacyDirectory)
            precondition(recovered.favorites.map(\.id) == [image.id])
            precondition(recovered.favorites[0].wallpaper.category == "anime")
            precondition(recovered.favorites[0].wallpaper.dimensionX == 1600)
            precondition(recovered.downloads.map(\.id) == [image.id])
            precondition(recovered.downloads[0].localFilePath == "/missing/legacy/original.jpg")
            let retainedFavorites = try Data(contentsOf: favoritesURL)
            precondition(retainedFavorites == favoriteBytes)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(image))
            let job: [String: Any] = ["id": "wallpaper.aa0001", "payload": ["wallpaper": ["_0": object]], "state": "paused", "source": "manual", "addedAt": 0, "updatedAt": 0, "attemptCount": 1]
            let raw = try JSONSerialization.data(withJSONObject: ["version": 2, "jobs": [job, ["id": "media.retired", "payload": ["media": [:]], "state": "queued"], NSNull()]])
            let old = directory.appendingPathComponent("download-queue-v2.json")
            try raw.write(to: old)
            queue.configure(wallpaperViewModel: model)
            precondition(DownloadTaskService.shared.tasks.map(\.id) == ["wallpaper.aa0001"])
            precondition(DownloadTaskService.shared.tasks[0].status == .paused)
            let preserved = try Data(contentsOf: old)
            precondition(preserved == raw)
            precondition(FileManager.default.fileExists(atPath: checkpoint.path))
            queue.resume(jobID: "wallpaper.aa0001")
            _ = try await queue.waitForRemoteCompletion(id: "wallpaper.aa0001")
            precondition(WallpaperLibraryService.shared.downloaded.contains("aa0001"))
        } else if mode == "corrupt" {
            let raw = Data("unreadable original checkpoint".utf8)
            try raw.write(to: checkpoint)
            queue.configure(wallpaperViewModel: model)
            do {
                _ = try queue.submitWallpaper(image("aa0001"), folderID: nil)
                preconditionFailure("A corrupt checkpoint must not be silently overwritten")
            } catch {}
            let preserved = try Data(contentsOf: checkpoint)
            precondition(preserved == raw)
            let backupFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            precondition(backupFiles.contains { $0.contains("backup-") })
        } else {
            queue.configure(wallpaperViewModel: model)
            let a = try queue.submitWallpaper(image("aa0001"), folderID: "folder-one")
            let duplicate = try queue.submitWallpaper(image("aa0001"), folderID: "folder-one")
            precondition(a == duplicate)
            let b = try queue.submitWallpaper(image("aa0002"), folderID: nil)
            let c = try queue.submitWallpaper(image("aa0003"), folderID: nil)
            _ = try await queue.waitForRemoteCompletion(id: c)
            _ = try await queue.waitForRemoteCompletion(id: a)
            _ = try await queue.waitForRemoteCompletion(id: b)
            precondition(model.attempts["aa0001"] == 1)
            precondition(model.starts.prefix(3).elementsEqual(["aa0001", "aa0002", "aa0003"]))
            precondition(model.maximumRunning == 2)
            let paused = try queue.submitWallpaper(image("aa0004"), folderID: nil)
            try await eventually { model.attempts["aa0004"] == 1 }
            queue.pause(jobID: paused)
            queue.resume(jobID: paused)
            _ = try await queue.waitForRemoteCompletion(id: paused)
            precondition(model.attempts["aa0004"] == 2)
            let cancelled = try queue.submitWallpaper(image("aa0005"), folderID: nil)
            try await eventually { model.attempts["aa0005"] == 1 }
            queue.cancel(jobID: cancelled)
            let replacement = try queue.submitWallpaper(image("aa0005"), folderID: nil)
            _ = try await queue.waitForRemoteCompletion(id: replacement)
            precondition(model.attempts["aa0005"] == 2)
            model.failing.insert("aa0006")
            let failed = try queue.submitWallpaper(image("aa0006"), folderID: nil)
            do {
                _ = try await queue.waitForRemoteCompletion(id: failed)
                preconditionFailure("Expected transfer failure")
            } catch {}
            precondition(DownloadTaskService.shared.task(for: failed)?.status == .failed)
            queue.resume(jobID: failed)
            _ = try await queue.waitForRemoteCompletion(id: failed)
            precondition(model.attempts["aa0006"] == 2)
            let stop = try queue.submitWallpaper(image("aa0007"), folderID: nil)
            try await eventually { model.attempts["aa0007"] == 1 }
            queue.prepareForProcessTermination()
            try await Task.sleep(for: .milliseconds(15))
            let snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint)) as! [String: Any]
            let jobs = snapshot["jobs"] as! [[String: Any]]
            precondition(jobs.contains { $0["id"] as? String == stop })
            precondition(model.maximumRunning <= 2)
        }
        DownloadTaskService.shared.flushPendingPersistence()
        print("PASS: production download queue \(mode)")
    }
}

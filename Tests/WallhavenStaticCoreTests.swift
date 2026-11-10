import Foundation
import CoreGraphics

@main
enum WallhavenStaticCoreTests {
    static func main() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let canvas = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
            bytesPerRow: 400, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        canvas.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        let original = canvas.makeImage()!
        var crop = DisplayCropSettings()
        precondition(!crop.needsStaticRendering)
        crop.zoom = 2
        crop.pan.x = 0
        let left = try StaticWallpaperCropRenderer.render(image: original, targetSize: CGSize(width: 100, height: 100), settings: crop)
        crop.pan.x = 1
        let right = try StaticWallpaperCropRenderer.render(image: original, targetSize: CGSize(width: 100, height: 100), settings: crop)
        func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
            let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
            let offset = y * image.bytesPerRow + x * 4
            return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
        }
        precondition(pixel(left, x: 50, y: 50)[0] > 240 && pixel(left, x: 50, y: 50)[2] < 10)
        precondition(pixel(right, x: 50, y: 50)[2] > 240 && pixel(right, x: 50, y: 50)[0] < 10)
        crop = DisplayCropSettings()
        crop.aspectPreset = .ratio1x1
        crop.letterboxColorHex = "00ff00"
        let boxed = try StaticWallpaperCropRenderer.render(image: original, targetSize: CGSize(width: 200, height: 100), settings: crop)
        precondition(pixel(boxed, x: 10, y: 50)[1] > 240 && pixel(boxed, x: 10, y: 50)[0] < 10)
        precondition(pixel(boxed, x: 60, y: 50)[0] > 240)
        crop.zoom = .infinity
        crop.pan.x = .nan
        precondition(crop.sanitized.zoom == 1 && crop.sanitized.pan.x == 0.5)
        precondition(WallpaperLibraryPath.isMigrationFile("DerivedWallpapers/StaticCrop/crop-" + String(repeating: "f", count: 32) + ".jpg"))
        print("PASS: static crop pixel pan/zoom, aspect letterbox, invalid settings and derivative path policy")
        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let response = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let wallpapers = response["data"] as! [[String: Any]]
            precondition(!wallpapers.isEmpty)
            for record in wallpapers {
                precondition(WallhavenContentPolicy.isWallpaperRecord(id: record["id"] as! String, detailURL: record["url"] as! String, imagePath: record["path"] as! String))
                let thumbs = record["thumbs"] as! [String: String]
                precondition(thumbs.values.allSatisfy { WallhavenContentPolicy.imageURL($0) != nil })
            }
            print("PASS: \(wallpapers.count) live API records and thumbnail URLs satisfy Wallhaven policy")
        }
        let bindings = WallpaperScreenIdentity.schedulerBindings(
            fingerprints: ["1": "cg:1:10:serialA:1920x1080", "2": "cg:1:20:serialB:1920x1080"],
            screens: [("1", "cg:1:20:serialB:2560x1440"), ("2", "cg:1:10:serialA:2560x1440")], allowRelativeRank: true)
        precondition(bindings == ["1": "2", "2": "1"])
        let twins = WallpaperScreenIdentity.schedulerBindings(
            fingerprints: ["1": "cg:1:10:noserial:Display:1920x1080:position:0x0", "2": "cg:1:10:noserial:Display:1920x1080:position:1920x0"],
            screens: [("1", "cg:1:10:noserial:Pantalla:2560x1440:position:0x0"), ("2", "cg:1:10:noserial:Pantalla:2560x1440:position:-2560x0")], allowRelativeRank: true)
        precondition(twins == ["1": "2", "2": "1"])
        let parked = WallpaperScreenIdentity.schedulerRelocations(keys: ["1", "2"], bindings: ["1": "2"], liveIDs: ["2"])
        precondition(parked["1"] == "2" && parked["2"] != "2")
        let configData = Data(#"{"isEnabled":true,"intervalMinutes":30,"order":"sequential","displayConfigs":{"valid":{"isEnabled":true,"intervalMinutes":15,"order":"random","includeWallpapers":true,"includeMedia":true,"folderIDs":["chosen"],"displayFingerprint":"physical-one"},"retired":{"isEnabled":true,"intervalMinutes":-1,"order":"random"},"videoOnly":{"isEnabled":true,"intervalMinutes":5,"order":"random","includeWallpapers":false},"corrupt":null},"isGlobalDisplaySyncEnabled":true,"globalDisplayConfig":{"isEnabled":true,"intervalMinutes":-2,"order":"random"}}"#.utf8)
        let migrated = try JSONDecoder().decode(SchedulerConfig.self, from: configData)
        precondition(migrated.isEnabled && migrated.intervalMinutes == 30 && migrated.order == .sequential)
        precondition(migrated.displayConfigs.count == 3)
        precondition(migrated.displayConfigs["valid"]?.folderIDs == ["chosen"])
        precondition(migrated.displayConfigs["valid"]?.displayFingerprint == "physical-one")
        precondition(migrated.displayConfigs["retired"]?.isEnabled == false)
        precondition(migrated.displayConfigs["videoOnly"]?.isEnabled == false)
        precondition(migrated.globalDisplayConfig.isOnUnlockMode && migrated.globalDisplayConfig.isEnabled)
        precondition(!migrated.storedDisplayConfig(for: "new-monitor").isEnabled)
        let configRoundTrip = try JSONDecoder().decode(SchedulerConfig.self, from: JSONEncoder().encode(migrated))
        precondition(configRoundTrip == migrated)
        let ids = ["aa0001", "aa0002", "aa0003"]
        var rotation = StaticWallpaperRotationState()
        var cycle: [String] = []
        for _ in 0..<3 {
            let next = rotation.nextID(in: ids, order: .random)!
            cycle.append(next)
            rotation.recordSelection(next, candidates: Set(ids))
        }
        precondition(Set(cycle).count == 3)
        precondition(rotation.nextID(in: ids, order: .random) != rotation.currentID)
        let currentIndex = ids.firstIndex(of: rotation.currentID!)!
        precondition(rotation.nextID(in: ids, order: .sequential) == ids[(currentIndex + 1) % ids.count])
        precondition(rotation.nextID(in: [], order: .random) == nil)
        precondition(rotation.nextID(in: ["replacement"], order: .sequential) == "replacement")
        let previous = rotation.previousID(in: Set(ids))!
        rotation.recordPrevious(previous)
        precondition(rotation.currentID == previous)
        let stateRoundTrip = try JSONDecoder().decode(StaticWallpaperRotationState.self, from: JSONEncoder().encode(rotation))
        precondition(stateRoundTrip == rotation)
        enum Kind: String, Decodable { case wallpaper }
        struct Record: Decodable {
            let id: String
            let kind: Kind
        }
        let legacy = Data(#"[{"id":"abc123","kind":"wallpaper"},{"id":"old","kind":"video"},null,{"broken":true},{"id":"def456","kind":"wallpaper"},{"id":"pixiv_123","kind":"wallpaper"}]"#.utf8)
        let result = try LegacyRecordReader.read(Record.self, from: legacy) {
            WallhavenContentPolicy.isWallpaperID($0.id)
        }
        precondition(result.records.map(\.id) == ["abc123", "def456"])
        precondition(result.rejectedCount == 4)
        var search = WallhavenAPI.SearchParameters()
        search.query = "anime mountains"
        search.page = 3
        search.categories = "010"
        search.purity = "001"
        search.sorting = "random"
        search.seed = "stable"
        search.resolutions = ["3840x2160"]
        search.ratios = ["16x9"]
        search.colors = ["ff9900"]
        let endpoint = WallhavenAPI.url(for: .search(search), apiKey: "  secret-test-key  ")!
        let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        precondition(endpoint.host == "wallhaven.cc" && endpoint.path == "/api/v1/search")
        precondition(query["q"] == "anime mountains" && query["page"] == "3")
        precondition(query["categories"] == "010" && query["purity"] == "001")
        precondition(query["seed"] == "stable" && query["colors"] == "ff9900")
        precondition(query["resolutions"] == "3840x2160" && query["ratios"] == "16x9")
        precondition(query["apikey"] == "secret-test-key")
        precondition(WallhavenAPI.authenticationHeaders(apiKey: " key ")["X-API-Key"] == "key")
        precondition(WallhavenAPI.authenticationHeaders(apiKey: " ")["X-API-Key"] == nil)
        precondition(WallhavenAPI.url(for: .wallpaper(id: "../bad")) == nil)
        precondition(WallhavenAPI.url(for: .wallpaper(id: "abc123"))?.absoluteString == "https://wallhaven.cc/api/v1/w/abc123")
        precondition(WallhavenAPI.imageURL(wallpaperId: "abc123", ext: "mp4") == nil)
        precondition(WallhavenAPI.imageURL(wallpaperId: "abc123")?.absoluteString == "https://w.wallhaven.cc/full/ab/wallhaven-abc123.jpg")
        precondition(WallhavenContentPolicy.isWallpaperRecord(id: "abc123", detailURL: "https://wallhaven.cc/w/abc123", imagePath: "https://w.wallhaven.cc/full/ab/wallhaven-abc123.jpg"))
        precondition(WallhavenContentPolicy.isWallpaperRecord(id: "abc123", detailURL: "https://whvn.cc/abc123", imagePath: "/old/downloads/original.jpg"))
        precondition(!WallhavenContentPolicy.isWallpaperRecord(id: "abc123", detailURL: "https://wallhaven.cc/w/def456", imagePath: "https://w.wallhaven.cc/full/ab/wallhaven-abc123.jpg"))
        precondition(!WallhavenContentPolicy.isWallpaperRecord(id: "abc123", detailURL: "https://wallhaven.cc/w/abc123", imagePath: "https://pixiv.net/image.jpg"))
        do {
            _ = try LegacyRecordReader.read(Record.self, from: Data("invalid json".utf8))
            preconditionFailure("Corrupt documents must not be mistaken for empty libraries")
        } catch {}
        for id in ["6d8k67", "abc123", "000000"] {
            precondition(WallhavenContentPolicy.isWallpaperID(id))
            precondition(WallhavenContentPolicy.wallpaperID(from: URL(string: "https://wallhaven.cc/w/\(id)")!) == id)
            precondition(WallhavenContentPolicy.wallpaperID(from: URL(string: "https://whvn.cc/\(id)")!) == id)
        }
        for id in ["pixiv_123", "local_abc", "../abc", "ABC123", "a", "éabcde", "1234567"] {
            precondition(!WallhavenContentPolicy.isWallpaperID(id))
        }
        for address in [
            "https://wallhaven.cc.evil.test/w/abc123", "https://evil.test/w/abc123",
            "http://wallhaven.cc/w/abc123", "https://user@wallhaven.cc/w/abc123",
            "https://wallhaven.cc:8443/w/abc123", "https://wallhaven.cc/w/abc123/extra",
            "file:///w/abc123", "https://wallhaven.cc/w/%2e%2e%2f"
        ] {
            precondition(WallhavenContentPolicy.wallpaperID(from: URL(string: address)!) == nil)
        }
        for address in [
            "https://w.wallhaven.cc/full/ab/wallhaven-abc123.jpg",
            "https://th.wallhaven.cc/lg/ab/abc123.jpg"
        ] {
            precondition(WallhavenContentPolicy.imageURL(address) != nil)
        }
        for address in [
            "https://pixiv.net/image.jpg", "https://w.wallhaven.cc.evil.test/image.jpg",
            "https://w.wallhaven.cc/video.mp4", "file:///tmp/wallpaper.jpg",
            "http://th.wallhaven.cc/image.jpg", "https://user@w.wallhaven.cc/image.jpg"
        ] {
            precondition(WallhavenContentPolicy.imageURL(address) == nil)
        }
        precondition(WallhavenContentPolicy.isImageRequestURL(URL(string: "https://a.wallhaven.cc/avatar/user.png")!))
        precondition(!WallhavenContentPolicy.isImageURL(URL(string: "https://a.wallhaven.cc/avatar/user.png")!))
        for address in ["https://a.wallhaven.cc.evil.test/avatar.png", "http://a.wallhaven.cc/avatar.png", "https://u@a.wallhaven.cc/avatar.png", "https://a.wallhaven.cc:9000/avatar.png", "https://a.wallhaven.cc/avatar.mp4"] {
            precondition(!WallhavenContentPolicy.isImageRequestURL(URL(string: address)!))
        }
        precondition(WallhavenLibraryFilePolicy.wallpaperID(relativePath: "Wallpapers/wallhaven-abc123.png") == "abc123")
        precondition(WallhavenLibraryFilePolicy.wallpaperID(relativePath: "Wallpapers/abc123.jpg") == "abc123")
        for path in ["../Wallpapers/abc123.jpg", "/Wallpapers/abc123.jpg", "Wallpapers/../abc123.jpg", "Wallpapers/a/abc123.jpg", "Media/abc123.jpg", "Wallpapers/wallhaven-abc123.mp4", "Wallpapers/ABC123.jpg", "Wallpapers/wallhaven-abc123.jpg?x", "Wallpapers//abc123.jpg"] {
            precondition(WallhavenLibraryFilePolicy.wallpaperID(relativePath: path) == nil)
        }
        precondition(WallhavenLibraryFilePolicy.originalFilename(id: "abc123", recordedPath: "/old/device/Wallpapers/wallhaven-abc123.png") == "wallhaven-abc123.png")
        precondition(WallhavenLibraryFilePolicy.originalFilename(id: "abc123", recordedPath: "/private/personal.png") == nil)
        precondition(WallhavenLibraryFilePolicy.isObjectHash(String(repeating: "f", count: 64)))
        precondition(!WallhavenLibraryFilePolicy.isObjectHash(String(repeating: "F", count: 64)))
        precondition(!WallhavenLibraryFilePolicy.isObjectHash("../object"))
        var metadata = SyncMetadata(recordID: "test", entityType: "wallpaper", updatedAt: Date(timeIntervalSince1970: 10), isDeleted: true)
        metadata.markSynced(at: Date(timeIntervalSince1970: 20))
        precondition(metadata.updatedAt == Date(timeIntervalSince1970: 10) && metadata.isDeleted && metadata.lastSyncedAt == Date(timeIntervalSince1970: 20))
        precondition(WallpaperLibraryPath.rebase("/library/Wallpapers/abc123.jpg", from: "/library", to: "/new") == "/new/Wallpapers/abc123.jpg")
        precondition(WallpaperLibraryPath.rebase("/library-sibling/abc123.jpg", from: "/library", to: "/new") == nil)
        precondition(WallpaperLibraryPath.rebaseURLString("https://wallhaven.cc/w/abc123", from: "/library", to: "/new") == nil)
        precondition(WallpaperLibraryPath.rebaseURLString("file:///library/a%20b.jpg", from: "/library", to: "/new") == "file:///new/a%20b.jpg")
        precondition(WallpaperLibraryPath.isMigrationFile("Wallpapers/wallhaven-abc123.jpg"))
        precondition(WallpaperLibraryPath.isMigrationFile("DerivedWallpapers/PortraitBlurFill/blur-fill-" + String(repeating: "f", count: 32) + ".jpg"))
        precondition(!WallpaperLibraryPath.isMigrationFile("DerivedWallpapers/PortraitBlurFill/mapping.json"))
        precondition(!WallpaperLibraryPath.isMigrationFile("Media/wallhaven-abc123.jpg"))
        precondition(!WallpaperLibraryPath.isMigrationFile("Wallpapers/../wallhaven-abc123.jpg"))
        for dimensions in [(7680.0, 4320.0), (50000, 100000), (1, 1000000)] {
            for bytes in [4, 8, 16] {
                let layout = WallpaperSnapshotPixelBudget.layout(width: dimensions.0, height: dimensions.1, decodedBytesPerPixel: bytes)!
                precondition(layout.allocationBytes <= 32 * 1024 * 1024)
                precondition(WallpaperSnapshotPixelBudget.acceptsDecodedImage(width: layout.width, height: layout.height, bytesPerRow: layout.bytesPerRow))
            }
        }
        precondition(WallpaperSnapshotPixelBudget.layout(width: .infinity, height: 100) == nil)
        precondition(WallpaperSnapshotPixelBudget.layout(width: .nan, height: 100) == nil)
        precondition(WallpaperSnapshotPixelBudget.layout(width: 0, height: 100) == nil)
        precondition(!WallpaperSnapshotPixelBudget.acceptsDecodedImage(width: 4096, height: 4096, bytesPerRow: Int.max))
        print("PASS: static rotation and config migration, mixed legacy records, Wallhaven provenance, malicious URLs and decode memory bounds")
    }
}

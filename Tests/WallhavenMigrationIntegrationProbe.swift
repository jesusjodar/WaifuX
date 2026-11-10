#if DEBUG && WAIFUX_HELPER
import AppKit
import Foundation

@MainActor
enum WallhavenMigrationIntegrationProbe {
    static func require(_ value: Bool, _ message: String) throws {
        try WallhavenCloudIntegrationProbe.require(value, message)
    }
    static func run() async throws {
        guard BackgroundRuntimeRole.isIsolatedTest,
              let path = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"],
              ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_SUITE"]?.hasPrefix("waifux-migration-integration-") == true else {
            throw WallhavenCloudIntegrationProbe.Failed(detail: "Missing isolated migration environment")
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path)
        let old = root.appendingPathComponent("source/WaifuX")
        let new = root.appendingPathComponent("destination/WaifuX")
        let original = old.appendingPathComponent("Wallpapers/wallhaven-abc123.png")
        let alias = root.appendingPathComponent("source-library-alias")
        let destination = new.appendingPathComponent("Wallpapers/wallhaven-abc123.png")
        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 2, height: 4, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 4))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 4))
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        let bytes = bitmap.representation(using: .png, properties: [:])!
        try bytes.write(to: original)
        let retired = old.appendingPathComponent("Media/episode.mp4")
        try fm.createDirectory(at: retired.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("retired episode".utf8).write(to: retired)
        let unregistered = old.appendingPathComponent("Wallpapers/unregistered.png")
        try Data("unregistered original".utf8).write(to: unregistered)
        let unrelatedEmptyDirectory = old.appendingPathComponent("Personal/Empty")
        try fm.createDirectory(at: unrelatedEmptyDirectory, withIntermediateDirectories: true)
        let sibling = URL(fileURLWithPath: old.path + "-sibling/Wallpapers/wallhaven-def456.png")
        try fm.createDirectory(at: sibling.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: sibling)
        try fm.createSymbolicLink(at: alias, withDestinationURL: old)
        let library = WallpaperLibraryService.shared
        library.restoreSavedData()
        LibraryFolderStore.shared.restoreSavedData()
        library.syncImportDownloads([
            .init(wallpaper: WallhavenCloudIntegrationProbe.image("abc123"), localFilePath: original.resolvingSymlinksInPath().path),
            .init(wallpaper: WallhavenCloudIntegrationProbe.image("def456"), localFilePath: sibling.path),
        ])
        let derived = try await DerivedStaticWallpaperService.portrait.preparedWallpaperURL(
            for: original, targetPixelSize: CGSize(width: 192, height: 108),
            derivedWallpapersDirectory: old.appendingPathComponent("DerivedWallpapers"))
        let derivedBitmap = NSBitmapImageRep(data: try Data(contentsOf: derived))
        try require(derivedBitmap?.pixelsWide == 192 && derivedBitmap?.pixelsHigh == 108
            && derivedBitmap?.cgImage?.colorSpace?.model == .rgb, "Derived image has invalid dimensions or color space")
        try require(derived != original, "Portrait fixture did not create a derived image")
        var cropSettings = DisplayCropSettings()
        cropSettings.zoom = 2
        cropSettings.pan.x = 0
        let cropped = try await DerivedStaticWallpaperService.crop.preparedWallpaperURL(
            for: original, targetPixelSize: CGSize(width: 192, height: 108),
            derivedWallpapersDirectory: old.appendingPathComponent("DerivedWallpapers"), cropSettings: cropSettings)
        let cropBytes = try Data(contentsOf: cropped)
        let newCropped = new.appendingPathComponent("DerivedWallpapers/StaticCrop/" + cropped.lastPathComponent)
        let oldMapping = old.appendingPathComponent("DerivedWallpapers/PortraitBlurFill/mapping.json")
        let oldMappingBytes = try Data(contentsOf: oldMapping)
        let newDerived = new.appendingPathComponent("DerivedWallpapers/PortraitBlurFill/" + derived.lastPathComponent)
        let preferences = WaifuXPreferences.shared
        preferences.set(try JSONEncoder().encode(GlobalWallpaperSyncCoordinator.Snapshot(localPath: original.path)), forKey: "wallhaven_global_wallpaper_last_success_v1")
        let screen = NSScreen.screens.first
        let desktopBefore = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        if let screen { DesktopWallpaperSyncManager.shared.registerWallpaperSet(derived, for: screen, sourceURL: original) }
        let conflicting = Data("different target".utf8)
        try conflicting.write(to: destination)
        let queueDirectory = root.appendingPathComponent("DownloadQueue")
        try fm.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        let queueCheckpoint = queueDirectory.appendingPathComponent("wallhaven-download-queue-v1.json")
        let queuedImage = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WallhavenCloudIntegrationProbe.image("qqq999")))
        let pendingJob: [String: Any] = ["id": "wallpaper.qqq999", "payload": ["wallpaper": ["_0": queuedImage]],
            "state": "queued", "source": "manual", "addedAt": 0, "updatedAt": 0, "attemptCount": 0]
        try JSONSerialization.data(withJSONObject: ["version": 1, "jobs": [pendingJob]]).write(to: queueCheckpoint)
        let migration = DirectoryMigrationService.shared
        let failed = await migration.migrate(from: alias, to: new) { _ in }
        guard case .partial = failed else { throw WallhavenCloudIntegrationProbe.Failed(detail: "Destination conflict was not reported") }
        try require(try Data(contentsOf: original) == bytes, "Original lost on copy conflict")
        try require(try Data(contentsOf: destination) == conflicting, "Conflicting destination overwritten")
        try require(library.downloadRecord(for: "abc123")?.localFilePath == original.resolvingSymlinksInPath().path, "Paths changed despite copy conflict")
        try fm.removeItem(at: destination)
        let result = await migration.migrate(from: alias, to: new) { _ in }
        guard case .success(let moved, let deleted) = result, moved == 3, deleted == 3 else {
            throw WallhavenCloudIntegrationProbe.Failed(detail: "Static migration failed: \(result)")
        }
        try require(try Data(contentsOf: destination) == bytes, "Copied original differs")
        try require(try Data(contentsOf: newCropped) == cropBytes && !fm.fileExists(atPath: cropped.path), "Static crop was not migrated intact")
        let cropSource = await DerivedStaticWallpaperService.crop.originalSourceURL(
            forDerivedWallpaperAt: newCropped, derivedWallpapersDirectory: new.appendingPathComponent("DerivedWallpapers"))
        try require(cropSource?.path == destination.path, "Crop source mapping was not rebased")
        let reusedCrop = try await DerivedStaticWallpaperService.crop.preparedWallpaperURL(
            for: destination, targetPixelSize: CGSize(width: 192, height: 108),
            derivedWallpapersDirectory: new.appendingPathComponent("DerivedWallpapers"), cropSettings: cropSettings)
        try require(reusedCrop == newCropped, "Migrated crop cache key did not retain settings")
        try require(!fm.fileExists(atPath: original.path) && !fm.fileExists(atPath: derived.path), "Verified sources not moved")
        try require(try Data(contentsOf: retired) == Data("retired episode".utf8), "Retired episode was changed")
        try require(try Data(contentsOf: unregistered) == Data("unregistered original".utf8), "Unregistered image was changed")
        try require(fm.fileExists(atPath: unrelatedEmptyDirectory.path), "Unrelated empty directory was deleted")
        try require(library.downloadRecord(for: "abc123")?.localFilePath == destination.path, "Download path was not rebased")
        try require(library.downloadRecord(for: "def456")?.localFilePath == sibling.path, "Sibling directory path was rebased")
        try require(library.verifyPersistedRecords(), "Migration records were not durable")
        try require(GlobalWallpaperSyncCoordinator.shared.lastSuccessfulApply?.localPath == destination.path, "Global snapshot path was not rebased")
        let recoveredOriginal = await DerivedStaticWallpaperService.portrait.originalSourceURL(
            forDerivedWallpaperAt: newDerived, derivedWallpapersDirectory: new.appendingPathComponent("DerivedWallpapers"))
        try require(recoveredOriginal?.path == destination.path, "Derived-to-original mapping was not migrated")
        try require(try Data(contentsOf: oldMapping) == oldMappingBytes, "Original artifact metadata was overwritten")
        if let screen {
            try require(DesktopWallpaperSyncManager.shared.imageURL(for: screen)?.path == newDerived.path, "Desktop registration was not rebased")
            try require(NSWorkspace.shared.desktopImageURL(for: screen) == desktopBefore, "Isolated test changed the desktop")
        }
        let durableQueue = try JSONSerialization.jsonObject(with: Data(contentsOf: queueCheckpoint)) as! [String: Any]
        try require((durableQueue["jobs"] as? [[String: Any]])?.contains { $0["id"] as? String == "wallpaper.qqq999" } == true,
            "Migration before executor configuration discarded queued downloads")
        let newMapping = new.appendingPathComponent("DerivedWallpapers/PortraitBlurFill/mapping.json")
        let newMappingBytes = try Data(contentsOf: newMapping)
        _ = await DerivedStaticWallpaperService.portrait.originalSourceURL(forDerivedWallpaperAt: newDerived,
            derivedWallpapersDirectory: root.appendingPathComponent("absent-derived-directory"))
        try Data("corrupt mapping".utf8).write(to: newMapping)
        let corruptLookup = await DerivedStaticWallpaperService.portrait.originalSourceURL(forDerivedWallpaperAt: newDerived,
            derivedWallpapersDirectory: new.appendingPathComponent("DerivedWallpapers"))
        try require(corruptLookup == nil, "Corrupt derived mapping was accepted")
        try newMappingBytes.write(to: newMapping)
        let repairedLookup = await DerivedStaticWallpaperService.portrait.originalSourceURL(forDerivedWallpaperAt: newDerived,
            derivedWallpapersDirectory: new.appendingPathComponent("DerivedWallpapers"))
        try require(repairedLookup?.path == destination.path, "A failed derived mapping read poisoned the next retry")
        let scopedOnly = old.appendingPathComponent("Wallpapers/wallhaven-ghi789.png")
        try bytes.write(to: scopedOnly)
        library.syncImportDownloads([.init(wallpaper: WallhavenCloudIntegrationProbe.image("ghi789"), localFilePath: scopedOnly.path)])
        library.bulkUpdateDownloadPaths(oldPrefix: old.path, newPrefix: new.path, wallpaperIDs: ["abc123"])
        try require(library.downloadRecord(for: "ghi789")?.localFilePath == scopedOnly.path,
            "Scoped orphan repair rebased an unrelated record")
        // Old broad checkpoints remain read-only. They cannot resume deleting retired media.
        let oldCheckpoint = Data("legacy migration containing Media/episode.mp4".utf8)
        preferences.set(oldCheckpoint, forKey: "migration_state_v1")
        await migration.recoverIncompleteMigrationIfNeeded()
        try require(preferences.data(forKey: "migration_state_v1") == oldCheckpoint, "Legacy checkpoint was discarded")
        try require(fm.fileExists(atPath: retired.path), "Legacy deletion resumed")
        // A modern checkpoint can only delete its explicit, verified static paths.
        try bytes.write(to: original)
        let checkpoint: [String: Any] = ["phase": "deleting", "oldPath": old.path, "newPath": new.path,
            "copiedFileCount": 1, "relativePaths": ["Wallpapers/wallhaven-abc123.png"]]
        preferences.set(try JSONSerialization.data(withJSONObject: checkpoint), forKey: "wallhaven_migration_state_v2")
        await migration.recoverIncompleteMigrationIfNeeded()
        try require(!fm.fileExists(atPath: original.path) && fm.fileExists(atPath: retired.path), "Recovery exceeded its whitelist")
        preferences.set(Data("corrupt checkpoint".utf8), forKey: "wallhaven_migration_state_v2")
        let corrupt = await migration.migrate(from: alias, to: new) { _ in }
        guard case .failure = corrupt else { throw WallhavenCloudIntegrationProbe.Failed(detail: "Corrupt checkpoint accepted") }
        try require(fm.fileExists(atPath: retired.path), "Corrupt migration changed legacy files")
        let desktopCheck = screen == nil ? "desktop check unavailable" : "desktop unchanged"
        print("PASS: real helper static directory migration, conflict preservation, derived images, durable path rebasing, sibling paths, explicit recovery and legacy file preservation; \(desktopCheck)")
    }
}
#endif

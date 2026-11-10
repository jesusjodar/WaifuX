import Foundation
import Combine

@MainActor
final class CloudSyncService: ObservableObject {
    static let shared = CloudSyncService()

    // MARK: - Published 状态
    @Published var isSyncing: Bool = false
    @Published var lastSyncedAt: Date?
    @Published var lastError: Error?
    @Published var syncProgress: Double = 0  // 0.0 ~ 1.0
    @Published var syncStatusMessage: String = ""

    // MARK: - 依赖
    private let config = CloudSyncConfiguration.shared
    private let fileEngine = CloudSyncFileEngine.shared
    private let webDAVEngine = CloudSyncWebDAVEngine.shared
    private let metadataEngine = CloudSyncMetadataEngine.shared
    private let conflictResolver = CloudSyncConflictResolver.self

    private var cancellables = Set<AnyCancellable>()
    private var exitSyncTask: Task<Void, Never>?

    private init() {
        lastSyncedAt = config.lastSyncedAt
        #if !WAIFUX_HELPER
        BackgroundAgentClient.shared.observe { [weak self] values in
            if let cloud = values["cloud"] as? [String: Any] { self?.applyRemoteSnapshot(cloud) }
        }
        #endif
    }

    // MARK: - 主同步入口

    /// 执行完整同步（元数据 + 文件）
    func sync() async {
        #if !WAIFUX_HELPER
        await requestRemote("cloud.sync.wait")
        return
        #else
        guard !isSyncing else {
            lastError = CloudSyncError.syncInProgress
            return
        }
        guard !DirectoryMigrationService.shared.isMigrating else {
            lastError = CloudSyncError.internalError(reason: t("migration.busy"))
            return
        }
        prepareLocalState()

        isSyncing = true
        lastError = nil
        syncProgress = 0
        syncStatusMessage = t("准备同步...")

        defer { isSyncing = false }

        do {
            switch config.syncMode {
            case .localFolder:
                try await performLocalSync()
            case .webDAV:
                try await performWebDAVSync()
            }
            let now = Date()
            config.lastSyncedAt = now
            lastSyncedAt = now
        } catch let error as CloudSyncError {
            lastError = error
            syncStatusMessage = String(format: t("同步失败: %@"), String(describing: error.localizedDescription))
        } catch {
            lastError = CloudSyncError.internalError(reason: error.localizedDescription)
            syncStatusMessage = String(format: t("同步失败: %@"), String(describing: error.localizedDescription))
        }
        #endif
    }

    // MARK: - 本地文件夹同步

    private func performLocalSync() async throws {
        guard config.isEnabled, let syncRoot = config.syncRootURL,
              let manifestURL = config.manifestURL, let metadataURL = config.metadataURL,
              let objectsDir = config.objectsURL else { throw CloudSyncError.syncDirectoryNotSet }
        try await fileEngine.ensureSyncDirectory(at: syncRoot)
        let cloudManifest = try await fileEngine.readManifest(from: manifestURL)
        if let metadata = try localCloudMetadata() {
            try metadataEngine.importMetadata(from: metadata, strategy: config.conflictStrategy)
        }
        let manager = DownloadPathManager.shared
        let localManifest = try await scanLocalFiles(downloadMgr: manager)
        try await performFileSync(localManifest: localManifest, cloudManifest: cloudManifest,
            downloadMgr: manager,
            uploadFile: { url, hash in try await self.fileEngine.uploadFile(localURL: url, hash: hash, objectsDir: objectsDir) },
            downloadFile: { hash, url in try await self.fileEngine.downloadFile(hash: hash, objectsDir: objectsDir, destinationURL: url) })
        try metadataEngine.exportMetadata().write(to: metadataURL, options: .atomic)
        let files = try await scanLocalFiles(downloadMgr: manager)
        try await fileEngine.writeManifest(.init(files: files, updatedAt: Date()), to: manifestURL)
        syncProgress = 1
        syncStatusMessage = t("同步完成")
    }

    // MARK: - WebDAV 同步

    private func performWebDAVSync() async throws {
        guard config.isEnabled, let credentials = config.webDAVCredentials else { throw CloudSyncError.syncDirectoryNotSet }
        try await webDAVEngine.ensureSyncDirectory(baseURL: credentials.baseURL, credentials: credentials)
        let cloudManifest = try await webDAVEngine.readManifest(baseURL: credentials.syncRootURL, credentials: credentials)
        if let metadata = try await remoteCloudMetadata(credentials) {
            try metadataEngine.importMetadata(from: metadata, strategy: config.conflictStrategy)
        }
        let manager = DownloadPathManager.shared
        let localManifest = try await scanLocalFiles(downloadMgr: manager)
        try await performFileSync(localManifest: localManifest, cloudManifest: cloudManifest,
            downloadMgr: manager,
            uploadFile: { url, hash in try await self.webDAVEngine.uploadFile(localURL: url, hash: hash, objectsBaseURL: credentials.objectsURL, credentials: credentials) },
            downloadFile: { hash, url in try await self.webDAVEngine.downloadFile(hash: hash, objectsBaseURL: credentials.objectsURL, destinationURL: url, credentials: credentials) })
        try await client.put(url: credentials.metadataURL, data: metadataEngine.exportMetadata(), contentType: "application/json", credentials: credentials)
        let files = try await scanLocalFiles(downloadMgr: manager)
        try await webDAVEngine.writeManifest(.init(files: files, updatedAt: Date()), baseURL: credentials.syncRootURL, credentials: credentials)
        syncProgress = 1
        syncStatusMessage = t("同步完成")
    }

    // 访问 WebDAV client 用于 PUT/GET metadata
    private var client: CloudSyncWebDAVClient { .shared }

    // MARK: - 公共同步子步骤

    /// Scan the retained static wallpaper directory.
    private func authorizedOriginals(downloadMgr: DownloadPathManager) -> [String: URL] {
        var result: [String: URL] = [:]
        for record in WallpaperLibraryService.shared.downloadRecords where record.isActive {
            let wallpaper = record.wallpaper
            guard WallhavenContentPolicy.isWallpaperRecord(id: wallpaper.id, detailURL: wallpaper.url, imagePath: wallpaper.path),
                  let relative = WallhavenLibraryFilePolicy.relativePath(id: wallpaper.id, recordedPath: record.localFilePath),
                  let destination = WallhavenLibraryFilePolicy.destination(relativePath: relative, root: downloadMgr.rootFolderURL),
                  destination.path == URL(fileURLWithPath: record.localFilePath).standardizedFileURL.path else { continue }
            result[relative] = destination
        }
        return result
    }

    private func scanLocalFiles(downloadMgr: DownloadPathManager) async throws -> [String: CloudSyncManifest.CloudSyncManifestEntry] {
        try await fileEngine.scanLocalFiles(authorizedOriginals(downloadMgr: downloadMgr), root: downloadMgr.rootFolderURL)
    }

    private func localCloudMetadata() throws -> Data? {
        guard let current = config.metadataURL else { return nil }
        for url in [current, current.deletingLastPathComponent().appendingPathComponent(CloudSyncDirectoryLayout.legacyMetadataFileName)] {
            if FileManager.default.fileExists(atPath: url.path) { return try Data(contentsOf: url) }
        }
        return nil
    }

    private func remoteCloudMetadata(_ credentials: WebDAVCredentials) async throws -> Data? {
        for name in [CloudSyncDirectoryLayout.metadataFileName, CloudSyncDirectoryLayout.legacyMetadataFileName] {
            do { return try await client.get(url: credentials.syncRootURL.appendingPathComponent(name), credentials: credentials) }
            catch let error as CloudSyncError {
                guard case .webDAVNotFound = error else { throw error }
            }
        }
        return nil
    }

    /// 上传/下载文件循环
    private func performFileSync(
        localManifest: [String: CloudSyncManifest.CloudSyncManifestEntry],
        cloudManifest: CloudSyncManifest,
        downloadMgr: DownloadPathManager,
        uploadFile: (URL, String) async throws -> Void,
        downloadFile: (String, URL) async throws -> Void
    ) async throws {
        guard cloudManifest.version == 1 else { throw CloudSyncError.manifestCorrupted }
        let authorized = authorizedOriginals(downloadMgr: downloadMgr)
        let cloudFiles = cloudManifest.files.filter { path, entry in
            authorized[path] != nil && WallhavenLibraryFilePolicy.isObjectHash(entry.hash) && entry.size >= 0
        }
        let total = max(1, localManifest.count + cloudFiles.count)
        var processed = 0
        for (path, entry) in localManifest {
            try Task.checkCancellation()
            if conflictResolver.resolveFile(localHash: entry.hash, cloudHash: cloudFiles[path]?.hash, strategy: config.conflictStrategy) == .upload,
               let url = authorized[path] {
                try await uploadFile(url, entry.hash)
            }
            processed += 1
            syncProgress = 0.15 + Double(processed) / Double(total) * 0.65
        }
        for (path, entry) in cloudFiles {
            try Task.checkCancellation()
            guard conflictResolver.resolveFile(localHash: localManifest[path]?.hash, cloudHash: entry.hash, strategy: config.conflictStrategy) == .download,
                  let destination = WallhavenLibraryFilePolicy.destination(relativePath: path, root: downloadMgr.rootFolderURL) else { continue }
            try await downloadFile(entry.hash, destination)
            processed += 1
            syncProgress = 0.15 + Double(processed) / Double(total) * 0.65
        }
    }

    // MARK: - 从云端恢复（首次配置）

    func restoreFromCloud() async {
        #if !WAIFUX_HELPER
        await requestRemote("cloud.restore.wait")
        return
        #else
        guard !isSyncing else { return }
        guard !DirectoryMigrationService.shared.isMigrating else {
            lastError = CloudSyncError.internalError(reason: t("migration.busy"))
            return
        }
        prepareLocalState()

        isSyncing = true
        lastError = nil
        syncProgress = 0
        syncStatusMessage = t("从云端恢复...")

        defer {
            isSyncing = false
        }

        do {
            switch config.syncMode {
            case .localFolder:
                try await performLocalRestore()
            case .webDAV:
                try await performWebDAVRestore()
            }

            let now = Date()
            config.lastSyncedAt = now
            lastSyncedAt = now
        } catch let error as CloudSyncError {
            lastError = error
            syncStatusMessage = String(format: t("恢复失败: %@"), String(describing: error.localizedDescription))
        } catch {
            lastError = CloudSyncError.internalError(reason: error.localizedDescription)
            syncStatusMessage = String(format: t("恢复失败: %@"), String(describing: error.localizedDescription))
        }
        #endif
    }

    private func performLocalRestore() async throws {
        guard let manifestURL = config.manifestURL, let objects = config.objectsURL,
              let metadata = try localCloudMetadata() else { throw CloudSyncError.metadataReadFailed }
        let manifest = try await fileEngine.readManifest(from: manifestURL)
        try metadataEngine.importMetadata(from: metadata, strategy: .cloudPreferred)
        try await restoreFiles(manifest: manifest) { hash, url in
            try await self.fileEngine.downloadFile(hash: hash, objectsDir: objects, destinationURL: url)
        }
    }

    private func performWebDAVRestore() async throws {
        guard let credentials = config.webDAVCredentials,
              let metadata = try await remoteCloudMetadata(credentials) else { throw CloudSyncError.metadataReadFailed }
        let manifest = try await webDAVEngine.readManifest(baseURL: credentials.syncRootURL, credentials: credentials)
        try metadataEngine.importMetadata(from: metadata, strategy: .cloudPreferred)
        try await restoreFiles(manifest: manifest) { hash, url in
            try await self.webDAVEngine.downloadFile(hash: hash, objectsBaseURL: credentials.objectsURL, destinationURL: url, credentials: credentials)
        }
    }

    private func restoreFiles(manifest: CloudSyncManifest, download: (String, URL) async throws -> Void) async throws {
        guard manifest.version == 1 else { throw CloudSyncError.manifestCorrupted }
        let manager = DownloadPathManager.shared
        let authorized = authorizedOriginals(downloadMgr: manager)
        let files = manifest.files.filter { path, entry in authorized[path] != nil && WallhavenLibraryFilePolicy.isObjectHash(entry.hash) && entry.size >= 0 }
        var processed = 0
        for (path, entry) in files {
            try Task.checkCancellation()
            guard let destination = WallhavenLibraryFilePolicy.destination(relativePath: path, root: manager.rootFolderURL) else { continue }
            try await download(entry.hash, destination)
            processed += 1
            syncProgress = Double(processed) / Double(max(1, files.count))
        }
        syncProgress = 1
        syncStatusMessage = t("恢复完成")
    }

    // MARK: - 应用退出时自动同步

    func syncOnAppTerminate() {
        #if !WAIFUX_HELPER
        BackgroundAgentClient.shared.send("cloud.syncOnUIExit")
        #else
        guard !isSyncing, exitSyncTask == nil else { return }
        config.reloadFromPreferences()
        guard config.isEnabled else { return }
        exitSyncTask = Task {
            await sync()
            exitSyncTask = nil
        }
        #endif
    }

    // MARK: - 错误清理

    func clearError() {
        lastError = nil
        syncStatusMessage = ""
        #if !WAIFUX_HELPER
        BackgroundAgentClient.shared.send("cloud.clearError")
        #endif
    }

    func backgroundSnapshot() -> [String: Any] {
        var state: [String: Any] = ["running": isSyncing, "progress": syncProgress,
            "status": syncStatusMessage, "error": lastError?.localizedDescription ?? ""]
        if let lastSyncedAt { state["lastSyncedAt"] = lastSyncedAt.timeIntervalSince1970 }
        return state
    }

    #if WAIFUX_HELPER
    private func prepareLocalState() {
        config.reloadFromPreferences()
        LibraryGridOrderStore.shared.reloadFromPreferences()
    }
    #else
    private func applyRemoteSnapshot(_ state: [String: Any]) {
        isSyncing = state["running"] as? Bool ?? false
        syncProgress = state["progress"] as? Double ?? 0
        syncStatusMessage = state["status"] as? String ?? ""
        if let timestamp = state["lastSyncedAt"] as? Double { lastSyncedAt = Date(timeIntervalSince1970: timestamp) }
        let message = state["error"] as? String ?? ""
        lastError = message.isEmpty ? nil : NSError(domain: "WaifuXCloudSync", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func requestRemote(_ operation: String) async {
        do {
            let response = try await BackgroundAgentClient.shared.request(operation)
            if let state = response["cloud"] as? [String: Any] { applyRemoteSnapshot(state) }
            WaifuXPreferences.shared.synchronize()
            LibraryGridOrderStore.shared.reloadFromPreferences()
        } catch {
            isSyncing = false
            lastError = error
            syncStatusMessage = error.localizedDescription
        }
    }
    #endif
}

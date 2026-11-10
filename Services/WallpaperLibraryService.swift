import Foundation
import Combine

private func mergedByStableID<Record>(
    primary: [Record],
    fallback: [Record],
    id: (Record) -> String
) -> [Record] {
    var seen = Set<String>()
    var merged: [Record] = []
    for record in primary + fallback where seen.insert(id(record)).inserted {
        merged.append(record)
    }
    return merged
}

@MainActor
final class WallpaperLibraryService: ObservableObject {
    static let shared = WallpaperLibraryService()

    @Published private(set) var favoriteRecords: [WallpaperFavoriteRecord] = [] {
        didSet { rebuildFavoriteIndex() }
    }
    @Published private(set) var downloadRecords: [WallpaperDownloadRecord] = [] {
        didSet { rebuildDownloadIndex() }
    }

    // MARK: - 持久化（Cache 替代 UserDefaults）

    private let cache = CachePersistenceService.shared
    private let favCategory = "wallpaper/fav"
    private let dlCategory = "wallpaper/dl"

    /// UserDefaults key — 仅迁移用
    private let favoriteRecordsKey = "wallpaper_favorite_records_v2"
    private let downloadRecordsKey = "wallpaper_download_records_v2"
    private let legacyFavoritesKey = "local_favorites"
    private let legacyCloudFavoritesKey = "cloud_favorites"
    private let legacyDownloadsKey = "wallpaper_downloads_v1"
    private let defaults = WaifuXPreferences.shared

    /// ⚡ 快速查找索引：活跃收藏/下载的 ID 集合，避免主线程线性扫描
    private var favoriteIDSet: Set<String> = []
    private var downloadIDSet: Set<String> = []
    /// 下载记录字典索引（wallpaper.id → record），O(1) 查找替代 O(n) first(where:)
    private var downloadRecordIndex: [String: WallpaperDownloadRecord] = [:]
    /// 文件存在性缓存，避免主线程反复 FileManager.fileExists(atPath:)
    private let fileCache = FileExistenceCache.shared

    func backgroundLibrarySnapshot() -> Data {
        (try? BackgroundPropertyList.encode([
            "favorites": JSONEncoder().encode(favoriteRecords),
            "downloads": JSONEncoder().encode(downloadRecords)
        ])) ?? Data()
    }

    private init() {
        if BackgroundRuntimeRole.isRemoteUI {
            BackgroundRuntimeBridge.observeLibrary { [weak self] values in
                guard let self, let data = values["wallpaper"] as? Data, let snapshot = try? BackgroundPropertyList.decode(data) else { return }
                if let bytes = snapshot["favorites"] as? Data, let records = try? LegacyRecordReader.read(WallpaperFavoriteRecord.self, from: bytes).records { self.favoriteRecords = records.filter { Self.isWallhaven($0.wallpaper) } }
                if let bytes = snapshot["downloads"] as? Data, let records = try? LegacyRecordReader.read(WallpaperDownloadRecord.self, from: bytes).records { self.downloadRecords = records.filter { Self.isWallhaven($0.wallpaper) } }
            }
            return
        }

        // ⚠️ 不在 init 中读 UserDefaults，避免 _CFXPreferences 递归栈溢出
        // 用静态数组持有 observer token（非 Sendable），避免 deinit 中访问 actor 隔离属性
        Self.registerMemoryPressureObserver(service: self)
    }

    /// 持有所有 observer tokens，避免被 dealloc 导致 observer 自动移除
    private static var _observerTokens: [Any] = []
    private static func registerMemoryPressureObserver(service: WallpaperLibraryService) {
        let token = NotificationCenter.default.addObserver(
            forName: .appDidReceiveMemoryPressure,
            object: nil,
            queue: nil,
            using: { _ in
                Task { @MainActor in
                    service.fileCache.clearAll()
                }
            }
        )
        _observerTokens.append(token)
    }

    /// 延迟恢复持久化数据（必须在 AppDelegate.applicationDidFinishLaunching 中调用）
    func restoreSavedData() {
        guard BackgroundRuntimeRole.isHelper else { return }
        loadPersistedState()
    }

    private func rebuildFavoriteIndex() {
        favoriteIDSet = Set(favoriteRecords.filter(\.isActive).map(\.wallpaper.id))
    }

    private func rebuildDownloadIndex() {
        downloadIDSet = Set(downloadRecords.filter(\.isActive).map(\.wallpaper.id))
        downloadRecordIndex = Dictionary(
            downloadRecords.filter(\.isActive).map { ($0.wallpaper.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    var favoriteWallpapers: [Wallpaper] {
        favoriteRecords
            .filter(\.isActive)
            .map(\.wallpaper)
    }

    /// 获取指定文件夹内的收藏壁纸
    func favoriteWallpapers(inFolder folderID: String?) -> [Wallpaper] {
        let target = Self.normalizedFolderID(folderID)
        return favoriteRecords
            .filter { $0.isActive && Self.normalizedFolderID($0.folderID) == target }
            .map(\.wallpaper)
    }

    /// 获取指定文件夹内的下载壁纸
    func downloadedWallpapers(inFolder folderID: String?) -> [WallpaperDownloadRecord] {
        let target = Self.normalizedFolderID(folderID)
        return downloadRecords.filter {
            $0.isActive && Self.normalizedFolderID($0.folderID) == target
        }
    }

    var downloadedWallpapers: [WallpaperDownloadRecord] {
        downloadRecords.filter(\.isActive)
    }

    var pendingSyncFavorites: [WallpaperFavoriteRecord] {
        favoriteRecords.filter { $0.metadata.syncState != .synced || $0.metadata.isDeleted }
    }

    var pendingSyncDownloads: [WallpaperDownloadRecord] {
        downloadRecords.filter { $0.metadata.syncState != .synced || $0.metadata.isDeleted }
    }

    func toggleFavorite(_ wallpaper: Wallpaper) {
        guard Self.isWallhaven(wallpaper) else { return }
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.toggleFavorite0", ["wallpaper": try? JSONEncoder().encode(wallpaper)]); return }

        // ⚡ 先用 Set 快速判断是否存在，避免全表 firstIndex 线性扫描
        if let index = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id && $0.isActive }) {
            favoriteRecords[index].wallpaper = wallpaper
            favoriteRecords[index].metadata.markLocalMutation(deleted: true)
        } else if let index = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
            // 已存在但不活跃（软删除），重新激活
            favoriteRecords[index].wallpaper = wallpaper
            favoriteRecords[index].metadata.markLocalMutation(deleted: false)
        } else {
            favoriteRecords.insert(WallpaperFavoriteRecord(wallpaper: wallpaper), at: 0)
        }

        favoriteRecords = deduplicated(favoriteRecords)
        // 单条写入 Cache
        if let record = favoriteRecords.first(where: { $0.wallpaper.id == wallpaper.id }) {
            saveFavToCache(record)
        }
        syncFavIndex()
    }

    func isFavorite(_ wallpaper: Wallpaper) -> Bool {
        // ⚡ O(1) Set 查找，替代线性扫描
        favoriteIDSet.contains(wallpaper.id)
    }

    func isFavorite(id: String) -> Bool {
        favoriteIDSet.contains(id)
    }

    func favoriteRecord(for wallpaperID: String) -> WallpaperFavoriteRecord? {
        guard favoriteIDSet.contains(wallpaperID) else { return nil }
        return favoriteRecords.first { $0.wallpaper.id == wallpaperID && $0.isActive }
    }

    func downloadRecord(for wallpaperID: String) -> WallpaperDownloadRecord? {
        guard downloadIDSet.contains(wallpaperID) else { return nil }
        return downloadRecordIndex[wallpaperID]
    }

    func downloadRecord(forLocalFilePath path: String) -> WallpaperDownloadRecord? {
        downloadRecords.first { $0.localFilePath == path && $0.isActive }
    }

    /// 通过壁纸的远程 URL（path 字段）反查下载记录
    func downloadRecord(forRemoteURL url: URL) -> WallpaperDownloadRecord? {
        let urlString = url.absoluteString
        return downloadRecords.first { record in
            record.isActive && record.wallpaper.path == urlString
        }
    }

    func markAsLooped(localFilePath path: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.markAsLooped0", ["path": path]); return }

        guard let index = downloadRecords.firstIndex(where: { $0.localFilePath == path }) else { return }
        downloadRecords[index].isLooped = true
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
    }

    func isDownloaded(_ wallpaper: Wallpaper) -> Bool {
        // ⚡ 先通过 Set 快速判断（O(1)），再通过字典索引 O(1) 获取记录
        guard downloadIDSet.contains(wallpaper.id),
              let record = downloadRecordIndex[wallpaper.id] else {
            return false
        }
        // 使用缓存检查文件存在性，避免主线程 FileManager.fileExists(atPath:)
        let fileExists = fileCache.fileExists(atPath: record.localFilePath)
        if !fileExists {
            print("[WallpaperLibraryService] File not found for downloaded wallpaper: \(wallpaper.id) at \(record.localFilePath)")
        }
        return fileExists
    }

    /// 已下载或本地导入壁纸的可分享文件 URL（文件需在磁盘上存在）
    func localFileURLIfAvailable(for wallpaper: Wallpaper) -> URL? {
        if wallpaper.id.hasPrefix("local_"),
           let u = wallpaper.fullImageURL,
           u.isFileURL,
           fileCache.fileExists(atPath: u.path) {
            return u
        }
        guard downloadIDSet.contains(wallpaper.id),
              let record = downloadRecordIndex[wallpaper.id] else {
            return nil
        }
        let url = URL(fileURLWithPath: record.localFilePath)
        guard fileCache.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 登记下载记录。
    /// - Parameter folderID: 可选目标文件夹。传入时写入/覆盖归属；
    ///   不传时保留已有 folderID（避免二次 record 把作者批量下载归夹冲掉）。
    func recordDownload(_ wallpaper: Wallpaper, fileURL: URL, folderID: String? = nil) {
        guard Self.isWallhaven(wallpaper) else { return }
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.recordDownload0", ["wallpaper": try? JSONEncoder().encode(wallpaper), "fileURL": fileURL, "folderID": folderID]); return }

        let targetFolderID = Self.normalizedFolderID(folderID)
        if let index = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
            downloadRecords[index].wallpaper = wallpaper
            downloadRecords[index].localFilePath = fileURL.path
            downloadRecords[index].downloadedAt = .now
            downloadRecords[index].metadata.markLocalMutation(deleted: false)
            // 仅在显式指定时改归属；nil 表示调用方不关心，保留现有 folderID
            if let targetFolderID {
                downloadRecords[index].folderID = targetFolderID
            }
        } else {
            downloadRecords.insert(
                WallpaperDownloadRecord(
                    wallpaper: wallpaper,
                    localFilePath: fileURL.path,
                    folderID: targetFolderID
                ),
                at: 0
            )
        }

        // 预缓存文件存在性，后续 isDownloaded() 不再走 FileManager
        fileCache.markExisting(atPath: fileURL.path)

        // 单条写入 Cache；强制数组重赋值以触发 didSet / downloadIDSet 重建
        let record = downloadRecords.first { $0.wallpaper.id == wallpaper.id }
        if let record { saveDlToCache(record) }
        syncDlIndex()
        downloadRecords = Array(downloadRecords)
        upsert(wallpaper)
    }

    func upsert(_ wallpaper: Wallpaper) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.upsert0", ["wallpaper": try? JSONEncoder().encode(wallpaper)]); return }

        if let favoriteIndex = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
            favoriteRecords[favoriteIndex].wallpaper = wallpaper
            saveFavToCache(favoriteRecords[favoriteIndex])
            syncFavIndex()
            favoriteRecords = Array(favoriteRecords)
        }

        if let downloadIndex = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
            downloadRecords[downloadIndex].wallpaper = wallpaper
            saveDlToCache(downloadRecords[downloadIndex])
            syncDlIndex()
            downloadRecords = Array(downloadRecords)
        }
    }

    /// 批量更新壁纸（性能优化：只持久化一次）
    func upsertBatch(_ wallpapers: [Wallpaper]) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.upsertBatch0", ["wallpapers": try? JSONEncoder().encode(wallpapers)]); return }

        var favoritesChanged = false
        var downloadsChanged = false

        for wallpaper in wallpapers {
            if let favoriteIndex = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
                favoriteRecords[favoriteIndex].wallpaper = wallpaper
                favoritesChanged = true
            }

            if let downloadIndex = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
                downloadRecords[downloadIndex].wallpaper = wallpaper
                downloadsChanged = true
            }
        }

        // 批量持久化
        if favoritesChanged {
            rebuildFavCache()
            favoriteRecords = Array(favoriteRecords)
        }
        if downloadsChanged {
            rebuildDlCache()
            downloadRecords = Array(downloadRecords)
        }
    }

    /// 更新下载记录的本地文件路径
    /// 当路径检测发现文件移动到新位置时调用
    /// - Parameters:
    ///   - wallpaperID: 壁纸ID
    ///   - newURL: 新的文件URL
    func updateDownloadPath(for wallpaperID: String, newURL: URL) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.updateDownloadPath0", ["wallpaperID": wallpaperID, "newURL": newURL]); return }

        if let index = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaperID }) {
            downloadRecords[index].localFilePath = newURL.path
            saveDlToCache(downloadRecords[index])
            syncDlIndex()
            downloadRecords = Array(downloadRecords)
            print("[WallpaperLibraryService] Updated download path for \(wallpaperID) to \(newURL.path)")
        }
    }

    /// 批量替换下载记录和收藏记录中的路径前缀（用于目录迁移）
    func bulkUpdateDownloadPaths(oldPrefix: String, newPrefix: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.bulkUpdateDownloadPaths0", ["oldPrefix": oldPrefix, "newPrefix": newPrefix]); return }

        var changed = false
        // 更新下载记录
        for index in downloadRecords.indices {
            let oldPath = downloadRecords[index].localFilePath
            if oldPath.hasPrefix(oldPrefix) {
                let newPath = newPrefix + String(oldPath.dropFirst(oldPrefix.count))
                downloadRecords[index].localFilePath = newPath
                changed = true
            }
            // 更新 wallpaper 内部的路径（详情页背景使用这些字段）
            var wallpaper = downloadRecords[index].wallpaper
            if updateWallpaperPaths(&wallpaper, oldPrefix: oldPrefix, newPrefix: newPrefix) {
                downloadRecords[index].wallpaper = wallpaper
                changed = true
            }
        }
        // 更新收藏记录（封面图和详情背景同样使用 wallpaper 内部路径）
        var favoritesChanged = false
        for index in favoriteRecords.indices {
            var wallpaper = favoriteRecords[index].wallpaper
            if updateWallpaperPaths(&wallpaper, oldPrefix: oldPrefix, newPrefix: newPrefix) {
                favoriteRecords[index].wallpaper = wallpaper
                favoritesChanged = true
            }
        }
        if changed {
            rebuildDlCache()
            downloadRecords = Array(downloadRecords)
        }
        if favoritesChanged {
            rebuildFavCache()
            favoriteRecords = Array(favoriteRecords)
        }
        if changed || favoritesChanged {
            print("[WallpaperLibraryService] Bulk updated paths from \(oldPrefix) to \(newPrefix)")
        }
    }

    /// 更新 Wallpaper 内部所有路径字段；支持 file:// 前缀和普通路径
    private func updateWallpaperPaths(_ wallpaper: inout Wallpaper, oldPrefix: String, newPrefix: String) -> Bool {
        var changed = false
        if let newPath = Self.replacePathPrefix(wallpaper.url, oldPrefix: oldPrefix, newPrefix: newPrefix) {
            wallpaper.url = newPath; changed = true
        }
        if let newPath = Self.replacePathPrefix(wallpaper.path, oldPrefix: oldPrefix, newPrefix: newPrefix) {
            wallpaper.path = newPath; changed = true
        }
        if let newPath = Self.replacePathPrefix(wallpaper.thumbs.large, oldPrefix: oldPrefix, newPrefix: newPrefix) {
            wallpaper.thumbs.large = newPath; changed = true
        }
        if let newPath = Self.replacePathPrefix(wallpaper.thumbs.original, oldPrefix: oldPrefix, newPrefix: newPrefix) {
            wallpaper.thumbs.original = newPath; changed = true
        }
        if let newPath = Self.replacePathPrefix(wallpaper.thumbs.small, oldPrefix: oldPrefix, newPrefix: newPrefix) {
            wallpaper.thumbs.small = newPath; changed = true
        }
        return changed
    }

    /// 替换路径前缀；支持 file:// 前缀和普通路径
    private static func replacePathPrefix(_ path: String, oldPrefix: String, newPrefix: String) -> String? {
        // 处理 file:// 前缀的路径
        if let url = URL(string: path), url.isFileURL {
            let filePath = url.path
            if filePath.hasPrefix(oldPrefix) {
                let newPath = newPrefix + String(filePath.dropFirst(oldPrefix.count))
                return URL(fileURLWithPath: newPath).absoluteString
            }
        }
        // 普通路径匹配
        if path.hasPrefix(oldPrefix) {
            return newPrefix + String(path.dropFirst(oldPrefix.count))
        }
        return nil
    }

    // MARK: - 壁纸批量删除

    /// 批量删除壁纸收藏
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeWallpaperFavorites(withIDs ids: Set<String>) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.removeWallpaperFavorites0", ["ids": try? JSONEncoder().encode(ids)]); return }

        for (index, record) in favoriteRecords.enumerated() {
            if ids.contains(record.wallpaper.id) {
                favoriteRecords[index].metadata.markLocalMutation(deleted: true)
                saveFavToCache(favoriteRecords[index])
            }
        }
        syncFavIndex()
        favoriteRecords = Array(favoriteRecords)
    }

    /// 批量删除壁纸下载记录（含物理文件）
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeWallpaperDownloads(withIDs ids: Set<String>) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.removeWallpaperDownloads0", ["ids": try? JSONEncoder().encode(ids)]); return }

        var recordsToDelete: [WallpaperDownloadRecord] = []
        for (index, record) in downloadRecords.enumerated() {
            if ids.contains(record.wallpaper.id) {
                recordsToDelete.append(record)
                downloadRecords[index].metadata.markLocalMutation(deleted: true)
                saveDlToCache(downloadRecords[index])
            }
        }
        syncDlIndex()
        downloadRecords = Array(downloadRecords)
        // 删除所有对应的物理文件
        for record in recordsToDelete {
            wallpaperDeletePhysicalFile(at: record.localFilePath, itemID: record.wallpaper.id)
        }
    }

    /// 安全删除壁纸物理文件
    private func wallpaperDeletePhysicalFile(at path: String, itemID: String) {
        guard !path.isEmpty else { return }
        let fm = FileManager.default
        // 如果是 Workshop 下载的内容，删除整个 workshop_xxx 文件夹
        if let workshopRoot = WorkshopDownloadDeletion.rootDirectory(for: path, itemID: itemID),
           fm.fileExists(atPath: workshopRoot) {
            do {
                try fm.removeItem(atPath: workshopRoot)
                print("[WallpaperLibraryService] ✅ Deleted workshop folder: \(workshopRoot)")
            } catch {
                print("[WallpaperLibraryService] ⚠️ Failed to delete workshop folder \(workshopRoot): \(error)")
            }
            return
        }
        if fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(atPath: path)
                print("[WallpaperLibraryService] ✅ Deleted physical file: \(path)")
            } catch {
                print("[WallpaperLibraryService] ⚠️ Failed to delete file \(path): \(error)")
            }
        }
    }

    /// 清理无效下载记录（文件不存在的记录）
    /// - Returns: 清理的记录数量
    @discardableResult
    func cleanupInvalidDownloadRecords() -> Int {
        guard BackgroundRuntimeRole.isHelper else { return 0 }
        var cleanedCount = 0

        for (index, record) in downloadRecords.enumerated() {
            // 检查文件是否存在（如果是活跃记录）
            if record.isActive && !FileManager.default.fileExists(atPath: record.localFilePath) {
                print("[WallpaperLibraryService] Cleaning up invalid record: \(record.wallpaper.id), file not found at \(record.localFilePath)")
                downloadRecords[index].metadata.markLocalMutation(deleted: true)
                cleanedCount += 1
            }
        }

        if cleanedCount > 0 {
            rebuildDlCache()
            downloadRecords = Array(downloadRecords)
            print("[WallpaperLibraryService] Cleaned up \(cleanedCount) invalid download records")
        }

        return cleanedCount
    }

    /// 修复指定记录的路径（由 DirectoryMigrationService 调用）
    func repairDownloadPath(recordID: String, newPath: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.repairDownloadPath0", ["recordID": recordID, "newPath": newPath]); return }

        guard let index = downloadRecords.firstIndex(where: { $0.id == recordID }) else { return }
        downloadRecords[index].localFilePath = newPath
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
    }

    /// 将指定记录标记为已删除（由 DirectoryMigrationService 调用）
    func deactivateDownloadRecord(recordID: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.deactivateDownloadRecord0", ["recordID": recordID]); return }

        guard let index = downloadRecords.firstIndex(where: { $0.id == recordID }) else { return }
        downloadRecords[index].metadata.markLocalMutation(deleted: true)
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
    }

    // MARK: - 文件夹移动

    /// 库文件夹归属作用域。
    /// 收藏与下载各自维护独立的 folderID，绝不能互相污染。
    enum FolderMembershipScope {
        case favorites
        case downloads
    }

    /// 将空字符串 / 空白 folderID 规范为 nil（根目录）。
    static func normalizedFolderID(_ folderID: String?) -> String? {
        guard let folderID else { return nil }
        let trimmed = folderID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 将壁纸移动到指定文件夹。
    /// - Parameters:
    ///   - wallpaperID: 壁纸 ID
    ///   - folderID: 目标文件夹 ID；传 nil 表示移回根目录
    ///   - scope: 只改收藏或只改下载，禁止跨集合写 folderID
    ///   - fallback: 用于「扫描进来但还没有 DownloadRecord 的项」的回退信息。
    ///     当 scope=.downloads 且都不命中时，先调 `recordDownload` 补登记再写 folderID。
    func moveWallpaperToFolder(
        wallpaperID: String,
        folderID: String?,
        scope: FolderMembershipScope,
        fallback: (wallpaper: Wallpaper, fileURL: URL)? = nil
    ) {
        if BackgroundRuntimeRole.isRemoteUI {
            var args: [String: Any] = [
                "wallpaperID": wallpaperID,
                "scope": scope == .favorites ? "favorites" : "downloads"
            ]
            if let folderID { args["folderID"] = folderID }
            if let fallback {
                args["fallbackWallpaper"] = try? JSONEncoder().encode(fallback.wallpaper)
                args["fallbackFileURL"] = fallback.fileURL
            }
            BackgroundRuntimeBridge.send("library.wallpaper.moveToFolder0", args)
            return
        }

        let targetFolderID = Self.normalizedFolderID(folderID)

        switch scope {
        case .favorites:
            if let index = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaperID }) {
                favoriteRecords[index].folderID = targetFolderID
                saveFavToCache(favoriteRecords[index])
                syncFavIndex()
                favoriteRecords = Array(favoriteRecords)
            }
        case .downloads:
            var hit = false
            if let index = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaperID }) {
                downloadRecords[index].folderID = targetFolderID
                saveDlToCache(downloadRecords[index])
                syncDlIndex()
                downloadRecords = Array(downloadRecords)
                hit = true
            }
            if !hit, let fallback {
                recordDownload(fallback.wallpaper, fileURL: fallback.fileURL)
                if let index = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaperID }) {
                    downloadRecords[index].folderID = targetFolderID
                    saveDlToCache(downloadRecords[index])
                    syncDlIndex()
                    downloadRecords = Array(downloadRecords)
                }
            }
        }
    }

    func moveItemsToRoot(fromFolder folderID: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.moveItemsToRoot0", ["folderID": folderID]); return }

        guard let folderID = Self.normalizedFolderID(folderID) else { return }
        var favoritesChanged = false
        for index in favoriteRecords.indices where favoriteRecords[index].folderID == folderID {
            favoriteRecords[index].folderID = nil
            favoritesChanged = true
        }
        var downloadsChanged = false
        for index in downloadRecords.indices where downloadRecords[index].folderID == folderID {
            downloadRecords[index].folderID = nil
            downloadsChanged = true
        }
        if favoritesChanged {
            rebuildFavCache()
            favoriteRecords = Array(favoriteRecords)
        }
        if downloadsChanged {
            rebuildDlCache()
            downloadRecords = Array(downloadRecords)
        }
    }

    /// 审计无效 folderID：空字符串、指向不存在文件夹、或跨集合引用。
    ///
    /// 重要：该方法保持历史名称以兼容现有调用方，但现在只读并报告，
    /// 永远不会把 folderID 改成 nil，也不会重建或覆盖库缓存。
    /// 用户明确执行“移到根目录”或删除文件夹时，仍由 moveItemsToRoot()
    /// 负责执行实际变更。
    @discardableResult
    func sanitizeFolderMembership(
        validFavoriteFolderIDs: Set<String>,
        validDownloadFolderIDs: Set<String>
    ) -> Int {
        let favoriteAudit = LibraryFolderMembershipPolicy.audit(
            folderIDs: favoriteRecords.map(\.folderID),
            validFolderIDs: validFavoriteFolderIDs
        )
        let downloadAudit = LibraryFolderMembershipPolicy.audit(
            folderIDs: downloadRecords.map(\.folderID),
            validFolderIDs: validDownloadFolderIDs
        )
        let invalidCount = favoriteAudit.invalidCount + downloadAudit.invalidCount

        if invalidCount > 0 {
            let invalidIDs = favoriteAudit.invalidFolderIDs
                .union(downloadAudit.invalidFolderIDs)
                .sorted()
                .joined(separator: ",")
            print(
                "[WallpaperLibraryService] Preserved \(invalidCount) invalid folder "
                    + "membership field(s); folderIDs=\(invalidIDs)"
            )
        }
        return invalidCount
    }

    /// 把指向已不存在文件夹的 folderID 归零（移回根目录）。
    ///
    /// 仅由用户主动触发（设置 → 修复数据）调用；与启动时只读的
    /// sanitizeFolderMembership 相区分。空有效集合视为「文件夹定义尚未
    /// 加载」并中止，避免把全部有效归属清空。
    /// - Returns: 本次实际归零的记录条数（收藏 + 下载）；中止时返回 -1。
    @discardableResult
    func clearOrphanFolderMemberships(
        validFavoriteFolderIDs: Set<String>,
        validDownloadFolderIDs: Set<String>
    ) -> Int {
        guard BackgroundRuntimeRole.isHelper else { return 0 }
        guard !validFavoriteFolderIDs.isEmpty || !validDownloadFolderIDs.isEmpty else {
            print("[WallpaperLibraryService] clearOrphanFolderMemberships: empty valid folder sets, aborting")
            return -1
        }

        var clearedCount = 0
        for index in favoriteRecords.indices {
            guard let folderID = favoriteRecords[index].folderID,
                  !validFavoriteFolderIDs.contains(folderID) else { continue }
            favoriteRecords[index].folderID = nil
            clearedCount += 1
        }
        for index in downloadRecords.indices {
            guard let folderID = downloadRecords[index].folderID,
                  !validDownloadFolderIDs.contains(folderID) else { continue }
            downloadRecords[index].folderID = nil
            clearedCount += 1
        }

        guard clearedCount > 0 else { return 0 }
        rebuildFavCache()
        rebuildDlCache()
        favoriteRecords = Array(favoriteRecords)
        downloadRecords = Array(downloadRecords)
        print("[WallpaperLibraryService] Cleared \(clearedCount) orphaned folder memberships")
        return clearedCount
    }

    private static func isWallhaven(_ wallpaper: Wallpaper) -> Bool {
        WallhavenContentPolicy.isWallpaperRecord(
            id: wallpaper.id, detailURL: wallpaper.url, imagePath: wallpaper.path
        )
    }

    private func preserveLegacyCache<Record: Encodable>(_ records: [Record], key: String) {
        guard defaults.data(forKey: key) == nil, !records.isEmpty,
              let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }

    private func loadPersistedState() {
        let decoder = JSONDecoder()

        // 1) 优先从 Cache 加载，同时把旧 UserDefaults 作为一次性补缺来源
        let cachedFavs: [WallpaperFavoriteRecord] = cache.loadAll(category: favCategory)
        preserveLegacyCache(cachedFavs, key: "wallhaven_static_backup_favorites_v1")
        var migratedFavs: [WallpaperFavoriteRecord] = []


        if let data = defaults.data(forKey: favoriteRecordsKey),
           let decoded = try? LegacyRecordReader.read(WallpaperFavoriteRecord.self, from: data).records {
            migratedFavs.append(contentsOf: decoded)
        }
        if let data = defaults.data(forKey: legacyFavoritesKey),
           let decoded = try? LegacyRecordReader.read(Wallpaper.self, from: data).records {
            migratedFavs.append(contentsOf: decoded.map { WallpaperFavoriteRecord(wallpaper: $0) })
        }
        if let data = defaults.data(forKey: legacyCloudFavoritesKey),
           let decoded = try? LegacyRecordReader.read(Wallpaper.self, from: data).records {
            migratedFavs.append(contentsOf: decoded.map { WallpaperFavoriteRecord(wallpaper: $0) })
        }

        favoriteRecords = deduplicated(mergedByStableID(
            primary: cachedFavs.filter { Self.isWallhaven($0.wallpaper) },
            fallback: migratedFavs.filter { Self.isWallhaven($0.wallpaper) },
            id: \.id
        ))
        // Original legacy keys remain intact as migration backups.
        if !migratedFavs.isEmpty { _ = rebuildFavCache() }

        // --- 下载 ---
        let cachedDls: [WallpaperDownloadRecord] = cache.loadAll(category: dlCategory)
        preserveLegacyCache(cachedDls, key: "wallhaven_static_backup_downloads_v1")
        var migratedDls: [WallpaperDownloadRecord] = []


        if let data = defaults.data(forKey: downloadRecordsKey),
           let decoded = try? LegacyRecordReader.read(WallpaperDownloadRecord.self, from: data).records {
            migratedDls.append(contentsOf: decoded)
        }
        if let data = defaults.data(forKey: legacyDownloadsKey),
           let decoded = try? LegacyRecordReader.read(WallpaperDownloadRecord.self, from: data).records {
            migratedDls.append(contentsOf: decoded)
        }

        downloadRecords = mergedByStableID(
            primary: cachedDls.filter { Self.isWallhaven($0.wallpaper) },
            fallback: migratedDls.filter { Self.isWallhaven($0.wallpaper) },
            id: \.id
        )
        if !migratedDls.isEmpty { _ = rebuildDlCache() }

        // --- 孤儿记录恢复 ---
        let orphanedData = cache.recoverOrphanedRecordData(for: [favCategory, dlCategory])
        var favFixed = false
        var dlFixed = false

        if let favOrphans = orphanedData[favCategory], !favOrphans.isEmpty {
            let recovered = favOrphans.compactMap { try? decoder.decode(WallpaperFavoriteRecord.self, from: $0) }
            if !recovered.isEmpty {
                let existingIDs = Set(favoriteRecords.map(\.id))
                let newRecords = recovered.filter { Self.isWallhaven($0.wallpaper) && !existingIDs.contains($0.id) }
                if !newRecords.isEmpty {
                    favoriteRecords.append(contentsOf: newRecords)
                    favFixed = true
                    print("[WallpaperLibraryService] Recovered \(newRecords.count) orphaned favorite records from disk")
                }
            }
        }
        if let dlOrphans = orphanedData[dlCategory], !dlOrphans.isEmpty {
            let recovered = dlOrphans.compactMap { try? decoder.decode(WallpaperDownloadRecord.self, from: $0) }
            if !recovered.isEmpty {
                let existingIDs = Set(downloadRecords.map(\.id))
                let newRecords = recovered.filter { Self.isWallhaven($0.wallpaper) && !existingIDs.contains($0.id) }
                if !newRecords.isEmpty {
                    downloadRecords.append(contentsOf: newRecords)
                    dlFixed = true
                    print("[WallpaperLibraryService] Recovered \(newRecords.count) orphaned download records from disk")
                }
            }
        }
        if favFixed { rebuildFavCache() }
        if dlFixed { rebuildDlCache() }
    }

    /// 外部调用入口：批量重建下载 Cache（由 DirectoryMigrationService 等调用）
    func persistDownloads() {
        guard BackgroundRuntimeRole.isHelper else { return }
        rebuildDlCache()
    }

    // MARK: - 云同步导入方法

    /// 同步导入收藏记录（合并模式，不覆盖本地已有记录除非云端更新）
    func syncImportFavorites(_ records: [WallpaperFavoriteRecord]) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.syncImportFavorites0", ["records": try? JSONEncoder().encode(records)]); return }

        for record in records where Self.isWallhaven(record.wallpaper) {
            let id = record.id
            if let existingIndex = favoriteRecords.firstIndex(where: { $0.id == id }) {
                // 本地已存在，用云端更新覆盖
                favoriteRecords[existingIndex] = record
                _ = saveFavToCache(record)
            } else {
                // 本地不存在，新增
                favoriteRecords.append(record)
                _ = saveFavToCache(record)
            }
        }
        _ = syncFavIndex()
    }

    /// 同步导入下载记录（合并模式）
    func syncImportDownloads(_ records: [WallpaperDownloadRecord]) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.syncImportDownloads0", ["records": try? JSONEncoder().encode(records)]); return }

        for record in records where Self.isWallhaven(record.wallpaper) {
            let id = record.id
            if let existingIndex = downloadRecords.firstIndex(where: { $0.id == id }) {
                downloadRecords[existingIndex] = record
                _ = saveDlToCache(record)
            } else {
                downloadRecords.append(record)
                _ = saveDlToCache(record)
            }
        }
        rebuildDlCache()
    }

    /// 同步删除收藏（按 ID 集合）
    func syncRemoveFavorites(ids: Set<String>) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.syncRemoveFavorites0", ["ids": try? JSONEncoder().encode(ids)]); return }

        favoriteRecords.removeAll { ids.contains($0.id) }
        for id in ids {
            _ = deleteFavFromCache(id)
        }
        _ = syncFavIndex()
    }

    /// 同步删除下载（按 ID 集合）
    func syncRemoveDownloads(ids: Set<String>) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.syncRemoveDownloads0", ["ids": try? JSONEncoder().encode(ids)]); return }

        downloadRecords.removeAll { ids.contains($0.id) }
        for id in ids {
            _ = deleteDlFromCache(id)
        }
        rebuildDlCache()
    }

    // MARK: - Cache 辅助方法

    /// 保存单条收藏记录到 Cache
    @discardableResult
    private func saveFavToCache(_ record: WallpaperFavoriteRecord) -> Bool {
        cache.save(record, key: "\(favCategory)/\(record.id)")
    }

    /// 删除单条收藏记录
    @discardableResult
    private func deleteFavFromCache(_ id: String) -> Bool {
        cache.delete(key: "\(favCategory)/\(id)")
    }

    /// 保存单条下载记录到 Cache
    @discardableResult
    private func saveDlToCache(_ record: WallpaperDownloadRecord) -> Bool {
        cache.save(record, key: "\(dlCategory)/\(record.id)")
    }

    /// 删除单条下载记录
    @discardableResult
    private func deleteDlFromCache(_ id: String) -> Bool {
        cache.delete(key: "\(dlCategory)/\(id)")
    }

    /// 同步收藏索引（活跃 ID 列表）
    @discardableResult
    private func syncFavIndex() -> Bool {
        let ids = favoriteRecords.map(\.id)
        return cache.saveIndex(ids, key: "index/\(favCategory)")
    }

    /// 同步下载索引
    @discardableResult
    private func syncDlIndex() -> Bool {
        let ids = downloadRecords.map(\.id)
        return cache.saveIndex(ids, key: "index/\(dlCategory)")
    }

    /// 全量重建收藏缓存（用于迁移/批量操作后）
    @discardableResult
    private func rebuildFavCache() -> Bool {
        for record in favoriteRecords {
            guard saveFavToCache(record) else { return false }
        }
        return syncFavIndex()
    }

    /// 全量重建下载缓存
    @discardableResult
    private func rebuildDlCache() -> Bool {
        for record in downloadRecords {
            guard saveDlToCache(record) else { return false }
        }
        return syncDlIndex()
    }

    private func deduplicated(_ records: [WallpaperFavoriteRecord]) -> [WallpaperFavoriteRecord] {
        var seen = Set<String>()
        return records.filter { record in
            seen.insert(record.id).inserted
        }
    }
}

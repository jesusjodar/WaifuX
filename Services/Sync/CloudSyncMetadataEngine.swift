import Foundation

// MARK: - Metadata Payload 结构
struct CloudSyncMetadataPayload: Codable {
  var version: Int = 1
  let deviceID: String
  let syncedAt: Date
  var records: CloudSyncRecords
}

struct CloudSyncRecords: Codable {
  // 壁纸收藏/下载（已含 SyncMetadata）
  var wallpaperFavorites: [WallpaperFavoriteRecord] = []
  var wallpaperDownloads: [WallpaperDownloadRecord] = []

  // 库文件夹
  var libraryFolders: LibraryFoldersPayload?

  // Grid 排序
  var libraryGridOrder: [String: [String]]?  // scope → [id]

  // 设置
  var settings: [String: [String: AnyCodable]] = [:]  // category.rawValue → { key → value }

  enum CodingKeys: String, CodingKey {
    case wallpaperFavorites, wallpaperDownloads, libraryFolders, libraryGridOrder, settings
  }
  init() {}
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.wallpaperFavorites) {
      wallpaperFavorites = try LegacyRecordReader.read(
        WallpaperFavoriteRecord.self, from: container.superDecoder(forKey: .wallpaperFavorites)
      ).records
    }
    if container.contains(.wallpaperDownloads) {
      wallpaperDownloads = try LegacyRecordReader.read(
        WallpaperDownloadRecord.self, from: container.superDecoder(forKey: .wallpaperDownloads)
      ).records
    }
    libraryFolders = try container.decodeIfPresent(
      LibraryFoldersPayload.self, forKey: .libraryFolders)
    libraryGridOrder = try container.decodeIfPresent(
      [String: [String]].self, forKey: .libraryGridOrder)
    settings =
      try container.decodeIfPresent([String: [String: AnyCodable]].self, forKey: .settings) ?? [:]
  }
}

struct LibraryFoldersPayload: Codable {
  var wallpaper: [LibraryFolder] = []
  init(wallpaper: [LibraryFolder]) { self.wallpaper = wallpaper }
  enum CodingKeys: String, CodingKey { case wallpaper }
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.wallpaper) {
      wallpaper = try LegacyRecordReader.read(
        LibraryFolder.self, from: container.superDecoder(forKey: .wallpaper)
      ).records
    }
  }
}

// MARK: - 元数据引擎
@MainActor
final class CloudSyncMetadataEngine {
  static let shared = CloudSyncMetadataEngine()

  let configuration = CloudSyncConfiguration.shared
  let fileEngine = CloudSyncFileEngine.shared

  // MARK: - 导出

  /// 从各 Service 读取数据，组装为 payload
  func exportMetadata() throws -> Data {
    let payload = try buildPayload()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(payload)
  }

  private func buildPayload() throws -> CloudSyncMetadataPayload {
    let wallpaperLib = WallpaperLibraryService.shared
    let folderStore = LibraryFolderStore.shared
    let gridStore = LibraryGridOrderStore.shared
    let downloadMgr = DownloadPathManager.shared

    // 导出设置：将 [CloudSyncSettingsCategory: ...] 转为 [String: ...]
    let exportedSettings = CloudSyncSettingsRegistry.exportSettings()
    let settingsPayload: [String: [String: AnyCodable]] = exportedSettings.reduce(into: [:]) {
      result, pair in
      result[pair.key.rawValue] = pair.value
    }

    var records = CloudSyncRecords()
    records.wallpaperFavorites = wallpaperLib.favoriteRecords
    records.wallpaperDownloads = wallpaperLib.downloadRecords.map { record in
      var record = record
      record.localFilePath = Self.relativizePath(
        record.localFilePath, baseFolder: downloadMgr.wallpapersFolderURL.path)
      return record
    }
    records.libraryFolders = LibraryFoldersPayload(wallpaper: folderStore.wallpaperFolders)
    records.libraryGridOrder = gridStore.exportOrders()
    records.settings = settingsPayload
    return CloudSyncMetadataPayload(deviceID: Self.deviceID, syncedAt: Date(), records: records)
  }

  // MARK: - 导入

  /// 从 Data 导入元数据，根据策略合并到本地
  func importMetadata(
    from data: Data,
    strategy: CloudSyncConflictStrategy
  ) throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload: CloudSyncMetadataPayload

    do {
      payload = try decoder.decode(CloudSyncMetadataPayload.self, from: data)
    } catch {
      throw CloudSyncError.metadataCorrupted
    }

    guard payload.version == 1 else {
      throw CloudSyncError.metadataVersionMismatch(version: payload.version)
    }

    let backupKey = "wallhaven_static_cloud_metadata_backup_v1"
    if WaifuXPreferences.shared.data(forKey: backupKey) == nil {
      WaifuXPreferences.shared.set(data, forKey: backupKey)
    }
    let records = payload.records

    // 1. 合并壁纸收藏
    mergeWallpaperFavorites(records.wallpaperFavorites, strategy: strategy)

    // 2. 合并壁纸下载（含路径重建）
    mergeWallpaperDownloads(records.wallpaperDownloads, strategy: strategy)

    // 9. 合并库文件夹
    if let folders = records.libraryFolders {
      mergeLibraryFolders(folders, strategy: strategy)
    }

    // 10. 合并 Grid 排序
    if let gridOrder = records.libraryGridOrder {
      mergeGridOrder(gridOrder, strategy: strategy)
    }

    // 12. 合并设置：将 [String: ...] 转回 [CloudSyncSettingsCategory: ...]
    let typedSettings: [CloudSyncSettingsCategory: [String: AnyCodable]] = records.settings.reduce(
      into: [:]) { result, pair in
        if let category = CloudSyncSettingsCategory(rawValue: pair.key) {
          result[category] = pair.value
        }
      }
    CloudSyncSettingsRegistry.importSettings(typedSettings, strategy: strategy)

  }

  private static func isWallhaven(_ wallpaper: Wallpaper) -> Bool {
    WallhavenContentPolicy.isWallpaperRecord(
      id: wallpaper.id, detailURL: wallpaper.url, imagePath: wallpaper.path)
  }

  // MARK: - 内部：路径处理

  /// 将绝对路径转换为相对路径（相对于基础目录）
  private static func relativizePath(_ absolutePath: String, baseFolder: String) -> String {
    let prefix = baseFolder.hasSuffix("/") ? baseFolder : baseFolder + "/"
    guard absolutePath.hasPrefix(prefix) else { return absolutePath }
    var relative = String(absolutePath.dropFirst(baseFolder.count))
    if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
    return relative
  }

  /// 将相对路径还原为绝对路径
  static func absolutizePath(_ relativePath: String, baseFolder: String) -> String {
    if relativePath.hasPrefix("/") { return relativePath }  // 已经是绝对路径
    return (baseFolder as NSString).appendingPathComponent(relativePath)
  }

  // MARK: - 内部：设备 ID

  private static let deviceID: String = {
    if let stored = WaifuXPreferences.shared.string(forKey: "cloud_sync_device_id") {
      return stored
    }
    let id = UUID().uuidString
    WaifuXPreferences.shared.set(id, forKey: "cloud_sync_device_id")
    return id
  }()
}

// MARK: - 合并实现
extension CloudSyncMetadataEngine {

  // MARK: 壁纸收藏合并
  func mergeWallpaperFavorites(
    _ cloudRecords: [WallpaperFavoriteRecord], strategy: CloudSyncConflictStrategy
  ) {
    let service = WallpaperLibraryService.shared
    let localRecords = service.favoriteRecords
    var toImport: [WallpaperFavoriteRecord] = []
    var toRemoveIDs: Set<String> = []

    for cloudRecord in cloudRecords where Self.isWallhaven(cloudRecord.wallpaper) {
      let id = cloudRecord.wallpaper.id
      if let localRecord = localRecords.first(where: { $0.wallpaper.id == id }) {
        let resolution = CloudSyncConflictResolver.resolveRecord(
          localUpdatedAt: localRecord.metadata.updatedAt,
          cloudUpdatedAt: cloudRecord.metadata.updatedAt,
          localIsDeleted: localRecord.metadata.isDeleted,
          cloudIsDeleted: cloudRecord.metadata.isDeleted,
          strategy: strategy
        )
        switch resolution {
        case .useLocal: continue
        case .useCloud:
          if cloudRecord.metadata.isDeleted {
            toRemoveIDs.insert(id)
          } else {
            var merged = cloudRecord
            merged.metadata.markSynced()
            toImport.append(merged)
          }
        case .skip: continue
        }
      } else {
        guard !cloudRecord.metadata.isDeleted else { continue }
        var record = cloudRecord
        record.metadata.markSynced()
        toImport.append(record)
      }
    }

    if !toImport.isEmpty { service.syncImportFavorites(toImport) }
    if !toRemoveIDs.isEmpty { service.syncRemoveFavorites(ids: toRemoveIDs) }
  }

  // MARK: 壁纸下载合并
  func mergeWallpaperDownloads(
    _ cloudRecords: [WallpaperDownloadRecord], strategy: CloudSyncConflictStrategy
  ) {
    let service = WallpaperLibraryService.shared
    let localRecords = service.downloadRecords
    let downloadMgr = DownloadPathManager.shared
    let basePath = downloadMgr.wallpapersFolderURL.path
    var toImport: [WallpaperDownloadRecord] = []
    var toRemoveIDs: Set<String> = []

    for var cloudRecord in cloudRecords where Self.isWallhaven(cloudRecord.wallpaper) {
      let id = cloudRecord.wallpaper.id
      // 重建绝对路径
      if !cloudRecord.localFilePath.isEmpty && !cloudRecord.localFilePath.hasPrefix("/") {
        cloudRecord.localFilePath = (basePath as NSString).appendingPathComponent(
          cloudRecord.localFilePath)
      }

      if let localRecord = localRecords.first(where: { $0.wallpaper.id == id }) {
        let resolution = CloudSyncConflictResolver.resolveRecord(
          localUpdatedAt: localRecord.metadata.updatedAt,
          cloudUpdatedAt: cloudRecord.metadata.updatedAt,
          localIsDeleted: localRecord.metadata.isDeleted,
          cloudIsDeleted: cloudRecord.metadata.isDeleted,
          strategy: strategy
        )
        switch resolution {
        case .useLocal: continue
        case .useCloud:
          if cloudRecord.metadata.isDeleted {
            toRemoveIDs.insert(id)
          } else {
            var merged = cloudRecord
            merged.metadata.markSynced()
            toImport.append(merged)
          }
        case .skip: continue
        }
      } else {
        guard !cloudRecord.metadata.isDeleted else { continue }
        var record = cloudRecord
        record.metadata.markSynced()
        toImport.append(record)
      }
    }

    if !toImport.isEmpty { service.syncImportDownloads(toImport) }
    if !toRemoveIDs.isEmpty { service.syncRemoveDownloads(ids: toRemoveIDs) }
  }

  // MARK: 库文件夹合并
  func mergeLibraryFolders(
    _ cloudFolders: LibraryFoldersPayload, strategy: CloudSyncConflictStrategy
  ) {
    guard strategy == .cloudPreferred else { return }
    let store = LibraryFolderStore.shared
    store.syncImportWallpaperFolders(cloudFolders.wallpaper)
  }

  // MARK: Grid 排序合并
  func mergeGridOrder(_ cloudOrder: [String: [String]], strategy: CloudSyncConflictStrategy) {
    guard strategy == .cloudPreferred else { return }
    let store = LibraryGridOrderStore.shared
    store.syncImportOrders(cloudOrder)
  }

}

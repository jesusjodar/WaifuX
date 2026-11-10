import Foundation

// MARK: - 同步模式
enum CloudSyncMode: String, Codable, CaseIterable {
    /// 本地文件夹模式（iCloud/Dropbox/SMB 挂载）
    case localFolder
    /// WebDAV 远程服务器模式
    case webDAV
}

// MARK: - 冲突策略
enum CloudSyncConflictStrategy: String, Codable, CaseIterable {
    case localPreferred   // 本地方优先（默认）
    case cloudPreferred   // 云端优先

    var displayName: String {
        switch self {
        case .localPreferred: return t("本地方优先")
        case .cloudPreferred: return t("云端优先")
        }
    }
}

// MARK: - Manifest（文件清单）
struct CloudSyncManifest: Codable {
    var version: Int = 1
    var files: [String: CloudSyncManifestEntry]  // 相对路径 → 条目
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey { case version, files, updatedAt }
    init(files: [String: CloudSyncManifestEntry], updatedAt: Date) {
        self.files = files
        self.updatedAt = updatedAt
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported manifest version")
        }
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        let decoded = try LegacyRecordReader.readDictionary(CloudSyncManifestEntry.self, from: values.superDecoder(forKey: .files))
        files = decoded.filter { path, entry in
            WallhavenLibraryFilePolicy.wallpaperID(relativePath: path) != nil
                && WallhavenLibraryFilePolicy.isObjectHash(entry.hash) && entry.size >= 0
        }
    }

    struct CloudSyncManifestEntry: Codable {
        let hash: String          // SHA-256 hex
        let size: Int64
        let mtime: Date
    }
}

// MARK: - 同步目录结构定义
enum CloudSyncDirectoryLayout {
    static let rootName = "WaifuXSync"
    static let versionDir = "v1"
    static let metadataFileName = "wallhaven-metadata-v1.json"
    static let legacyMetadataFileName = "metadata.json"
    static let manifestFileName = "wallhaven-manifest-v1.json"
    static let legacyManifestFileName = "manifest.json"
    static let objectsDirName = "objects"

    /// Path relative to the objects directory, which callers already supply.
    static func objectSubpath(hash: String) -> String {
        let prefix = String(hash.prefix(2))
        return "\(prefix)/\(hash)"
    }
}

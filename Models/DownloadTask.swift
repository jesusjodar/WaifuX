import Foundation

enum DownloadStatus: String, Codable {
    case pending, downloading, paused, completed, failed, cancelled
}

enum DownloadTaskKind: String, Codable {
    case wallpaper
}

struct DownloadTask: Identifiable, Codable {
    let id: String
    let kind: DownloadTaskKind
    var wallpaper: Wallpaper?
    var progress: Double
    var status: DownloadStatus
    let createdAt: Date
    var completedAt: Date?
    var lastUpdatedAt: Date

    init(wallpaper: Wallpaper) {
        id = "wallpaper.\(wallpaper.id)"
        kind = .wallpaper
        self.wallpaper = wallpaper
        progress = 0
        status = .pending
        createdAt = .now
        completedAt = nil
        lastUpdatedAt = createdAt
    }

    var itemID: String { wallpaper?.id ?? id.replacingOccurrences(of: "wallpaper.", with: "") }
    var title: String {
        if let name = wallpaper?.primaryTagName { return name }
        if let username = wallpaper?.uploader?.username, !username.isEmpty { return username }
        return "Wallhaven \(itemID.uppercased())"
    }
    var subtitle: String { wallpaper?.categoryDisplayName ?? "" }
    var badgeText: String { wallpaper?.resolution ?? "" }
    var thumbnailURL: URL? { wallpaper?.thumbURL ?? wallpaper?.smallThumbURL }
    var isRunning: Bool { status == .pending || status == .downloading }
    var shouldAppearInLibrary: Bool { isRunning || status == .paused }
    var isTerminal: Bool { [.completed, .failed, .cancelled].contains(status) }

    enum CodingKeys: String, CodingKey {
        case id, kind, wallpaper, progress, status, createdAt, completedAt, lastUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(DownloadTaskKind.self, forKey: .kind) ?? .wallpaper
        let original = try container.decode(Wallpaper.self, forKey: .wallpaper)
        guard WallhavenContentPolicy.isWallpaperRecord(id: original.id, detailURL: original.url, imagePath: original.path) else {
            throw DecodingError.dataCorruptedError(forKey: .wallpaper, in: container, debugDescription: "Unsupported wallpaper provenance")
        }
        wallpaper = original
        id = "wallpaper.\(original.id)"
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        status = try container.decodeIfPresent(DownloadStatus.self, forKey: .status) ?? .pending
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt) ?? completedAt ?? createdAt
    }
}

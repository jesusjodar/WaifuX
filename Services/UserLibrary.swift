import Foundation

/// Read-only import of the original JSON library. The old documents and every
/// unsupported record remain on disk; only verified Wallhaven data is returned.
enum LegacyWallhavenLibraryReader {
  struct Result: Sendable {
    var favorites: [WallpaperFavoriteRecord]
    var downloads: [WallpaperDownloadRecord]
  }
  static func read(from directory: URL) throws -> Result {
    let favorites = try records(
      Favorite.self, at: directory.appendingPathComponent("wallpaper_favorites.json")
    )
    .map(\.record).filter { supported($0.wallpaper) }
    let downloads = try records(
      Download.self, at: directory.appendingPathComponent("downloads.json")
    )
    .map(\.record).filter { supported($0.wallpaper) }
    return Result(favorites: favorites, downloads: downloads)
  }
  private static func records<Record: Decodable>(_ type: Record.Type, at url: URL) throws
    -> [Record]
  {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try LegacyRecordReader.read(type, from: Data(contentsOf: url)).records
  }
  private static func supported(_ image: Wallpaper) -> Bool {
    WallhavenContentPolicy.isWallpaperRecord(
      id: image.id, detailURL: image.url, imagePath: image.path)
  }
  private struct Favorite: Decodable {
    let record: WallpaperFavoriteRecord
    init(from decoder: Decoder) throws {
      if let value = try? WallpaperFavoriteRecord(from: decoder) {
        record = value
        return
      }
      if let value = try? Wallpaper(from: decoder) {
        record = .init(wallpaper: value)
        return
      }
      let item = try UniversalWallpaper(from: decoder)
      record = WallpaperFavoriteRecord(wallpaper: item.wallpaper)
    }
  }
  private struct Download: Decodable {
    let record: WallpaperDownloadRecord
    private enum Keys: String, CodingKey {
      case contentType, itemId, title, thumbnailURL, downloadURL, localPath, downloadedAt, status
    }
    init(from decoder: Decoder) throws {
      if let value = try? WallpaperDownloadRecord(from: decoder) {
        record = value
        return
      }
      let c = try decoder.container(keyedBy: Keys.self)
      guard try c.decode(String.self, forKey: .contentType) == "wallpaper",
        try c.decode(String.self, forKey: .status) == "completed"
      else { throw CocoaError(.featureUnsupported) }
      let id = try c.decode(String.self, forKey: .itemId)
      let imageURL = try c.decode(String.self, forKey: .downloadURL)
      let path = try c.decode(String.self, forKey: .localPath)
      guard path.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
      let image = makeWallpaper(
        id: id, detail: "https://wallhaven.cc/w/\(id)", original: imageURL,
        thumb: try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? imageURL,
        title: try c.decodeIfPresent(String.self, forKey: .title), resolution: nil, purity: "sfw",
        category: "general")
      guard supported(image) else { throw CocoaError(.featureUnsupported) }
      record = WallpaperDownloadRecord(
        wallpaper: image, localFilePath: path,
        downloadedAt: try c.decodeIfPresent(Date.self, forKey: .downloadedAt) ?? .distantPast)
    }
  }
  private struct UniversalWallpaper: Decodable {
    let wallpaper: Wallpaper
    private enum Keys: String, CodingKey {
      case contentType, title, thumbnailURL, sourceURL, metadata
    }
    private struct Metadata: Decodable {
      let fullImageURL: String
      let resolution: String?
      let purity: String?
      let category: String?
    }
    private struct Envelope: Decodable {
      let type: String
      let data: Data
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      let envelope = try c.decode(Envelope.self, forKey: .metadata)
      guard try c.decode(String.self, forKey: .contentType) == "wallpaper",
        envelope.type == "wallpaper"
      else {
        throw CocoaError(.featureUnsupported)
      }
      let metadata = try JSONDecoder().decode(Metadata.self, from: envelope.data)
      let detail = try c.decode(String.self, forKey: .sourceURL)
      guard let url = URL(string: detail), let id = WallhavenContentPolicy.wallpaperID(from: url)
      else { throw CocoaError(.featureUnsupported) }
      wallpaper = makeWallpaper(
        id: id, detail: detail, original: metadata.fullImageURL,
        thumb: try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? metadata.fullImageURL,
        title: try c.decodeIfPresent(String.self, forKey: .title), resolution: metadata.resolution,
        purity: metadata.purity ?? "sfw", category: metadata.category ?? "general")
    }
  }
  private static func makeWallpaper(
    id: String, detail: String, original: String, thumb: String, title: String?,
    resolution: String?, purity: String, category: String
  ) -> Wallpaper {
    let parts = (resolution ?? "").lowercased().split(separator: "x")
    let width = parts.count == 2 ? Int(parts[0]) ?? 0 : 0
    let height = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
    let thumbnail = WallhavenContentPolicy.imageURL(thumb)?.absoluteString ?? original
    return Wallpaper(
      id: id, title: title, url: detail, shortUrl: nil, views: 0, favorites: 0, downloads: nil,
      source: nil, purity: purity, category: category, dimensionX: width, dimensionY: height,
      resolution: resolution ?? "",
      ratio: height > 0 ? String(Double(width) / Double(height)) : "0",
      fileSize: nil, fileType: nil, createdAt: nil, colors: [], path: original,
      thumbs: .init(large: thumbnail, original: thumbnail, small: thumbnail), tags: nil,
      uploader: nil)
  }
}

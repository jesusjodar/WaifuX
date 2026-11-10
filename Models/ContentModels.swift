import Foundation

/// Only static wallpapers are supported. Retired values deliberately fail
/// per-record decoding; LegacyRecordReader preserves other valid records.
enum ContentType: String, CaseIterable, Codable {
    case wallpaper
    var displayName: String { t("content.wallpaper") }
    var icon: String { "photo" }
}

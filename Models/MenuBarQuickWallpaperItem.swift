import Foundation

/// Background indexing uses paths and IDs only; library service payloads stay on MainActor.
struct MenuBarQuickIndexEntry: Sendable {
    let id: String
    let path: String
    let folderKey: String
    let downloadedAt: Date
    let visible: Bool
}

struct MenuBarQuickIndex: Sendable {
    var ids: [String] = []
    var idsByFolder: [String: [String]] = [:]
    var visibleIDs = Set<String>()
    /// Includes hidden records: a known hidden path must never become an external item.
    var ownerByPath: [String: String] = [:]
    var hiddenPaths = Set<String>()

    static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    static func build(_ entries: [MenuBarQuickIndexEntry]) -> Self {
        var index = Self()
        for entry in entries.sorted(by: { $0.downloadedAt > $1.downloadedAt }) {
            guard !Task.isCancelled else { return Self() }
            if entry.visible {
                index.ids.append(entry.id)
                index.visibleIDs.insert(entry.id)
                index.idsByFolder[entry.folderKey, default: []].append(entry.id)
            }
            let path = normalizedPath(entry.path)
            index.ownerByPath[path] = entry.id
            if !entry.visible { index.hiddenPaths.insert(path) }
        }
        return index
    }

    func owner(of rawPath: String) -> String? {
        let path = Self.normalizedPath(rawPath)
        guard !hiddenPaths.contains(path) else { return nil }
        return ownerByPath[path]
    }

    /// Samples at most `limit` entries without shuffling or copying the whole library.
    func sample(folderIDs: [String]?, excluding: Set<String>, limit: Int) -> [String] {
        let pools = folderIDs.map { selection in
            (selection.isEmpty ? [""] : selection).map { idsByFolder[$0] ?? [] }
        } ?? [ids]
        let count = pools.reduce(0) { $0 + $1.count }
        guard count > 0, limit > 0 else { return [] }
        func element(at offset: Int) -> String {
            var remaining = offset
            for pool in pools {
                if remaining < pool.count { return pool[remaining] }
                remaining -= pool.count
            }
            return ""
        }
        var result: [String] = []
        var chosen = Set<String>()
        for _ in 0..<(min(count, limit) * 8) {
            let id = element(at: Int.random(in: 0..<count))
            if !excluding.contains(id), chosen.insert(id).inserted { result.append(id) }
            if result.count == min(count, limit) { return result }
        }
        // Bounded fallback for small pools or an almost-exhausted previous batch.
        let start = Int.random(in: 0..<count)
        for offset in 0..<min(count, limit * 2 + excluding.count) {
            let id = element(at: (start + offset) % count)
            if !excluding.contains(id), chosen.insert(id).inserted { result.append(id) }
            if result.count == min(count, limit) { return result }
        }
        // Only when fresh candidates really cannot fill the batch, reuse old ones.
        for offset in 0..<min(count, limit * 2 + excluding.count) {
            let id = element(at: (start + offset) % count)
            if chosen.insert(id).inserted { result.append(id) }
            if result.count == min(count, limit) { break }
        }
        return result
    }
}

/// A downloaded Wallhaven image; unknown local files never become candidates.
struct MenuBarQuickWallpaperItem: Identifiable {
    let id: String
    let title: String
    let localURL: URL
    let thumbnailURL: URL?
    let downloadedAt: Date
    let wallpaper: Wallpaper
    let folderID: String?

    func replacingThumbnail(with url: URL?) -> Self {
        Self(id: id, title: title, localURL: localURL, thumbnailURL: url,
             downloadedAt: downloadedAt, wallpaper: wallpaper, folderID: folderID)
    }
}

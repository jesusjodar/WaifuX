import SwiftUI

/// Wallhaven recommendations, ranked from static favorites and downloads.
@MainActor
final class GuessYouLikeService {
    static let shared = GuessYouLikeService()
    private init() {}

    func getRecommendations() async -> [GuessYouLikeItem] { await forceRefresh() }

    func forceRefresh() async -> [GuessYouLikeItem] {
        let items = await fetchWallhaven(count: 12, preferences: makePreferenceSnapshot())
        return items.shuffled()
    }

    private struct PreferenceSnapshot {
        let staticTags: [String]
        let wallhavenCategoryMask: String
        let wallhavenPurityMask: String
        let wallhavenRatios: [String]
        let wallhavenColors: [String]
        let excludedWallpaperIDs: Set<String>
    }

    private func makePreferenceSnapshot() -> PreferenceSnapshot {
        var tags: [String: Double] = [:]
        var categories: [String: Double] = [:]
        var purity: [String: Double] = [:]
        var ratios: [String: Double] = [:]
        var colors: [String: Double] = [:]
        var excluded = Set<String>()
        func add(_ wallpaper: Wallpaper, weight: Double) {
            guard WallhavenContentPolicy.isWallpaperRecord(
                id: wallpaper.id, detailURL: wallpaper.url, imagePath: wallpaper.path) else { return }
            excluded.insert(wallpaper.id)
            for tag in wallpaper.tags ?? [] {
                if let term = normalizedPreferenceTerm(tag.name) { tags[term, default: 0] += weight }
            }
            categories[wallpaper.category.lowercased(), default: 0] += weight
            purity[wallpaper.purity.lowercased(), default: 0] += weight
            if let ratio = wallhavenRatioLabel(for: wallpaper) { ratios[ratio, default: 0] += weight }
            for color in wallpaper.normalizedColorHexes.prefix(3) where WallhavenAPI.colorPreset(for: color) != nil {
                colors[color.lowercased(), default: 0] += weight
            }
        }
        let library = WallpaperLibraryService.shared
        for record in library.favoriteRecords where record.isActive { add(record.wallpaper, weight: 5) }
        for record in library.downloadedWallpapers { add(record.wallpaper, weight: 4) }
        return PreferenceSnapshot(
            staticTags: rankedTerms(tags), wallhavenCategoryMask: wallhavenCategoryMask(from: categories),
            wallhavenPurityMask: wallhavenPurityMask(from: purity), wallhavenRatios: rankedTerms(ratios, limit: 2),
            wallhavenColors: rankedTerms(colors, limit: 1), excludedWallpaperIDs: excluded)
    }

    private func rankedTerms(_ scores: [String: Double], limit: Int = 6) -> [String] {
        scores.sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }
        .prefix(limit)
        .map(\.key)
    }

    private func normalizedPreferenceTerm(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else {
            return nil
        }
        text = text.replacingOccurrences(of: "_", with: " ")
        text = text.replacingOccurrences(of: "-", with: " ")
        for suffix in [" live wallpapers", " wallpapers", " wallpaper"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ignored: Set<String> = ["", "wallpaper", "wallpapers", "live", "video", "dynamic", "sfw", "general", "motionbg", "motionbgs"]
        return ignored.contains(text) ? nil : text
    }

    private func wallhavenQuery(for preferences: PreferenceSnapshot) -> String {
        let usefulTags = preferences.staticTags
            .filter(isUsefulWallhavenTag)
        guard !usefulTags.isEmpty else { return "" }
        // 随机选择 1-2 个标签，起点随机，使每次查询不同
        let maxStart = max(0, usefulTags.count - 2)
        let start = Int.random(in: 0...maxStart)
        let take = min(Int.random(in: 1...2), usefulTags.count - start)
        return Array(usefulTags[start..<start + take]).joined(separator: " ")
    }

    private func isUsefulWallhavenTag(_ tag: String) -> Bool {
        let noisyTerms: Set<String> = [
            "art", "digital art", "illustration", "background", "desktop",
            "hd", "4k", "8k", "girl", "girls", "woman", "women", "man",
            "person", "people", "cute", "beautiful", "wallhaven"
        ]
        guard tag.count >= 3, !noisyTerms.contains(tag) else { return false }
        return !tag.contains("wallpaper")
    }

    private func wallhavenCategoryMask(from scores: [String: Double]) -> String {
        guard let topScore = scores.values.max(), topScore > 0 else { return "111" }
        let threshold = max(1, topScore * 0.45)
        let general = scores["general", default: 0] >= threshold
        let anime = scores["anime", default: 0] >= threshold
        let people = scores["people", default: 0] >= threshold
        let mask = "\(general ? 1 : 0)\(anime ? 1 : 0)\(people ? 1 : 0)"
        return mask == "000" ? "111" : mask
    }

    private func wallhavenPurityMask(from scores: [String: Double]) -> String {
        guard let topScore = scores.values.max(), topScore > 0 else { return "100" }
        let sketchyPreferred = scores["sketchy", default: 0] >= topScore * 0.5
        // 推荐卡片默认不引入 NSFW；后续如果接入用户显式内容级别设置，再放开第三位。
        return sketchyPreferred ? "110" : "100"
    }

    private func wallhavenRatioLabel(for wallpaper: Wallpaper) -> String? {
        guard let ratio = wallpaper.aspectRatioValue else { return nil }
        let candidates: [(String, Double)] = [
            ("16x9", 16.0 / 9.0),
            ("16x10", 16.0 / 10.0),
            ("21x9", 21.0 / 9.0),
            ("32x9", 32.0 / 9.0),
            ("48x9", 48.0 / 9.0),
            ("9x16", 9.0 / 16.0),
            ("10x16", 10.0 / 16.0),
        ]
        return candidates.min { lhs, rhs in
            abs(lhs.1 - ratio) < abs(rhs.1 - ratio)
        }
        .flatMap { abs($0.1 - ratio) <= 0.08 ? $0.0 : nil }
    }

    private func fetchWallhaven(count: Int, preferences: PreferenceSnapshot) async -> [GuessYouLikeItem] {
        guard count > 0 else { return [] }
        do {
            let list = try await fetchWallhavenCandidates(count: count, preferences: preferences)

            return list.prefix(count).map { w in
                GuessYouLikeItem(
                    id: w.id,
                    title: w.primaryTagName ?? w.categoryDisplayName,
                    subtitle: w.resolution,
                    imageURL: w.gridPreviewURL?.absoluteString ?? w.thumbs.original,
                    destination: w.url,
                    contentType: .wallpaper,
                    sourceName: "Wallhaven"
                )
            }
        } catch {
            print("[GYL] Wallhaven error: \(error)")
            return []
        }
    }

    private func fetchWallhavenCandidates(count: Int, preferences: PreferenceSnapshot) async throws -> [Wallpaper] {
        let sortingOptions = ["toplist", "random", "favorites", "date_added"]
        let topRangeOptions = ["1d", "3d", "1w", "1M"]
        let randomSorting = sortingOptions.randomElement() ?? "toplist"
        let randomTopRange = topRangeOptions.randomElement() ?? "1M"
        let randomPage = Int.random(in: 1...5)

        var params = WallhavenAPI.SearchParameters(
            categories: preferences.wallhavenCategoryMask,
            purity: preferences.wallhavenPurityMask,
            sorting: randomSorting,
            order: "desc",
            topRange: randomTopRange,
            ratios: preferences.wallhavenRatios,
            colors: preferences.wallhavenColors
        )
        params.perPage = max(count * 4, 12)
        params.page = randomPage
        params.query = wallhavenQuery(for: preferences)

        var list = try await fetchWallhavenList(params, excluding: preferences.excludedWallpaperIDs)
        if list.count >= count {
            return list
        }

        if !params.query.isEmpty {
            params.query = ""
            list = try await fetchWallhavenList(params, excluding: preferences.excludedWallpaperIDs)
            if list.count >= count { return list }
        }

        if !params.colors.isEmpty {
            params.colors = []
            list = try await fetchWallhavenList(params, excluding: preferences.excludedWallpaperIDs)
            if list.count >= count { return list }
        }

        if !params.ratios.isEmpty {
            params.ratios = []
            list = try await fetchWallhavenList(params, excluding: preferences.excludedWallpaperIDs)
            if list.count >= count { return list }
        }

        params.categories = preferences.wallhavenCategoryMask == "111" ? "111" : preferences.wallhavenCategoryMask
        params.purity = "100"
        params.query = ""
        params.colors = []
        params.ratios = []
        return try await fetchWallhavenList(params, excluding: preferences.excludedWallpaperIDs)
    }

    private func fetchWallhavenList(_ params: WallhavenAPI.SearchParameters, excluding excludedIDs: Set<String>) async throws -> [Wallpaper] {
        guard let url = WallhavenAPI.url(for: .search(params)) else { return [] }
        let headers = WallhavenAPI.authenticationHeaders(apiKey: nil)
        let resp: WallpaperSearchResponse = try await NetworkService.shared.fetch(
            WallpaperSearchResponse.self,
            from: url,
            headers: headers
        )
        return resp.data.filter {
            !excludedIDs.contains($0.id)
                && WallhavenContentPolicy.isWallpaperRecord(id: $0.id, detailURL: $0.url, imagePath: $0.path)
        }
    }
}

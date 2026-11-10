import Foundation

// MARK: - 设置分类
enum CloudSyncSettingsCategory: String, Codable, CaseIterable {
    case general, appearance, sources, localization
    var displayName: String {
        switch self {
        case .general: return t("general")
        case .appearance: return t("player.appearance")
        case .sources: return "Wallhaven"
        case .localization: return t("design.language")
        }
    }
}

// MARK: - 值类型
enum CloudSyncSettingsValueType: Codable {
    case bool
    case string
    case double
    case data
}

// MARK: - 白名单条目
struct CloudSyncSettingsEntry {
    let key: String
    let category: CloudSyncSettingsCategory
    let valueType: CloudSyncSettingsValueType
}

// MARK: - 设置注册表
enum CloudSyncSettingsRegistry {
    /// 完整的同步白名单
    static var allEntries: [CloudSyncSettingsEntry] {
        [
            .init(key: "theme_mode", category: .general, valueType: .string),
            .init(key: "save_to_downloads", category: .general, valueType: .bool),
            .init(key: "launch_at_login", category: .general, valueType: .bool),
            .init(key: "proxy_enabled", category: .general, valueType: .bool),
            .init(key: "proxy_host", category: .general, valueType: .string),
            .init(key: "proxy_port", category: .general, valueType: .string),
            .init(key: "arc_theme_mode", category: .appearance, valueType: .string),
            .init(key: "arc_accent_color", category: .appearance, valueType: .string),
            .init(key: "arc_compact_mode", category: .appearance, valueType: .bool),
            .init(key: "portrait_blur_fill_enabled", category: .sources, valueType: .bool),
            .init(key: WallhavenBrowsePreferences.hidePortraitByDefaultKey, category: .sources, valueType: .bool),
            .init(key: WallhavenBrowsePreferences.hidePeopleByDefaultKey, category: .sources, valueType: .bool),
            .init(key: "app_language", category: .localization, valueType: .string)
        ]
    }

    // MARK: - 读取和写入

    /// 读取所有白名单中的设置
    static func exportSettings() -> [CloudSyncSettingsCategory: [String: AnyCodable]] {
        let defaults = WaifuXPreferences.shared
        var result: [CloudSyncSettingsCategory: [String: AnyCodable]] = [:]

        for entry in allEntries {
            guard let value = readValue(from: defaults, entry: entry) else { continue }
            result[entry.category, default: [:]][entry.key] = value
        }

        return result
    }

    /// 写入设置到 UserDefaults（根据冲突策略决定是否覆盖）
    static func importSettings(
        _ settings: [CloudSyncSettingsCategory: [String: AnyCodable]],
        strategy: CloudSyncConflictStrategy = .cloudPreferred
    ) {
        let defaults = WaifuXPreferences.shared

        guard strategy == .cloudPreferred else { return }

        for (_, entries) in settings {
            for (key, value) in entries {
                // 检查是否在白名单中
                guard allEntries.contains(where: { $0.key == key }) else { continue }
                writeValue(value, to: defaults, key: key)
            }
        }

        // 通知各服务重新加载设置
        notifySettingsChanged()
    }

    /// 获取云端和本地都存在的分类（用于展示同步预览）
    static func categorizedKeys() -> [(CloudSyncSettingsCategory, [CloudSyncSettingsEntry])] {
        let grouped = Dictionary(grouping: allEntries, by: { $0.category })
        return grouped.map { ($0.key, $0.value) }
            .sorted { $0.0.rawValue < $1.0.rawValue }
    }

    // MARK: - 内部辅助

    private static func readValue(
        from defaults: UserDefaults,
        entry: CloudSyncSettingsEntry
    ) -> AnyCodable? {
        switch entry.valueType {
        case .bool:
            guard defaults.object(forKey: entry.key) != nil else { return nil }
            return .bool(defaults.bool(forKey: entry.key))
        case .string:
            guard let val = defaults.string(forKey: entry.key), !val.isEmpty else { return nil }
            return .string(val)
        case .double:
            guard defaults.object(forKey: entry.key) != nil else { return nil }
            return .number(defaults.double(forKey: entry.key))
        case .data:
            guard let val = defaults.data(forKey: entry.key) else { return nil }
            return .data(val)
        }
    }

    private static func writeValue(_ value: AnyCodable, to defaults: UserDefaults, key: String) {
        switch value {
        case .bool(let b):
            defaults.set(b, forKey: key)
        case .string(let s):
            defaults.set(s, forKey: key)
        case .number(let n):
            defaults.set(n, forKey: key)
        case .data(let d):
            defaults.set(d, forKey: key)
        }
    }

    private static func notifySettingsChanged() {
        // 发送通知让各服务重载
        NotificationCenter.default.post(name: .cloudSyncSettingsImported, object: nil)
    }
}

// MARK: - AnyCodable（JSON 兼容包装）
enum AnyCodable: Codable {
    case bool(Bool)
    case string(String)
    case number(Double)
    case data(Data)

    var codableValue: Codable {
        switch self {
        case .bool(let v): return v
        case .string(let v): return v
        case .number(let v): return v
        case .data(let v): return v
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .number(doubleVal)
        } else {
            throw DecodingError.typeMismatch(
                AnyCodable.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "不支持的 AnyCodable 类型")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .data(let v): try container.encode(v.base64EncodedString())
        }
    }
}

// MARK: - 通知扩展
extension Notification.Name {
    static let cloudSyncSettingsImported = Notification.Name("cloudSyncSettingsImported")
}

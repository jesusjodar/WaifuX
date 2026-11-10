import Foundation

enum ScheduleOrder: String, Codable { case sequential, random }

struct DisplaySchedulerConfig: Codable, Equatable {
  var isEnabled: Bool
  var intervalMinutes: Int
  var order: ScheduleOrder
  /// nil selects all folders; an empty array selects images at the root.
  var folderIDs: [String]?
  var displayFingerprint: String?
  var isOnUnlockMode: Bool { intervalMinutes == SchedulerConfig.intervalOnUnlockMinutes }

  init(
    isEnabled: Bool, intervalMinutes: Int, order: ScheduleOrder, folderIDs: [String]? = nil,
    displayFingerprint: String? = nil
  ) {
    self.isEnabled = isEnabled
    self.intervalMinutes = intervalMinutes
    self.order = order
    self.folderIDs = folderIDs
    self.displayFingerprint = displayFingerprint
  }
  static func fromLegacy(_ config: SchedulerConfig) -> Self {
    Self(isEnabled: config.isEnabled, intervalMinutes: config.intervalMinutes, order: config.order)
  }
  private enum CodingKeys: String, CodingKey {
    case isEnabled, intervalMinutes, order, folderIDs, displayFingerprint
  }
  private enum LegacyKeys: String, CodingKey { case includeWallpapers, source }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let legacy = try decoder.container(keyedBy: LegacyKeys.self)
    let includesImages =
      try legacy.decodeIfPresent(Bool.self, forKey: .includeWallpapers)
      ?? (legacy.decodeIfPresent(String.self, forKey: .source) != "local")
    let interval = try values.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 60
    let supported = SchedulerConfig.isSupportedInterval(interval)
    isEnabled =
      (try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false) && includesImages
      && supported
    intervalMinutes = supported ? interval : 60
    order = try values.decodeIfPresent(ScheduleOrder.self, forKey: .order) ?? .random
    folderIDs = try values.decodeIfPresent([String].self, forKey: .folderIDs)
    displayFingerprint = try values.decodeIfPresent(String.self, forKey: .displayFingerprint)
  }
}

struct SchedulerConfig: Codable, Equatable {
  var isEnabled: Bool
  var intervalMinutes: Int
  var order: ScheduleOrder
  var displayConfigs: [String: DisplaySchedulerConfig]
  var isGlobalDisplaySyncEnabled: Bool
  var globalDisplayConfig: DisplaySchedulerConfig
  static let intervalOnUnlockMinutes = -2
  static let intervalOptions = [1, 3, 5, 15, 30, 60, 360, 1440]
  static let `default` = Self(isEnabled: false, intervalMinutes: 60, order: .random)
  static func isSupportedInterval(_ value: Int) -> Bool {
    value == intervalOnUnlockMinutes || (1...10080).contains(value)
  }

  init(
    isEnabled: Bool, intervalMinutes: Int, order: ScheduleOrder,
    displayConfigs: [String: DisplaySchedulerConfig] = [:],
    isGlobalDisplaySyncEnabled: Bool = false, globalDisplayConfig: DisplaySchedulerConfig? = nil
  ) {
    self.isEnabled = isEnabled
    self.intervalMinutes = intervalMinutes
    self.order = order
    self.displayConfigs = displayConfigs
    self.isGlobalDisplaySyncEnabled = isGlobalDisplaySyncEnabled
    self.globalDisplayConfig =
      globalDisplayConfig
      ?? DisplaySchedulerConfig(
        isEnabled: isEnabled, intervalMinutes: intervalMinutes, order: order)
  }
  private enum CodingKeys: String, CodingKey {
    case isEnabled, intervalMinutes, order, displayConfigs, isGlobalDisplaySyncEnabled,
      globalDisplayConfig
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let legacy = try DisplaySchedulerConfig(from: decoder)
    isEnabled = legacy.isEnabled
    intervalMinutes = legacy.intervalMinutes
    order = legacy.order
    displayConfigs = [:]
    if values.contains(.displayConfigs) {
      displayConfigs = try LegacyRecordReader.readDictionary(
        DisplaySchedulerConfig.self, from: values.superDecoder(forKey: .displayConfigs))
    }
    isGlobalDisplaySyncEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .isGlobalDisplaySyncEnabled) ?? false
    globalDisplayConfig =
      try values.decodeIfPresent(DisplaySchedulerConfig.self, forKey: .globalDisplayConfig)
      ?? legacy
  }
  func resolvedDisplayConfig(for screenID: String) -> DisplaySchedulerConfig {
    isGlobalDisplaySyncEnabled ? globalDisplayConfig : storedDisplayConfig(for: screenID)
  }
  func storedDisplayConfig(for screenID: String) -> DisplaySchedulerConfig {
    displayConfigs[screenID]
      ?? DisplaySchedulerConfig(isEnabled: false, intervalMinutes: intervalMinutes, order: order)
  }
}

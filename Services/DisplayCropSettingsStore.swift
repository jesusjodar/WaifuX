import Foundation
import AppKit
import Combine

/// crop 配置重链/去腐纯函数集（无 actor 隔离，可独立单测）。
enum DisplayCropStateReconciler {

    /// 当前屏身份快照（不依赖真实 NSScreen，便于单测）。
    struct ScreenIdentitySnapshot: Equatable {
        let screenID: String
        let fingerprint: String
    }

    /// 去掉无序列号显示器指纹中的 `:position:` 后缀与本地化屏幕名段，得到
    /// 位置与进程语言无关的稳定部分。有硬件序列号的指纹原样返回（剥名守卫
    /// 只认 `cg:v:m:noserial:<name>:<rest>` 形态）。
    ///
    /// 屏幕名段跟随读取进程的本地化（主 App zh / Helper en 对同一块内建屏
    /// 读出两个名字），参与匹配会把同一块屏误判成「已变化」。
    static func stableFingerprintPart(_ fp: String) -> String {
        var result: Substring = fp[...]
        if let range = fp.range(of: ":position:") {
            result = fp[..<range.lowerBound][...]
        }
        let fields = result.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count > 5, fields[0] == "cg", fields[3] == "noserial" else {
            return String(result)
        }
        return (fields[0...3] + fields[5...]).joined(separator: ":")
    }

    /// 指纹匹配：精确相等，或仅桌面位置变化（稳定部分一致）。
    static func isFingerprintMatch(_ recorded: String, _ actual: String) -> Bool {
        recorded == actual || stableFingerprintPart(recorded) == stableFingerprintPart(actual)
    }

    /// 用当前在线屏对持久化条目做重链 + 去腐（纯函数，返回 nil 表示无需变化）。
    ///
    /// Pass 1（fingerprint 认领）：条目跟着它记录的物理显示器指纹走，而不是跟着
    ///   screenID 走——修复重启后双屏 displayID 互换导致的 A/B 设置串台。
    ///   第一轮精确匹配，第二轮忽略 position（显示器仅桌面位置变化的场景）。
    /// Pass 2（同 ID 兜底）：同 screenID 条目若记录的指纹与当前屏不匹配
    ///   （displayID 被新屏回收复用），丢弃旧条目回退默认；没记录过指纹的历史
    ///   条目（旧版 update(forScreenID:) 路径）信任并补记指纹。
    /// 未被认领的孤儿条目原样保留（显示器暂时断开不丢配置，重插后仍可按指纹重链）。
    static func reconciledCropState(
        settingsByScreen: [String: DisplayCropSettings],
        fingerprints: [String: String],
        currentScreens: [ScreenIdentitySnapshot]
    ) -> (settings: [String: DisplayCropSettings], fingerprints: [String: String])? {
        guard !currentScreens.isEmpty else { return nil }
        let currentIDs = Set(currentScreens.map(\.screenID))

        var newSettings: [String: DisplayCropSettings] = [:]
        var newFingerprints: [String: String] = [:]
        var consumed = Set<String>()

        for pass in 0..<2 {
            for screen in currentScreens {
                guard newSettings[screen.screenID] == nil else { continue }
                guard let entryID = fingerprints.first(where: { entryID, recordedFp in
                    !consumed.contains(entryID)
                        && (pass == 0
                            ? recordedFp == screen.fingerprint
                            : isFingerprintMatch(recordedFp, screen.fingerprint))
                })?.key,
                   let s = settingsByScreen[entryID] else { continue }
                newSettings[screen.screenID] = s
                newFingerprints[screen.screenID] = screen.fingerprint
                consumed.insert(entryID)
            }
        }

        for screen in currentScreens {
            let id = screen.screenID
            guard newSettings[id] == nil, let s = settingsByScreen[id] else { continue }
            if let recorded = fingerprints[id] {
                // 记录的指纹与当前同 ID 屏不匹配 → displayID 被回收/复用，丢弃旧条目。
                guard isFingerprintMatch(recorded, screen.fingerprint) else { continue }
            }
            // 补记/更新指纹（含仅 position 变化的场景）。
            newSettings[id] = s
            newFingerprints[id] = screen.fingerprint
            consumed.insert(id)
        }

        for (id, s) in settingsByScreen where !consumed.contains(id) && !currentIDs.contains(id) {
            newSettings[id] = s
            if let fp = fingerprints[id] { newFingerprints[id] = fp }
        }

        guard newSettings != settingsByScreen || newFingerprints != fingerprints else { return nil }
        return (newSettings, newFingerprints)
    }
}

/// Per-display static crop preferences, rebound by physical display identity.
@MainActor
final class DisplayCropSettingsStore: ObservableObject {
    static let shared = DisplayCropSettingsStore()
    static let cropDidChangeNotification = Notification.Name("DisplayCropSettingsDidChange")
    @Published private(set) var settingsByScreen: [String: DisplayCropSettings] = [:]
    private var fingerprints: [String: String] = [:]
    private var pendingApplies: [String: Task<Void, Never>] = [:]
    private let defaults: UserDefaults
    private let stateKey = "display_crop_settings_v2"
    private let fingerprintKey = "display_crop_fingerprints_v1"

    init(testDefaults: UserDefaults? = nil) {
        defaults = testDefaults ?? WaifuXPreferences.shared
        load()
        if BackgroundRuntimeRole.isHelper && !BackgroundRuntimeRole.isIsolatedTest {
            reconcileWithCurrentScreens()
            NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    func settings(forScreenID id: String) -> DisplayCropSettings {
        if let recorded = fingerprints[id],
           let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == id }),
           !DisplayCropStateReconciler.isFingerprintMatch(recorded, screen.wallpaperScreenFingerprint) {
            return .defaultSettings
        }
        return (settingsByScreen[id] ?? .defaultSettings).sanitized
    }
    func settings(for screen: NSScreen) -> DisplayCropSettings { settings(forScreenID: screen.wallpaperScreenIdentifier) }
    func update(forScreenID id: String, interactive: Bool = false, _ mutate: (inout DisplayCropSettings) -> Void) {
        var value = settings(forScreenID: id)
        mutate(&value)
        settingsByScreen[id] = value.sanitized
        if !interactive { persist() }
        notifyChange(screenID: id, interactive: interactive)
    }
    func update(for screen: NSScreen, interactive: Bool = false, _ mutate: (inout DisplayCropSettings) -> Void) {
        fingerprints[screen.wallpaperScreenIdentifier] = screen.wallpaperScreenFingerprint
        update(forScreenID: screen.wallpaperScreenIdentifier, interactive: interactive, mutate)
    }
    func reset(forScreenID id: String) { update(forScreenID: id) { $0 = .defaultSettings } }
    func reset(for screen: NSScreen) { update(for: screen) { $0 = .defaultSettings } }
    func commitInteractive(for screen: NSScreen, applyChanges: Bool = true) {
        fingerprints[screen.wallpaperScreenIdentifier] = screen.wallpaperScreenFingerprint
        persist()
        if applyChanges { notifyChange(screenID: screen.wallpaperScreenIdentifier, interactive: false) }
    }
    func reloadFromPreferences() { load(); reconcileWithCurrentScreens() }
    private func load() {
        if let bytes = defaults.data(forKey: stateKey),
           let values = try? JSONDecoder().decode([String: DisplayCropSettings].self, from: bytes) {
            settingsByScreen = values.mapValues(\.sanitized)
        } else if let bytes = defaults.data(forKey: "display_crop_settings_v1"),
                  let values = try? JSONDecoder().decode([String: DisplayCropSettings].self, from: bytes) {
            // Keep the old preference document intact for rollback.
            settingsByScreen = values.mapValues { old in
                var value = old
                value.pan = CGPoint(x: old.pan.x / 2 + 0.5, y: old.pan.y / 2 + 0.5)
                return value.sanitized
            }
            persist()
        }
        if let bytes = defaults.data(forKey: fingerprintKey),
           let values = try? JSONDecoder().decode([String: String].self, from: bytes) { fingerprints = values }
    }
    private func persist() {
        guard !BackgroundRuntimeRole.isRemoteUI else { return }
        if let bytes = try? JSONEncoder().encode(settingsByScreen) { defaults.set(bytes, forKey: stateKey) }
        if let bytes = try? JSONEncoder().encode(fingerprints) { defaults.set(bytes, forKey: fingerprintKey) }
    }
    private func reconcileWithCurrentScreens() {
        let screens = NSScreen.screens.map {
            DisplayCropStateReconciler.ScreenIdentitySnapshot(screenID: $0.wallpaperScreenIdentifier, fingerprint: $0.wallpaperScreenFingerprint)
        }
        if let next = DisplayCropStateReconciler.reconciledCropState(settingsByScreen: settingsByScreen,
            fingerprints: fingerprints, currentScreens: screens) {
            settingsByScreen = next.settings
            fingerprints = next.fingerprints
            persist()
        }
    }
    @objc private func screenParametersChanged() { reconcileWithCurrentScreens() }
    private func notifyChange(screenID: String, interactive: Bool) {
        NotificationCenter.default.post(name: Self.cropDidChangeNotification, object: nil,
            userInfo: ["screenID": screenID, "interactive": interactive])
        guard !interactive, !BackgroundRuntimeRole.isIsolatedTest,
              let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) else { return }
        let settings = settings(for: screen)
        pendingApplies[screenID]?.cancel()
        pendingApplies[screenID] = Task {
            do {
                if BackgroundRuntimeRole.isRemoteUI {
                    _ = try await BackgroundRuntimeBridge.request("crop.update", ["screen": screen,
                        "settings": try JSONEncoder().encode(settings)])
                } else {
                    try await applyToCurrentWallpaper(on: screen)
                }
            } catch is CancellationError {} catch {
                let alert = NSAlert()
                alert.messageText = t("statusbar.cropAdjust")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
    /// Does not take ownership of a wallpaper changed outside this application.
    func applyToCurrentWallpaper(on screen: NSScreen) async throws {
        let manager = DesktopWallpaperSyncManager.shared
        guard let owned = manager.imageURL(for: screen),
              NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL == owned.standardizedFileURL else { return }
        guard !DirectoryMigrationService.shared.isMigrating else {
            throw LocalWallpaperApplyService.ApplyError.failed(t("migration.busy"))
        }
        let source = manager.originalSourceURL(for: owned)
        guard let record = WallpaperLibraryService.shared.downloadRecord(forLocalFilePath: source.path) else { return }
        let scheduler = WallpaperSchedulerService.shared
        let lease = await scheduler.beginManualWallpaperApply()
        var success = false
        defer { scheduler.completeManualWallpaperApply(lease: lease, success: success,
            screenIDs: [screen.wallpaperScreenIdentifier], itemID: record.wallpaper.id) }
        try await StaticWallpaperApplyService.apply(from: source, option: .desktop, targetScreens: [screen])
        success = true
    }
}

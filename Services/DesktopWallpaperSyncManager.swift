import Foundation
import AppKit

/// 桌面壁纸跨 Space 同步管理器
///
/// macOS 的 `NSWorkspace.setDesktopImageURL` 默认只更新当前 active Space 的壁纸。
/// 即使在 options 中传入 `allSpaces: true`，已有 Spaces 仍可能不同步。
///
/// 解决思路：
/// 1. 监听 `activeSpaceDidChangeNotification`，当用户切换到另一个 Space 时，
///    自动将每个屏幕最后设置的壁纸重新应用到新的 active Space。
/// 2. 作为备用，在应用重新变为活跃时（applicationDidBecomeActive）也执行一次同步，
///    因为 `activeSpaceDidChangeNotification` 在应用后台时可能不可靠。
@MainActor
final class DesktopWallpaperSyncManager {
    static let shared = DesktopWallpaperSyncManager()
    static let registrationDidChangeNotification = Notification.Name("com.waifux.desktopRegistrationDidChange")

    /// 每个屏幕最后通过 WaifuX 设置的静态壁纸 URL（key 为 screenID）
    private var sourcePathByImagePath: [String: String] = [:]
    private var lastSetImageURLByScreen: [String: URL] = [:]
    /// 每个物理显示器指纹最后设置的静态壁纸 URL，用于外接屏重连后 screenID 变化时恢复。
    private var lastSetImageURLByFingerprint: [String: URL] = [:]

    /// 每个屏幕最后设置的选项
    private var lastOptionsByScreen: [String: [NSWorkspace.DesktopImageOptionKey: Any]] = [:]
    /// 每个物理显示器指纹最后设置的选项。
    private var lastOptionsByFingerprint: [String: [NSWorkspace.DesktopImageOptionKey: Any]] = [:]
    /// WaifuX 接管前的系统壁纸快照（按物理指纹持久化）。关闭 ownership 时用于还原。
    private var originalImageURLByFingerprint: [String: URL] = [:]

    /// 记录最后一次尝试同步的时间，避免过于频繁的重复同步
    private var lastSyncTime: Date?
    private let minimumSyncInterval: TimeInterval = 0.5
    /// 用于 Space 切换的 debounce，快速连续切换时只保留最后一次
    private var pendingSyncWorkItem: DispatchWorkItem?
    /// 节流期间合并一次尾沿同步，不能丢掉最后切入的 Space。
    private var pendingThrottledSyncWorkItem: DispatchWorkItem?
    private var pendingScreenChangeWorkItem: DispatchWorkItem?
    private var pendingActivationSyncWorkItem: DispatchWorkItem?
    /// 标记“应用重新激活时确实需要做一次恢复性同步”。
    /// 仅在显示器参数变化/系统唤醒等场景置为 true，避免普通前后台切换也去重写桌面壁纸。
    private var requiresActivationRecoverySync = false

    /// 持久化键：`{displayIdentity: imageURLString}` JSON。
    /// 用于外接屏断开重连（App 可能已被系统杀掉重启）后判断该屏是否曾由 App 设过壁纸。
    private static let fingerprintStateKey = "desktop_wallpaper_sync_fingerprint_state_v1"
    private static let originalFingerprintStateKey = "desktop_wallpaper_sync_original_fingerprint_state_v1"

    private init() {
        guard !BackgroundRuntimeRole.isIsolatedTest else { return }
        if BackgroundRuntimeRole.isRemoteUI {
            BackgroundRuntimeBridge.observe { [weak self] snapshot in
                guard let self, let values = snapshot["desktop"] as? [String: Any] else { return }
                lastSetImageURLByScreen = (values["screens"] as? [String: String] ?? [:]).compactMapValues(URL.init(string:))
                lastSetImageURLByFingerprint = (values["fingerprints"] as? [String: String] ?? [:]).compactMapValues(URL.init(string:))
            }
            return
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // 系统唤醒后同步壁纸到所有显示器（外接显示器可能延迟枚举）
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        // 恢复持久化的指纹 -> 壁纸 URL 映射，供外接屏重连后判断是否曾由 App 设过壁纸
        sourcePathByImagePath = WaifuXPreferences.shared.dictionary(forKey: "desktop_wallpaper_static_sources_v1") as? [String: String] ?? [:]
        loadFingerprintState()
        loadOriginalFingerprintState()
    }

    func backgroundSnapshot() -> [String: Any] {
        ["screens": lastSetImageURLByScreen.mapValues(\.absoluteString), "fingerprints": lastSetImageURLByFingerprint.mapValues(\.absoluteString)]
    }

    /// 在 WaifuX 首次改写某屏系统壁纸前，记录当时的系统桌面图。
    func captureOriginalSystemWallpaperIfNeeded(for screens: [NSScreen]) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("desktop.capture", ["screens": screens]); return }
        var changed = false
        for screen in screens {
            let fingerprint = screen.wallpaperScreenFingerprint
            guard originalImageURLByFingerprint[fingerprint] == nil,
                  let imageURL = NSWorkspace.shared.desktopImageURL(for: screen),
                  imageURL.isFileURL else {
                continue
            }
            originalImageURLByFingerprint[fingerprint] = imageURL
            changed = true
        }
        if changed {
            persistOriginalFingerprintState()
        }
    }

    /// 恢复指定显示器在 WaifuX 接管前的系统壁纸；没有可用快照时只清理 WaifuX 的同步记录。
    func restoreOriginalSystemWallpaper(for screen: NSScreen) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("desktop.restore", ["screen": screen]); return }

        let fingerprint = screen.wallpaperScreenFingerprint
        defer {
            originalImageURLByFingerprint.removeValue(forKey: fingerprint)
            clearRegistration(for: screen)
            persistOriginalFingerprintState()
        }

        guard let imageURL = originalImageURLByFingerprint[fingerprint],
              FileManager.default.fileExists(atPath: imageURL.path) else {
            return
        }

        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true
        ]
        do {
            try NSWorkspace.shared.setDesktopImageURLForAllSpaces(imageURL, for: screen, options: fillOptions)
        } catch {
            AppLogger.error(.wallpaper, "Failed to restore original system wallpaper", metadata: [
                "screen": screen.localizedName,
                "error": error.localizedDescription
            ])
        }
    }

    private func persistOriginalFingerprintState() {
        let state = originalImageURLByFingerprint.mapValues(\.absoluteString)
        if state.isEmpty {
            WaifuXPreferences.shared.removeObject(forKey: Self.originalFingerprintStateKey)
        } else if let data = try? JSONEncoder().encode(state) {
            WaifuXPreferences.shared.set(data, forKey: Self.originalFingerprintStateKey)
        }
    }

    private func loadOriginalFingerprintState() {
        guard let data = WaifuXPreferences.shared.data(forKey: Self.originalFingerprintStateKey),
              let state = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        originalImageURLByFingerprint = state.reduce(into: [:]) { result, entry in
            guard let url = URL(string: entry.value), url.isFileURL else { return }
            result[entry.key] = url
        }
    }

    /// 注册一次静态壁纸设置，后续 Space 切换时会自动同步
    /// - Parameters:
    ///   - url: 壁纸图片 URL
    ///   - screen: 目标屏幕；nil 表示注册到所有当前屏幕
    ///   - options: 设置选项
    func registerWallpaperSet(_ url: URL, for screen: NSScreen? = nil, options: [NSWorkspace.DesktopImageOptionKey: Any] = [:], sourceURL: URL? = nil) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("desktop.register", ["url": url, "screen": screen, "options": Dictionary(uniqueKeysWithValues: options.map { ($0.key.rawValue, $0.value) })]); return }
        if let sourceURL {
            sourcePathByImagePath[url.standardizedFileURL.path] = sourceURL.standardizedFileURL.path
            WaifuXPreferences.shared.set(sourcePathByImagePath, forKey: "desktop_wallpaper_static_sources_v1")
        }
        guard isVerifiedStaticImage(url) else { return }
        let targetScreens: [NSScreen]
        if let screen = screen {
            targetScreens = [screen]
        } else {
            targetScreens = NSScreen.screens
        }

        for targetScreen in targetScreens {
            let screenID = targetScreen.wallpaperScreenIdentifier
            let fingerprint = targetScreen.wallpaperScreenFingerprint
            let previousURL = lastSetImageURLByScreen[screenID]
                ?? lastSetImageURLByFingerprint[fingerprint]

            lastSetImageURLByScreen[screenID] = url
            lastSetImageURLByFingerprint[fingerprint] = url
            // A later bookkeeping call often repeats the same poster with no
            // options. Preserve the concrete options from the actual desktop
            // write so a pending refresh keeps the intended fill behavior.
            if !options.isEmpty || lastOptionsByScreen[screenID] == nil {
                lastOptionsByScreen[screenID] = options
            }
            if !options.isEmpty || lastOptionsByFingerprint[fingerprint] == nil {
                lastOptionsByFingerprint[fingerprint] = options
            }

            guard previousURL?.standardizedFileURL != url.standardizedFileURL else {
                continue
            }
        }
        persistFingerprintState()

        // 静态壁纸写入会让 wallpaper agent 新增一份 24MB+ 的解码缓存，
        // 触发一次系统壁纸缓存水位检查（内部 10 秒防抖 + 10 分钟节流 + 2GB 阈值，常态零开销）
        WallpaperSystemCacheJanitor.shared.noteWallpaperChanged()
    }

    /// 返回指定屏幕最后通过 App 设置的静态壁纸 URL（无记录时返回 nil）
    func imageURL(for screen: NSScreen) -> URL? {
        let screenID = screen.wallpaperScreenIdentifier
        let fingerprint = screen.wallpaperScreenFingerprint
        return lastSetImageURLByScreen[screenID]
            ?? WallpaperScreenIdentity.value(
                in: lastSetImageURLByFingerprint,
                forFingerprint: fingerprint
            )
    }

    /// 清除静态壁纸注册（例如用户手动在系统设置里改了壁纸）
    /// - Parameter screen: 目标屏幕；nil 表示清除所有屏幕
    func clearRegistration(for screen: NSScreen? = nil) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("desktop.clear", ["screen": screen]); return }
        if let screen = screen {
            let screenID = screen.wallpaperScreenIdentifier
            let fingerprint = screen.wallpaperScreenFingerprint
            lastSetImageURLByScreen.removeValue(forKey: screenID)
            lastSetImageURLByFingerprint.removeValue(forKey: fingerprint)
            lastOptionsByScreen.removeValue(forKey: screenID)
            lastOptionsByFingerprint.removeValue(forKey: fingerprint)
        } else {
            lastSetImageURLByScreen.removeAll()
            lastSetImageURLByFingerprint.removeAll()
            lastOptionsByScreen.removeAll()
            lastOptionsByFingerprint.removeAll()
        }
        persistFingerprintState()
    }

    func clearRegistration(screenID: String, fingerprint: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("desktop.clearIdentity", ["id": screenID, "fingerprint": fingerprint]); return }
        lastSetImageURLByScreen.removeValue(forKey: screenID)
        lastSetImageURLByFingerprint.removeValue(forKey: fingerprint)
        lastOptionsByScreen.removeValue(forKey: screenID)
        lastOptionsByFingerprint.removeValue(forKey: fingerprint)
        persistFingerprintState()
    }

    /// 应用变为活跃时的备用同步入口（处理 activeSpaceDidChangeNotification 丢失的情况）
    func syncOnAppActivation() {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("desktop.activation"); return }
        let screenCount = NSScreen.screens.count
        if screenCount <= 1, !requiresActivationRecoverySync {
            AppLogger.debug(.ui, "Desktop wallpaper activation sync skipped", metadata: [
                "reason": "singleDisplayNoRecoveryNeeded",
                "screenCount": screenCount
            ])
            return
        }

        pendingActivationSyncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.performSync(source: "appActivation")
            self.requiresActivationRecoverySync = false
        }
        pendingActivationSyncWorkItem = workItem
        // 激活应用的首帧优先给 UI；桌面跨 Space 同步延后一拍，避免把窗口唤醒卡在主线程上。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    @objc private func handleActiveSpaceChanged() {
        // 上一个 Space 的节流补跑不能抢在本次切换稳定前写入桌面。
        pendingThrottledSyncWorkItem?.cancel()
        pendingThrottledSyncWorkItem = nil
        // Debounce：快速连续切换 Space 时，取消之前的延迟任务，只保留最后一次
        pendingSyncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performSync(source: "spaceChange")
        }
        pendingSyncWorkItem = workItem
        // 延迟再同步，确保 Space 切换动画完全结束、系统桌面状态稳定后再执行
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    @objc private func handleScreenParametersChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.requiresActivationRecoverySync = true
            // 防抖：延迟 0.5s 执行
            self.pendingScreenChangeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.relinkScreenStateForCurrentDisplays()
                // 显示器变化后立即同步壁纸，确保新接入/重新枚举的显示器立即获得正确的壁纸
                self.performSync(source: "screenChange")
            }
            self.pendingScreenChangeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }

    @objc private func handleSystemDidWake() {
        // 系统唤醒后延迟同步，给 macOS 时间重新枚举所有显示器
        // 注意：不 cancel pendingScreenChangeWorkItem（那是 screenParametersChanged 的专用 work item），
        // 避免 screenParametersChanged 在唤醒期间触发时把唤醒重建任务连带后续二次重试一起 cancel 掉。
        // performSync 内部有 0.5s 节流，重复请求会合并为一次尾沿同步。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.requiresActivationRecoverySync = true
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.relinkScreenStateForCurrentDisplays()
                self.performSync(source: "systemWake")
                // 二次延迟同步：外接显示器可能 1~2 秒后才被 macOS 完全枚举
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    self.relinkScreenStateForCurrentDisplays()
                    self.performSync(source: "systemWakeRetry")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }
    }

    @objc private func handleScreensDidWake() {
        // 屏幕唤醒后延迟同步（不 cancel pendingScreenChangeWorkItem，理由同上）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.requiresActivationRecoverySync = true
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.relinkScreenStateForCurrentDisplays()
                self.performSync(source: "screensWake")
                // 二次延迟同步：应对显示器延迟枚举
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    self.relinkScreenStateForCurrentDisplays()
                    self.performSync(source: "screensWakeRetry")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }
    }

    private func relinkScreenStateForCurrentDisplays() {
        let currentScreenIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))

        // 清掉已断屏的 screenID 键；fingerprint 级注册保留，供重插 / Space 同步
        let orphanScreenIDs = Set(lastSetImageURLByScreen.keys)
            .union(lastOptionsByScreen.keys)
            .subtracting(currentScreenIDs)
        for screenID in orphanScreenIDs {
            lastSetImageURLByScreen.removeValue(forKey: screenID)
            lastOptionsByScreen.removeValue(forKey: screenID)
        }
        if !orphanScreenIDs.isEmpty {
            print("[DesktopWallpaperSyncManager] Dropped \(orphanScreenIDs.count) orphaned screenID registration(s) after disconnect")
        }

        var relinkedCount = 0
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            let fingerprint = screen.wallpaperScreenFingerprint

            if lastSetImageURLByScreen[screenID] == nil,
               let url = WallpaperScreenIdentity.value(
                   in: lastSetImageURLByFingerprint,
                   forFingerprint: fingerprint
               ) {
                lastSetImageURLByScreen[screenID] = url
                relinkedCount += 1
            }
            if lastOptionsByScreen[screenID] == nil,
               let options = WallpaperScreenIdentity.value(
                   in: lastOptionsByFingerprint,
                   forFingerprint: fingerprint
               ) {
                lastOptionsByScreen[screenID] = options
            }
        }
        if relinkedCount > 0 {
            print("[DesktopWallpaperSyncManager] Relinked wallpaper registration for \(relinkedCount) reconnected screen(s)")
        }
    }

    // MARK: - 持久化（指纹维度）

    /// 查询某块外接屏（按物理指纹）是否曾由 App 设过壁纸，用于外接屏重连时抑制"显示器接入"弹窗。
    /// 校验持久化的壁纸文件仍存在于磁盘，并跳过运行时临时 capture 路径。
    func hasPersistedWallpaperForFingerprint(_ fingerprint: String) -> Bool {
        guard let url = WallpaperScreenIdentity.value(
            in: lastSetImageURLByFingerprint,
            forFingerprint: fingerprint
        ) else { return false }
        return isVerifiedStaticImage(url) && FileManager.default.fileExists(atPath: url.path)
    }

    private func persistFingerprintState() {
        let fpDict = lastSetImageURLByFingerprint.mapValues { $0.absoluteString }
        if fpDict.isEmpty {
            WaifuXPreferences.shared.removeObject(forKey: Self.fingerprintStateKey)
        } else if let data = try? JSONSerialization.data(withJSONObject: fpDict),
                  let str = String(data: data, encoding: .utf8) {
            WaifuXPreferences.shared.set(str, forKey: Self.fingerprintStateKey)
        }
        // Static wallpaper changes have no video/overlay event when system sync
        // is enabled. Publish after updating the maps so Helper followers see it.
        NotificationCenter.default.post(name: Self.registrationDidChangeNotification, object: self)
    }

    private func loadFingerprintState() {
        guard let str = WaifuXPreferences.shared.string(forKey: Self.fingerprintStateKey),
              let data = str.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        for (fingerprint, urlString) in dict {
            lastSetImageURLByFingerprint[fingerprint] = URL(string: urlString)
        }
        migrateLegacyFingerprintStateIfNeeded()
    }

    /// 旧版无序列号指纹无法可靠地区分同型号显示器。升级时从 macOS 当前每屏
    /// 桌面读取实际壁纸重建新版状态，不能复用旧字典中的单个 URL。
    private func migrateLegacyFingerprintStateIfNeeded() {
        let screensByLegacyFingerprint = Dictionary(grouping: NSScreen.screens, by: \.legacyWallpaperScreenFingerprint)
        var didChange = false

        for (legacyFingerprint, screens) in screensByLegacyFingerprint {
            guard lastSetImageURLByFingerprint[legacyFingerprint] != nil,
                  let firstScreen = screens.first,
                  firstScreen.wallpaperScreenFingerprint != legacyFingerprint else {
                continue
            }

            lastSetImageURLByFingerprint.removeValue(forKey: legacyFingerprint)
            didChange = true

            for screen in screens {
                guard let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else {
                    continue
                }
                lastSetImageURLByFingerprint[screen.wallpaperScreenFingerprint] = currentURL
            }
        }

        if didChange {
            persistFingerprintState()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// 执行实际同步逻辑
    private func isVerifiedStaticImage(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = sourcePathByImagePath[url.standardizedFileURL.path] ?? url.standardizedFileURL.path
        guard let record = WallpaperLibraryService.shared.downloadRecord(forLocalFilePath: path) else { return false }
        return WallhavenContentPolicy.isWallpaperRecord(id: record.wallpaper.id, detailURL: record.wallpaper.url, imagePath: record.wallpaper.path)
    }

    private func performSync(source: String) {
        guard BackgroundRuntimeRole.allowsDesktopRendering, !BackgroundRuntimeRole.isIsolatedTest else { return }
        pendingThrottledSyncWorkItem?.cancel()
        pendingThrottledSyncWorkItem = nil
        if let lastSyncTime {
            let remaining = minimumSyncInterval - Date().timeIntervalSince(lastSyncTime)
            if remaining > 0 {
                let item = DispatchWorkItem { [weak self] in self?.performSync(source: source) }
                pendingThrottledSyncWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: item)
                return
            }
        }
        lastSyncTime = Date()
        relinkScreenStateForCurrentDisplays()
        for screen in NSScreen.screens {
            let id = screen.wallpaperScreenIdentifier
            let fingerprint = screen.wallpaperScreenFingerprint
            guard let url = lastSetImageURLByScreen[id]
                ?? WallpaperScreenIdentity.value(in: lastSetImageURLByFingerprint, forFingerprint: fingerprint),
                  isVerifiedStaticImage(url), FileManager.default.fileExists(atPath: url.path) else { continue }
            let options = lastOptionsByScreen[id]
                ?? WallpaperScreenIdentity.value(in: lastOptionsByFingerprint, forFingerprint: fingerprint) ?? [:]
            do {
                try NSWorkspace.shared.setDesktopImageURLForAllSpaces(url, for: screen, options: options)
            } catch {
                AppLogger.warn(.wallpaper, "Static desktop recovery failed", metadata: ["source": source, "screen": screen.localizedName, "error": error.localizedDescription])
            }
        }
    }
}

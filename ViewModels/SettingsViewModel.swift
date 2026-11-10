import SwiftUI
import Combine
import Kingfisher

@MainActor
final class SettingsViewModel: ObservableObject {
    private var isBatchUpdating = false
    private var cancellables = Set<AnyCancellable>()
    private var _schedulerViewModel: WallpaperSchedulerViewModel?
    private var _downloadTaskViewModel: DownloadTaskViewModel?
    private let apiKeyUserDefaultsKey = "wallhaven_api_key"
    private static var _cachedAPIKey: String?
    private static var _apiKeyRestored = false
    @Published var cacheSize = "0 MB"
    @Published var cacheProgress: Double = 0

    init() {}



    @Published private var themeModeRawValue: String = ThemeMode.dark.rawValue

    @Published var launchAtLogin = false { didSet { WaifuXPreferences.shared.set(launchAtLogin, forKey: "launch_at_login") } }

    @Published var swapMenuBarClickActions = false {
        didSet { WaifuXPreferences.shared.set(swapMenuBarClickActions, forKey: "menu_bar_swap_click_actions") }
    }

    @Published var preventSystemSleep = false {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(preventSystemSleep, forKey: "prevent_system_sleep")
            SleepPreventer.shared.setPreventingSleep(preventSystemSleep, reason: .userSetting)
        }
    }

    @Published var grainTextureEnabled = false {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(grainTextureEnabled, forKey: "grain_texture_enabled")
            ArcBackgroundSettings.shared.grainTextureEnabled = grainTextureEnabled
        }
    }

    @Published var grainIntensity: Double = 0.5 {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(grainIntensity, forKey: "arc_grain_intensity")
            ArcBackgroundSettings.shared.grainIntensity = grainIntensity
        }
    }

    @Published var pauseRotationOnBattery = true {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(pauseRotationOnBattery, forKey: "pause_rotation_on_battery")
        }
    }

    @Published var portraitBlurFillEnabled = false {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(portraitBlurFillEnabled, forKey: "portrait_blur_fill_enabled")
        }
    }

    @Published var hidePortraitWallpapersByDefault = true {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(
                hidePortraitWallpapersByDefault,
                forKey: WallhavenBrowsePreferences.hidePortraitByDefaultKey
            )
            NotificationCenter.default.post(name: .wallhavenDefaultFiltersChanged, object: nil)
        }
    }

    @Published var hidePeopleWallpapersByDefault = true {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(
                hidePeopleWallpapersByDefault,
                forKey: WallhavenBrowsePreferences.hidePeopleByDefaultKey
            )
            NotificationCenter.default.post(name: .wallhavenDefaultFiltersChanged, object: nil)
        }
    }

    @Published var proxyEnabled = false {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(proxyEnabled, forKey: "proxy_enabled")
            syncProxySettings()
        }
    }

    @Published var proxyHost: String = "" {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(proxyHost, forKey: "proxy_host")
            syncProxySettings()
        }
    }

    @Published var proxyPort: String = "" {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(proxyPort, forKey: "proxy_port")
            syncProxySettings()
        }
    }

    var schedulerViewModel: WallpaperSchedulerViewModel {
        if _schedulerViewModel == nil {
            _schedulerViewModel = WallpaperSchedulerViewModel()
            _schedulerViewModel!.objectWillChange
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
        return _schedulerViewModel!
    }

    var downloadTaskViewModel: DownloadTaskViewModel {
        if _downloadTaskViewModel == nil {
            _downloadTaskViewModel = DownloadTaskViewModel()
        }
        return _downloadTaskViewModel!
    }

    var apiKey: String {
        get {
            // ⚠️ 不直接读 UserDefaults！使用启动缓存
            if Self._apiKeyRestored { return Self._cachedAPIKey ?? "" }
            return ""
        }
        set {
            objectWillChange.send()
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Self._cachedAPIKey = trimmedValue.isEmpty ? nil : trimmedValue
            WaifuXPreferences.shared.set(trimmedValue, forKey: apiKeyUserDefaultsKey)

            // 同步更新 WallpaperViewModel 的 API Key 缓存，确保实时生效
            WallpaperViewModel.updateSharedAPIKeyCache(trimmedValue)
        }
    }

    func syncProxySettings() {
        Task {
            await NetworkService.shared.updateProxyConfiguration(
                enabled: proxyEnabled,
                host: proxyHost,
                port: proxyPort
            )
        }
    }

    var themeMode: ThemeMode {
        get { ThemeMode(rawValue: themeModeRawValue) ?? .system }
        set {
            objectWillChange.send()
            themeModeRawValue = newValue.rawValue
            ThemeManager.shared.themeMode = newValue
        }
    }

    var appVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return shortVersion ?? "1.0.0"
    }

    func toggleLaunchAtLogin() {
        // LaunchAgent owns login restoration; the full UI no longer launches at login.
        // The leftover pre-154 main-app login item is retired by the Helper bootstrap
        // before it registers the agent, never concurrently with it.
        BackgroundAgentClient.shared.start()
        launchAtLogin.toggle()
    }

    /// Restore after application launch; the initializers never read preferences.
    func restoreSavedSettings() {
        let defaults = WaifuXPreferences.shared
        isBatchUpdating = true
        themeModeRawValue = ThemeManager.savedMode(in: defaults).rawValue
        launchAtLogin = defaults.bool(forKey: "launch_at_login")
        swapMenuBarClickActions = defaults.bool(forKey: "menu_bar_swap_click_actions")
        preventSystemSleep = defaults.bool(forKey: "prevent_system_sleep")
        grainTextureEnabled = defaults.bool(forKey: "grain_texture_enabled")
        let intensity = defaults.object(forKey: "arc_grain_intensity") as? Double ?? 0.5
        grainIntensity = intensity.isFinite ? min(1, max(0, intensity)) : 0.5
        pauseRotationOnBattery = defaults.object(forKey: "pause_rotation_on_battery") as? Bool ?? true
        portraitBlurFillEnabled = defaults.bool(forKey: "portrait_blur_fill_enabled")
        hidePortraitWallpapersByDefault = WallhavenBrowsePreferences.hidePortraitByDefault()
        hidePeopleWallpapersByDefault = WallhavenBrowsePreferences.hidePeopleByDefault()
        proxyEnabled = defaults.bool(forKey: "proxy_enabled")
        proxyHost = defaults.string(forKey: "proxy_host") ?? ""
        proxyPort = defaults.string(forKey: "proxy_port") ?? ""
        Self._cachedAPIKey = defaults.string(forKey: apiKeyUserDefaultsKey)
        Self._apiKeyRestored = true
        isBatchUpdating = false
        ArcBackgroundSettings.shared.grainTextureEnabled = grainTextureEnabled
        ArcBackgroundSettings.shared.grainIntensity = grainIntensity
        SleepPreventer.shared.setPreventingSleep(preventSystemSleep, reason: .userSetting)
        Task { await updateCacheSize() }
    }

    func updateCacheSize() async {
        let general = (try? await WallpaperImageCache.shared.diskStorageSize) ?? 0
        let covers = (try? await LibraryCoverImageCache.imageCache.diskStorageSize) ?? 0
        let total = general + covers
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        cacheSize = formatter.string(fromByteCount: Int64(clamping: total))
        cacheProgress = min(Double(total) / 500_000_000, 1)
    }

    /// Only image caches owned by the current UI are cleared. Legacy media,
    /// downloaded originals, metadata and cloud objects are preserved.
    func clearCache() async {
        WallpaperImageCache.shared.clearMemoryCache()
        LibraryCoverImageCache.imageCache.clearMemoryCache()
        LocalImageThumbnailCache.shared.clearMemoryHints()
        await WallpaperImageCache.shared.clearDiskCache()
        await LibraryCoverImageCache.imageCache.clearDiskCache()
        URLCache.shared.removeAllCachedResponses()
        await NetworkService.shared.clearCache()
        await updateCacheSize()
    }
}

import SwiftUI
import AppKit
import AppIntents
import ServiceManagement
import Kingfisher
import ExceptionHandling
import Darwin
import Sparkle

/// 后台 Helper 连接横幅的挂载位置。
///
/// 横幅是窗口级 overlay，而 `EdgeToEdgeHostingView` 铺满整个窗口、自绘顶栏
/// （红绿灯 + Tabs）就画在最顶部那一条：直接 `overlay(alignment: .top)`
/// 会把横幅压在红绿灯与 Tabs 上面。这里让出顶栏高度，让横幅落在内容区顶部。
private extension View {
    func attachingBackgroundAgentBanner() -> some View {
        overlay(alignment: .top) {
            BackgroundAgentConnectionBanner()
                .padding(.top, MainTopBarLayout.legacyContentTopPadding)
        }
    }
}

/// Coordinates ordinary app windows with the macOS Space that is currently active.
///
/// `.moveToActiveSpace` is intentionally limited to user-facing windows. Desktop
/// wallpaper and overlay windows must keep their existing all-Spaces behavior.
@MainActor
enum WindowSpaceCoordinator {
    static var referenceWindow: NSWindow? {
        if let keyWindow = NSApp.keyWindow, keyWindow.isVisible {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, mainWindow.isVisible {
            return mainWindow
        }
        return nil
    }

    static func prepare(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    static func show(
        _ window: NSWindow,
        following referenceWindow: NSWindow? = nil,
        activate: Bool = true
    ) {
        // Ordering the reference window first brings its Space active when the
        // caller opened the action from a global menu or the status bar.
        if let referenceWindow,
           referenceWindow !== window,
           referenceWindow.isVisible {
            referenceWindow.makeKeyAndOrderFront(nil)
        }

        prepare(window)
        window.makeKeyAndOrderFront(nil)
        MainWindowVisibility.shared.refresh()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func visibleFrame(for referenceWindow: NSWindow? = nil) -> NSRect? {
        let screen = referenceWindow?.screen
            ?? self.referenceWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.visibleFrame
    }
}

private func waifuxSignalHandler(_ signo: Int32) {
    AppExitDiagnostics.recordSignal(signo)
    signal(signo, SIG_DFL)
    raise(signo)
}

private func waifuxAtExitHandler() {
    AppExitDiagnostics.record("atexit")
}

enum AppExitDiagnostics {
    nonisolated(unsafe) private static var fd: Int32 = -1

    static func install() {
        openLogIfNeeded()
        record("install", metadata: [
            "pid": getpid(),
            "bundle": Bundle.main.bundleURL.path
        ])

        atexit(waifuxAtExitHandler)
        signal(SIGTERM, waifuxSignalHandler)
        signal(SIGINT, waifuxSignalHandler)
        signal(SIGQUIT, waifuxSignalHandler)
        signal(SIGABRT, waifuxSignalHandler)
        signal(SIGILL, waifuxSignalHandler)
        signal(SIGBUS, waifuxSignalHandler)
        signal(SIGSEGV, waifuxSignalHandler)
    }

    static func record(_ message: String, metadata: [String: Any] = [:]) {
        var parts = metadata.map { "\($0.key)=\($0.value)" }.sorted()
        parts.insert("pid=\(getpid())", at: 0)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message) | \(parts.joined(separator: ", "))\n"
        write(line)
        AppLogger.error(.general, "Exit diagnostics: \(message)", metadata: metadata)
    }

    nonisolated static func recordSignal(_ signo: Int32) {
        switch signo {
        case SIGTERM:
            writeStatic("signal SIGTERM\n")
        case SIGINT:
            writeStatic("signal SIGINT\n")
        case SIGQUIT:
            writeStatic("signal SIGQUIT\n")
        case SIGABRT:
            writeStatic("signal SIGABRT\n")
        case SIGILL:
            writeStatic("signal SIGILL\n")
        case SIGBUS:
            writeStatic("signal SIGBUS\n")
        case SIGSEGV:
            writeStatic("signal SIGSEGV\n")
        default:
            writeStatic("signal unknown\n")
        }
    }

    private static func openLogIfNeeded() {
        guard fd < 0 else { return }
        var supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        #if DEBUG
        if BackgroundRuntimeRole.isIsolatedTest,
           let root = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"] {
            supportURL = URL(fileURLWithPath: root, isDirectory: true)
        }
        #endif
        let dirURL = supportURL.appendingPathComponent("WaifuX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        // 退出日志按进程生命周期累积（每次退出写几行），长期会到几百 KB。
        // 打开前按上限截尾，避免无限增长；用 O_TRUNC 原地重写保持 inode。
        let path = dirURL.appendingPathComponent("waifux-exit.log").path
        trimExitLogIfNeeded(path: path)
        fd = Darwin.open(path, O_CREAT | O_WRONLY | O_APPEND, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    }

    /// 退出日志上限（256KB）；超限保留尾部一半并回退到换行边界。
    private static let exitLogMaxBytes = 256 * 1024

    private static func trimExitLogIfNeeded(path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              size > UInt64(exitLogMaxBytes) else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let firstNewline = data.dropFirst(data.count / 2).firstIndex(of: 0x0A) else { return }
        let tail = data.subdata(in: data.index(after: firstNewline)..<data.endIndex)
        let out = Darwin.open(path, O_WRONLY | O_TRUNC)
        guard out >= 0 else { return }
        defer { Darwin.close(out) }
        tail.withUnsafeBytes { raw in
            _ = Darwin.write(out, raw.baseAddress, tail.count)
        }
    }

    private static func write(_ line: String) {
        openLogIfNeeded()
        guard fd >= 0 else { return }
        line.withCString { pointer in
            _ = Darwin.write(fd, pointer, strlen(pointer))
        }
        _ = Darwin.fsync(fd)
    }

    nonisolated private static func writeStatic(_ message: StaticString) {
        guard fd >= 0 else { return }
        _ = Darwin.write(fd, message.utf8Start, message.utf8CodeUnitCount)
    }
}

final class EdgeToEdgeHostingView<Content: View>: NSHostingView<Content> {
    private let edgeToEdgeLayoutGuide = NSLayoutGuide()

    /// macOS 15+ (Sequoia) 的 Liquid Glass 改变了 safe area 行为，
    /// 强制覆盖 safe area 为 0 会与 SwiftUI 布局引擎产生冲突导致振荡。
    private let useLegacySafeAreaOverride: Bool = {
        if #available(macOS 15.0, *) {
            return false
        }
        return true
    }()

    private let zeroInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

    required init(rootView: Content) {
        super.init(rootView: rootView)

        addLayoutGuide(edgeToEdgeLayoutGuide)
        NSLayoutConstraint.activate([
            edgeToEdgeLayoutGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            edgeToEdgeLayoutGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            edgeToEdgeLayoutGuide.topAnchor.constraint(equalTo: topAnchor),
            edgeToEdgeLayoutGuide.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // Let the first click both activate an inactive window and reach SwiftUI
    // controls. This matches standard macOS control behavior for the main UI.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var safeAreaRect: NSRect {
        useLegacySafeAreaOverride ? bounds : super.safeAreaRect
    }

    override var safeAreaInsets: NSEdgeInsets {
        useLegacySafeAreaOverride ? zeroInsets : super.safeAreaInsets
    }

    override var safeAreaLayoutGuide: NSLayoutGuide {
        useLegacySafeAreaOverride ? edgeToEdgeLayoutGuide : super.safeAreaLayoutGuide
    }

    override var additionalSafeAreaInsets: NSEdgeInsets {
        get { useLegacySafeAreaOverride ? zeroInsets : super.additionalSafeAreaInsets }
        set { if useLegacySafeAreaOverride { /* ignore */ } else { super.additionalSafeAreaInsets = newValue } }
    }
}

@main
struct WaifuXApp {
    #if os(macOS)
    private nonisolated(unsafe) static var memoryPressureSource: DispatchSourceMemoryPressure?
    #endif

    static func main() {
        #if DEBUG
        if CommandLine.arguments.contains("--helper-service-diagnostics") {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                Task { @MainActor in
                    do {
                        let values = try await BackgroundAgentClient.shared.inspectRunningService()
                        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
                        print(String(decoding: data, as: UTF8.self))
                        app.terminate(nil)
                    } catch {
                        print("HELPER_SERVICE_DIAGNOSTICS_FAILED \(error.localizedDescription)")
                        exit(1)
                    }
                }
                app.run()
            }
            return
        }
        if CommandLine.arguments.contains("--helper-ui-exit-probe") {
            MainActor.assumeIsolated {
                guard BackgroundRuntimeRole.isIsolatedTest else { exit(2) }
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                let delegate = HelperUIExitProbeDelegate()
                app.delegate = delegate
                withExtendedLifetime(delegate) { app.run() }
            }
            return
        }
        #endif

        AppExitDiagnostics.install()
        // 若不加此保护会导致信号 13 (SIGPIPE) 传递到 NSEventThread 崩溃。
        // 所有自定义 socket 已通过 SO_NOSIGPIPE 独立防护，全局忽略是安全的。
        signal(SIGPIPE, SIG_IGN)

        // 配置 Kingfisher（高性能图片加载）
        configureKingfisher()

        // 配置全局 URLCache
        let cache = makeSharedURLCache()
        URLCache.shared = cache

        // 注意：不要修改 URLSession.shared 的配置
        // 因为它是一个共享的单例，修改可能影响其他代码
        // 各服务应该使用自定义的 URLSession 配置

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// 配置 Kingfisher 高性能图片加载
    private static func configureKingfisher() {
        // 内存缓存配置：128MB / 512 张 / 15 分钟过期 / 30 秒一次清理。
        // 探索页只显示缩略图；过高的 totalCostLimit 会让 RSS 长期顶在高位。
        // 库网格封面走独立的 LibraryCoverImageCache（LibraryGridCells.swift），
        // 不受详情页大图挤占；这里放宽过期时长，减少切页/返回后的磁盘重解码。
        ImageCache.default.memoryStorage.config.totalCostLimit = 128 * 1024 * 1024 // 128MB
        ImageCache.default.memoryStorage.config.countLimit = 512
        ImageCache.default.memoryStorage.config.expiration = .seconds(15 * 60) // 15 min
        ImageCache.default.memoryStorage.config.cleanInterval = 30             // 30s

        // 磁盘缓存配置
        ImageCache.default.diskStorage.config.sizeLimit = 500 * 1024 * 1024 // 500MB
        ImageCache.default.diskStorage.config.expiration = .days(7)

        // 下载配置
        let downloader = KingfisherManager.shared.downloader
        let configuration = downloader.sessionConfiguration
        // 探索页的可见 cell、图片预取和分页请求共享该下载器；限制并发，
        // 避免快速滚动时大量请求同时占用连接和解码内存。
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        downloader.sessionConfiguration = configuration
        downloader.downloadTimeout = 60.0
        // ⚠️ 不设置全局 .backgroundDecode：
        // macOS 上某些图片（16bpc、非 RGB 色彩空间等）在后台解码时 CGContext 创建会失败，
        // 触发 "[Kingfisher] Image context cannot be created." 崩溃。
        // macOS 14+ Core Graphics 已能高效处理离屏渲染，无需全局后台解码。
        KingfisherManager.shared.defaultOptions = [
            .retryStrategy(DelayRetryStrategy(maxRetryCount: 2, retryInterval: .accumulated(1.0))),
            .requestModifier(AnyModifier { request in
                guard let url = request.url, WallhavenContentPolicy.isImageRequestURL(url) else { return nil }
                var request = request
                request.timeoutInterval = max(request.timeoutInterval, 45)
                applyImageRequestHeaders(to: &request)
                return request
            })
        ]

        // 设置内存压力处理（使用 DispatchSource）
        #if os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler {
            // 内存紧张时清理所有内存缓存
            ImageCache.default.clearMemoryCache()
            LibraryCoverImageCache.imageCache.clearMemoryCache()
            Task { @MainActor in
                LocalImageThumbnailCache.shared.clearMemoryHints()
                NotificationCenter.default.post(name: .appDidReceiveMemoryPressure, object: nil)
            }
        }
        source.resume()
        memoryPressureSource = source
        #endif
    }

    private static func makeSharedURLCache() -> URLCache {
        let memoryCapacity = 50_000_000
        let diskCapacity = 500_000_000
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("WaifuXImageCache", isDirectory: true)

        if let cacheDirectory {
            do {
                try FileManager.default.createDirectory(
                    at: cacheDirectory,
                    withIntermediateDirectories: true
                )
                return URLCache(
                    memoryCapacity: memoryCapacity,
                    diskCapacity: diskCapacity,
                    directory: cacheDirectory
                )
            } catch {
                print("[WaifuXApp] Failed to create URLCache directory at \(cacheDirectory.path): \(error)")
            }
        }

        return URLCache(
            memoryCapacity: memoryCapacity,
            diskCapacity: diskCapacity,
            diskPath: nil
        )
    }

    private static func applyImageRequestHeaders(to request: inout URLRequest) {
        request.setValue("WaifuX/Wallhaven", forHTTPHeaderField: "User-Agent")
        request.setValue("image/jpeg,image/png,image/webp,image/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("https://wallhaven.cc/", forHTTPHeaderField: "Referer")
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency SPUStandardUserDriverDelegate, @preconcurrency SPUUpdaterDelegate {
    var window: NSWindow?
    // ⚠️ 延迟初始化 SettingsViewModel，不在 AppDelegate 属性初始化阶段创建
    // 避免其 @Published didSet 在 applicationDidFinishLaunching 之前写 UserDefaults
    private var settingsViewModel: SettingsViewModel?
    private var settingsWindowController: NSWindowController?
    private var uiRequestRouter = WaifuXUIActions.RequestRouter()
    private var mainWindowDataRestored = false
    /// 登录项启动标记：`oapp` 事件带 `lgit` 即为开机自启动。
    /// 必须在 didFinishLaunching 同步捕获（事件派发期内 currentAppleEvent 才有效），
    /// 异步建窗时据此跳过默认主窗口 —— 壁纸恢复由 Helper 负责，主界面不再自动弹出。
    private var launchedAsLoginItem = false
    /// 窗口隐藏后延迟释放视图树的任务，用于回收 IOSurface / CoreAnimation 等系统图形缓存
    private var delayedReleaseTask: Task<Void, Never>?
    /// Sparkle 自动更新控制器（检测 + 内置弹窗 + 自动安装）
    private var updaterController: SPUStandardUpdaterController!
    /// 更新检查期间暂时隐藏设置窗口，避免遮挡 Sparkle 的状态或结果窗口。
    private var shouldRestoreSettingsWindowAfterUpdateCheck = false
    /// 静态访问器，供 Settings 等外部触发更新检查
    static var shared: AppDelegate?

    // MARK: - 全局 ViewModel（生命周期与 App 一致）
    /// 这 3 个 ViewModel 由 AppDelegate 持有，传入 ContentView 时用普通 let 引用而非 @StateObject。
    /// 设计目的：避免 ContentView 因 @StateObject 响应 ViewModel 的 @Published 变化而重算 body
    /// （会连锁导致下游 5 个 tab 子视图重建 binding/参数 → 全量重算）。
    /// 同时让 ViewModel 不再随主窗口隐藏/重建而销毁，避免数据重新加载。
    // Settings-only launches and bare-window tests must not initialize feeds.
    lazy var wallpaperViewModel = WallpaperViewModel()

    // MARK: - 窗口尺寸（唯一真实来源，全局统一）
    /// 最小允许的窗口大小
    private static let minimumWindowSize = NSSize(width: 1150, height: 720)

    /// 默认窗口大小：根据屏幕尺寸动态计算（首次启动或无保存状态时使用）
    private static var defaultWindowSize: NSSize {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            return NSSize(width: 1400, height: 880) // 兜底值
        }
        let available = screen.visibleFrame
        // 取屏幕可用区域的 ~78% 宽度，~92% 高度，给首页轮播和内容区留足空间
        let width = max(minimumWindowSize.width, floor(available.width * 0.78))
        let height = max(minimumWindowSize.height, floor(available.height * 0.92))
        return NSSize(width: width, height: height)
    }

    // MARK: - 窗口自动保存名称
    private enum WindowAutosaveName {
        static let mainWindow = "WaifuXMainWindow"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        launchedAsLoginItem = Self.wasLaunchedAsLoginItem()
        // 历史版本曾把主 App 注册为登录项；服务拆到 Helper 后登录恢复归 LaunchAgent。
        // 残留的清理挪进了 BackgroundAgentClient 的 bootstrap，等注销在 BTM 落地后才注册
        // Helper：两者写同一条 WaifuX 父记录，这里同步 unregister 后立刻 start() 会抢跑，
        // 154 在用户机上留下 launchd 找不到 App 路径的坏记录（exit 78）。
        installHelperQuitHandlers()
        WaifuXPreferences.shared.loadLegacyPreferences()
        BackgroundAgentClient.shared.start()
        AppResponsivenessMonitor.startIfNeeded()
        AppResponsivenessMonitor.noteScenePhase("didFinishLaunching")
        AppResponsivenessMonitor.noteAppActive(NSApp.isActive)

        // [AnimTracker] 后台 CPU 诊断：动画存活心跳 + 主窗口遮挡状态
        RepeatForeverAnimationTracker.shared.startHeartbeat()
        #if DEBUG
        // 遮挡日志只是诊断手段，Release 下由 MainWindowVisibility 的节流日志覆盖，
        // 这里不再为每条通知构造字符串（issue #119 的空转来源之一）。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let win = note.object as? NSWindow else { return }
            let state = win.occlusionState.contains(.visible) ? "visible" : "occluded"
            let name = win.title.isEmpty ? (win.identifier?.rawValue ?? "?") : win.title
            AppLogger.throttled(.error, .general, key: "window.occlusion.\(name)", interval: 10,
                                "[AnimTracker] occlusion \(name) -> \(state)")
        }
        #endif
        // ⚠️ ⚠️ 关键：所有 UserDefaults 读取都必须在 applicationDidFinishLaunching 中延迟恢复！
        // 绝对不能在任何单例 init() 中读 UserDefaults，macOS 26+ 会触发 _CFXPreferences
        // 隐式递归导致主线程栈溢出崩溃（EXC_BAD_ACCESS SIGSEGV, 174K 层递归）
        // macOS 26.5 beta 上这个问题更加严格，即使 @AppStorage 属性包装器 init 也会触发
        //
        // 在下一个 run loop 恢复设置，然后按请求创建目标窗口。

        // 设置标准菜单栏（包含 Edit 菜单，使 TextField 支持复制粘贴）
        setupMainMenu()

        // 捕获 macOS 布局循环异常（NSHostingView + NSCollectionView 混合布局的已知问题）
        // _postWindowNeedsLayout 在 _layoutViewTree 期间被触发时会抛出此异常
        setupLayoutExceptionHandler()

        // 初始化 Sparkle 自动更新（检测 + 内置弹窗 + 自动安装）
        // 拆架构分发：appcast 每个版本有 arm64 / x86_64 两个 item（sparkle:channel），
        // 这里按当前包架构声明 allowedChannels，Sparkle 只会选中对应架构的更新包。
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )

        // 状态栏由 Helper 持有；UI 只接收明确的窗口/操作请求。
        WaifuXUIActions.handler = { [weak self] action in
            switch action {
            case .main: self?.showMainWindow()
            case .library:
                MainNavigationRequestStore.requestLibraryTab()
                self?.showMainWindow()
            case .wallpaperDetail:
                WaifuXPreferences.shared.synchronize()
                self?.showMainWindow()
                NotificationCenter.default.post(name: .openCurrentWallpaperDetail, object: nil)
            case .settings: self?.showSettingsWindow(nil)
            case .scheduler:
                WaifuXPreferences.shared.set(true, forKey: "settings.openSchedulerOnNextAppearance")
                self?.showSettingsWindow(nil)
                NotificationCenter.default.post(name: .openSchedulerSettings, object: nil)
            case .updates: self?.checkForUpdates()
            case .releaseMemory: self?.releaseForegroundMemoryNow()
            }
        }

        // ⚠️ 在创建 ContentView 之前刷新功能模块启动快照。
        // ContentView 的 MainTabViewController.configure 在 makeNSViewController（视图设置）即跑，
        // 直接读 UserDefaults 是安全的（非 @AppStorage、非 init 读取，与已存在的 line 316/399 一致）。

        // Restore preferences after launch, then create only the requested UI.
        // Helper URLs also carry launch arguments, so a late URL event cannot
        // cause the main window to flash during a settings-only cold start.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreAllDataAsync()
            // 系统壁纸缓存清理只在这里激活：执行者刻意是主 App，因为要清理的目标在
            // wallpaper agent 的容器里、受 TCC 保护，而授权对象必须是隐私面板里可见的 WaifuX
            // （Helper 藏在 Contents/Helpers/ 下，用户既找不到也拖不进去）。
            // noteAppLaunch 内部自带 90 秒错峰 + 10 分钟节流 + 24h 兜底，不阻塞启动。
            WallpaperSystemCacheJanitor.shared.noteAppLaunch()
            var actions = self.uiRequestRouter.start(arguments: CommandLine.arguments)
            if self.launchedAsLoginItem, WaifuXPreferences.shared.bool(forKey: "launch_at_login") {
                // 开机自启动：Helper 负责恢复壁纸，主窗口不再自动弹出。
                // 用户明确的 UI 请求（菜单栏/Helper openUI）不受影响，照常弹窗。
                actions.removeAll { $0 == .main }
                if actions.isEmpty {
                    self.enterBackgroundModeIfNoForegroundInterface(hideDockIcon: true)
                    return
                }
            }
            for action in actions {
                WaifuXUIActions.perform(action)
            }
        }

        // Sparkle 自动按 SUScheduledCheckInterval (24h) 检查更新，无需手动触发
    }

    /// 触发 Sparkle 更新检查（供 Settings "检查更新" 按钮调用）
    func checkForUpdates() {
        if let settingsWindow = settingsWindowController?.window, settingsWindow.isVisible {
            shouldRestoreSettingsWindowAfterUpdateCheck = true
            settingsWindow.orderOut(nil)
        }
        updaterController.checkForUpdates(nil)
    }

    /// Sparkle 按架构分发：只接受与当前包架构一致的 channel。
    /// appcast 中每个版本的 item 带 <sparkle:channel>arm64|x86_64</sparkle:channel>，
    /// 旧版 universal 客户端未声明 channel，会自动忽略所有带 channel 的 item（不会误装错架构包）。
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        {
            #if arch(arm64)
            return ["arm64"]
            #else
            return ["x86_64"]
            #endif
        }()
    }

    /// Waiting for the app-update session to finish avoids competing update prompts.

    func standardUserDriverWillShowModalAlert() {
        hideSettingsWindowForUpdateCheck()
    }

    func standardUserDriverDidShowModalAlert() {
        restoreSettingsWindowAfterUpdateCheck()
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        hideSettingsWindowForUpdateCheck()
    }

    func standardUserDriverWillFinishUpdateSession() {
        restoreSettingsWindowAfterUpdateCheck()
    }

    private func hideSettingsWindowForUpdateCheck() {
        guard let settingsWindow = settingsWindowController?.window, settingsWindow.isVisible else { return }
        shouldRestoreSettingsWindowAfterUpdateCheck = true
        settingsWindow.orderOut(nil)
    }

    private func restoreSettingsWindowAfterUpdateCheck() {
        guard shouldRestoreSettingsWindowAfterUpdateCheck else { return }
        shouldRestoreSettingsWindowAfterUpdateCheck = false
        guard let settingsWindow = settingsWindowController?.window else { return }
        WindowSpaceCoordinator.show(settingsWindow)
    }

    // MARK: - 延迟恢复共享 UI 数据；探索页数据在主窗口打开时恢复
    private func restoreAllDataAsync() {
        LocalizationService.shared.restoreSavedSettings()
        ThemeManager.shared.restoreSavedSettings()
        WallpaperLibraryService.shared.restoreSavedData()
        LibraryFolderStore.shared.restoreSavedData()
        DownloadTaskService.shared.restoreSavedTasks()
        if settingsViewModel == nil {
            let vm = SettingsViewModel()
            vm.restoreSavedSettings()
            settingsViewModel = vm
        }
    }

    private func restoreMainWindowDataIfNeeded() {
        guard !mainWindowDataRestored else { return }
        mainWindowDataRestored = true
        wallpaperViewModel.restoreExploreSortPreferences()
        wallpaperViewModel.restoreAPIKeyState()
        // 壁纸数据源不再有启动自动选择（ping Google / VPN 检测已移除）；
        // 源只由用户手动切换，restoreAllDataAsync() 里的 restoreState() 负责恢复持久化选择。
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let request = WaifuXUIActions.Request(url: url) else { continue }
            if let action = uiRequestRouter.receive(request) {
                WaifuXPreferences.shared.synchronize()
                WaifuXUIActions.perform(action)
            }
        }
    }

    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 当用户点击 Dock 图标时显示主窗口
        showMainWindow()
        return false // The requested window was handled; skip AppKit's default ordering.
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppResponsivenessMonitor.noteAppActive(true)
        AppResponsivenessMonitor.noteScenePhase("didBecomeActive")
        AppResponsivenessMonitor.noteForegroundActivation(reason: "applicationDidBecomeActive")
        // 备用同步：当应用重新变为活跃时，检查并同步跨 Space 壁纸
        // 因为 activeSpaceDidChangeNotification 在应用后台时可能不可靠
        DesktopWallpaperSyncManager.shared.syncOnAppActivation()
    }

    func applicationDidResignActive(_ notification: Notification) {
        AppResponsivenessMonitor.noteAppActive(false)
        AppResponsivenessMonitor.noteScenePhase("didResignActive")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if !helperExitInProgress { prepareForInterfaceExit() }
        return true
    }

    private var helperExitInProgress = false
    private var helperExitApproved = false
    private var exitsInterfaceOnly = false
    /// 退出链已进入「Helper 确认停止、等它真正退出」的阶段。这个阶段
    /// 不该再受 6s 应用级看门狗约束（见 applicationShouldTerminate 的计时分解）。
    private var helperStopPhaseStarted = false
    private var interfaceRelaunchURL: URL?
    private var helperExitGeneration: UInt = 0
    private var helperExitTask: Task<Void, Never>?

    func installHelperQuitHandlers() {
        BackgroundAgentClient.shared.onApplicationQuitRequested = { [weak self] in self?.quitApplication() }
        BackgroundAgentClient.shared.onHelperStopped = { [weak self] in
            // stopped is sent before final worker cleanup and process exit.
            // Follow the normal quit path so the client still confirms exit.
            self?.quitApplication()
        }
    }

    /// Window close and an intentional UI relaunch preserve the background owner.
    func prepareForInterfaceExit() {
        guard !helperExitInProgress else { return }
        exitsInterfaceOnly = true
    }

    func exitInterface() {
        prepareForInterfaceExit()
        NSApp.terminate(nil)
    }

    func relaunchInterface() {
        guard !helperExitInProgress else { return }
        interfaceRelaunchURL = Bundle.main.bundleURL
        markIntentionalTermination(reason: "relaunch")
        AppExitDiagnostics.record("relaunchRequested", metadata: ["bundle": Bundle.main.bundleURL.path])
        exitInterface()
    }

    private func completeUIExit(_ sender: NSApplication) throws {
        guard !helperExitApproved else { return }
        if let bundleURL = interfaceRelaunchURL {
            // The writer has acknowledged the final settings before a new UI
            // can read them. No asynchronous gap separates launch from exit.
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launcher.arguments = ["-n", bundleURL.path]
            launcher.standardOutput = FileHandle.nullDevice
            launcher.standardError = FileHandle.nullDevice
            try launcher.run()
            interfaceRelaunchURL = nil
            AppExitDiagnostics.record("relaunchTerminate")
        }
        helperExitApproved = true
        sender.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if helperExitApproved { return .terminateNow }
        guard !helperExitInProgress else { return .terminateCancel }
        helperExitInProgress = true
        helperExitGeneration &+= 1
        let generation = helperExitGeneration
        helperStopPhaseStarted = false
        if !exitsInterfaceOnly { BackgroundAgentClient.shared.beginApplicationQuit() }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let metadata: [String: Any] = [
            "frontmostApp": frontmost?.localizedName ?? "nil",
            "frontmostBundle": frontmost?.bundleIdentifier ?? "nil",
            "appActive": NSApp.isActive,
            "appHidden": NSApp.isHidden,
            "mainWindowVisible": window?.isVisible ?? false,
            "settingsWindowVisible": settingsWindowController?.window?.isVisible ?? false,
            "decision": "allow",
            "scope": exitsInterfaceOnly ? "interface" : "application"
        ]
        AppExitDiagnostics.record("applicationShouldTerminate", metadata: metadata)
        // Keep the ordinary event loop running while acknowledging queued writes.
        // .terminateLater enters AppKit's modal loop; a programmatic close from
        // a main-queue/concurrency callback can then block both drain and timeout.
        helperExitTask = Task {
            do {
                try await BackgroundAgentClient.shared.drainForUIExit(interfaceOnly: exitsInterfaceOnly)
                AppExitDiagnostics.record("quitDrainCompleted")
                guard generation == helperExitGeneration, !Task.isCancelled else { return }
                if exitsInterfaceOnly {
                    // The Helper can finish this sync after the UI process exits.
                    // An unresponsive Helper must not hold the UI past the bounded
                    // close fallback: the window close intent already preserves it.
                    await BackgroundAgentClient.shared.requestBounded("cloud.syncOnUIExit", timeoutSeconds: 2)
                    AppExitDiagnostics.record("quitCloudSyncBounded")
                }
                guard generation == helperExitGeneration, !Task.isCancelled else { return }
                if !exitsInterfaceOnly {
                    // Helper 已收到停止请求后的等待不再受 6s 应用级看门狗约束：
                    helperStopPhaseStarted = true
                    try await BackgroundAgentClient.shared.stopForApplicationQuit()
                }
                guard generation == helperExitGeneration, !Task.isCancelled else { return }
                try completeUIExit(sender)
            } catch { failApplicationQuit(error, generation: generation) }
        }
        Task {
            // 计时分解（同时满足两条验收判据）：
            // · drain 阶段 6s：unresponsive Helper 在这里由待存设置的 2s 重放
            //   超时先失败，或 6s 看门狗直接失败 —— 都不会进入 stop 阶段，
            //   所以仍是「6s 内失败并保留 UI」。
            // · stop 阶段再给 12s（合计 18s）：Helper 已应答 runtime.stop，
            //   正在收尾渲染器/子进程；正常路径秒退，full-quit 探针 15s
            //   deadline 之前完成。
            try? await Task.sleep(for: .seconds(6))
            guard generation == helperExitGeneration, !helperExitApproved else { return }
            if helperStopPhaseStarted {
                try? await Task.sleep(for: .seconds(12))
                guard generation == helperExitGeneration, !helperExitApproved else { return }
                failApplicationQuit(NSError(domain: "WaifuXHelper", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: t("后台服务停止超时，请重试退出 WaifuX")]), generation: generation)
                return
            }
            failApplicationQuit(NSError(domain: "WaifuXHelper", code: 3,
                userInfo: [NSLocalizedDescriptionKey: exitsInterfaceOnly
                    ? t("后台保存设置超时，界面尚未退出")
                    : t("后台服务停止超时")]), generation: generation)
        }
        return .terminateCancel
    }

    private func failApplicationQuit(_ error: Error, generation: UInt) {
        guard generation == helperExitGeneration, !helperExitApproved else { return }
        helperExitGeneration &+= 1
        helperExitTask?.cancel()
        helperExitTask = nil
        helperExitInProgress = false
        helperStopPhaseStarted = false
        // 本次失败的判别要在复位前取走：exitsInterfaceOnly 只描述「刚发起的这次退出」，
        // 不能渗漏到下一次退出（否则关窗口失败一次后，Cmd+Q 会被误判成关窗口）。
        let wasInterfaceOnly = exitsInterfaceOnly
        exitsInterfaceOnly = false
        interfaceRelaunchURL = nil
        BackgroundAgentClient.shared.applicationQuitFailed(error)
        AppLogger.error(.general, "Application quit failed; UI retained", metadata: [
            "error": error.localizedDescription,
            "scope": wasInterfaceOnly ? "interface" : "application",
        ])
        applicationQuitDidFail(interfaceOnly: wasInterfaceOnly)
    }

    /// 退出失败的收尾。完整退出失败时把主窗口弹回，让用户看到「没退成」；
    /// 关窗口失败不弹回——用户意图就是收起窗口，进程与横幅保留，
    /// 连接恢复后待存设置由 `BackgroundAgentClient` 自动回放，无需打断用户。
    func applicationQuitDidFail(interfaceOnly: Bool) {
        guard !interfaceOnly else { return }
        showMainWindow()
    }

    func showMainWindow() {
        // 取消待执行的延迟释放，避免重新打开窗口后视图树被意外清空
        delayedReleaseTask?.cancel()
        delayedReleaseTask = nil

        updateActivationPolicy(showDockIcon: true)
        restoreMainWindowDataIfNeeded()

        if window == nil {
            let contentView = ContentView(
                wallpaperViewModel: wallpaperViewModel
            )
                .frame(
                    minWidth: Self.minimumWindowSize.width,
                    minHeight: Self.minimumWindowSize.height
                )

            // ⚠️ 使用 defer: false 立即显示窗口
            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            window?.title = "WaifuX"
            window?.titlebarAppearsTransparent = true
            window?.titleVisibility = .hidden
            window?.isOpaque = true
            window?.backgroundColor = NSColor(Color(hex: "0D0D0D"))
            window?.isReleasedWhenClosed = false
            if #available(macOS 15.0, *) {
                window?.titlebarSeparatorStyle = .none
            }
            window?.minSize = Self.minimumWindowSize
            window?.collectionBehavior = .fullScreenPrimary
            if let window {
                WindowSpaceCoordinator.prepare(window)
            }

            // 隐藏系统红绿灯（使用自定义 CustomWindowControls）
            window?.standardWindowButton(.closeButton)?.isHidden = true
            window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window?.standardWindowButton(.zoomButton)?.isHidden = true

            // ⚠️ 先设置 contentView，再恢复保存的窗口尺寸
            let hostingView = EdgeToEdgeHostingView(rootView: contentView.defaultAppStorage(WaifuXPreferences.shared).attachingBackgroundAgentBanner())
            configureOpaqueHostingView(hostingView)
            window?.contentView = hostingView

            // 恢复保存的窗口尺寸
            window?.setFrameAutosaveName(WindowAutosaveName.mainWindow)
            if !hasSavedWindowFrame() { window?.center() }

            window?.delegate = self
        } else if window?.contentView == nil {
            // 视图树之前已被释放，重新挂载
            let contentView = ContentView(
                wallpaperViewModel: wallpaperViewModel
            )
                .frame(
                    minWidth: Self.minimumWindowSize.width,
                    minHeight: Self.minimumWindowSize.height
                )
            let hostingView = EdgeToEdgeHostingView(rootView: contentView.defaultAppStorage(WaifuXPreferences.shared).attachingBackgroundAgentBanner())
            configureOpaqueHostingView(hostingView)
            window?.contentView = hostingView
        }

        // 确保窗口显示在最前面
        if let window = window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }

            // macOS 14+ 需要延迟一点时间来确保窗口正确显示
            if #available(macOS 14.0, *) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, let window = self.window else { return }
                    WindowSpaceCoordinator.show(window)
                }
            } else {
                WindowSpaceCoordinator.show(window)
            }
        }
        AppResponsivenessMonitor.noteWindowVisible(true)
        AppResponsivenessMonitor.noteScenePhase("showMainWindow")
    }

    func hideMainWindow() {
        window?.orderOut(nil)
        MainWindowVisibility.shared.refresh()
        AppResponsivenessMonitor.noteWindowVisible(false)
        AppResponsivenessMonitor.noteScenePhase("hideMainWindow")
        enterBackgroundModeIfNoForegroundInterface(hideDockIcon: true)

        delayedReleaseTask?.cancel()
        delayedReleaseTask = Task { @MainActor in
            // 先让窗口服务器完成 orderOut，避免拆 contentView 时和窗口隐藏动画抢布局。
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            NotificationCenter.default.post(name: .appDidHideWindow, object: nil)
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            guard let window = self.window, !window.isVisible else { return }
            self.releaseForegroundResourcesForHiddenWindow(window)

            self.delayedReleaseTask = nil
        }
    }

    func releaseForegroundMemoryNow() {
        delayedReleaseTask?.cancel()
        delayedReleaseTask = nil

        guard let window else {
            enterBackgroundModeIfNoForegroundInterface(hideDockIcon: true)
            DisplaySelectorManager.shared.cancelForMemoryRelease()
            ForegroundPrefetchManager.shared.stopAll()
            KingfisherManager.shared.downloader.cancelAll()
            ImageCache.default.clearMemoryCache()
            LibraryCoverImageCache.imageCache.clearMemoryCache()
            LocalImageThumbnailCache.shared.clearMemoryHints()
            URLCache.shared.removeAllCachedResponses()
            Task(priority: .utility) {
                // ExploreGridImageLoader 已移除
                await NetworkService.shared.clearCache()
            }
            return
        }

        if window.isVisible {
            window.orderOut(nil)
        }

        enterBackgroundModeIfNoForegroundInterface(hideDockIcon: true)

        releaseForegroundResourcesForHiddenWindow(window)
    }

    private func releaseForegroundResourcesForHiddenWindow(_ window: NSWindow) {
        AppResponsivenessMonitor.noteScenePhase("releaseForegroundResources")
        // 窗口隐藏时锁定所有加密文件夹
        FolderLockService.shared.lockAllFolders()

        NotificationCenter.default.post(name: .appShouldReleaseForegroundMemory, object: nil)
        DisplaySelectorManager.shared.cancelForMemoryRelease()

        // 释放视图树是回收系统图形缓存（IOSurface、CALayer backing store）的关键。
        ForegroundPrefetchManager.shared.stopAll()
        KingfisherManager.shared.downloader.cancelAll()
        autoreleasepool {
            window.contentView = nil
        }

        PreviewWindowManager.shared.closePreview()
        ImageCache.default.clearMemoryCache()
        LibraryCoverImageCache.imageCache.clearMemoryCache()
        LocalImageThumbnailCache.shared.clearMemoryHints()
        URLCache.shared.removeAllCachedResponses()

        Task(priority: .utility) {
            // ExploreGridImageLoader 已移除
            await NetworkService.shared.clearCache()
        }
    }

    private func configureOpaqueHostingView<Content: View>(_ hostingView: EdgeToEdgeHostingView<Content>) {
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor(Color(hex: "0D0D0D")).cgColor
        hostingView.layer?.isOpaque = true
    }

    func quitApplication() {
        exitsInterfaceOnly = false
        BackgroundAgentClient.shared.beginApplicationQuit()
        markIntentionalTermination(reason: "quitApplication")
        AppExitDiagnostics.record("quitApplication")
        NSApp.terminate(nil)
    }

    /// Records application-controlled exits for diagnostics without altering termination policy.
    func markIntentionalTermination(reason: String) {
        AppExitDiagnostics.record("intentionalTerminationMarked", metadata: [
            "reason": reason
        ])
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppExitDiagnostics.record("applicationWillTerminate")
        BackgroundAgentClient.shared.disconnect()
    }

    /// 捕获 macOS 窗口布局循环异常。
    /// 当 NSHostingView（SwiftUI）和 NSCollectionView（AppKit）混合布局时，
    /// 窗口的 _layoutViewTree 可能触发 _postWindowNeedsLayout 导致无限布局循环崩溃。
    /// NSExceptionHandler 只能记录日志，无法真正抑制异常（异常仍会被重新抛出）。
    /// 真正的修复应确保所有 UI 操作都在主线程执行。
    private func setupLayoutExceptionHandler() {
        // 设置未捕获异常处理器，仅用于日志记录
        NSSetUncaughtExceptionHandler { exception in
            AppExitDiagnostics.record("uncaughtException", metadata: [
                "name": exception.name.rawValue,
                "reason": exception.reason ?? "nil"
            ])
            if exception.name.rawValue == "NSGenericException",
               let reason = exception.reason,
               reason.contains("Layout Window") {
                AppLogger.error(.general, "检测到窗口布局循环异常（未捕获）: \(reason)")
            }
        }

        // NSExceptionHandler 用于在异常传播过程中记录日志
        guard let handler = NSExceptionHandler.default() else { return }
        handler.setDelegate(LayoutExceptionHandlerDelegate.shared)
        let mask = NSLogOtherExceptionMask | NSHandleOtherExceptionMask
            | NSLogUncaughtExceptionMask | NSHandleUncaughtExceptionMask
            | NSHandleUncaughtSystemExceptionMask
        handler.setExceptionHandlingMask(mask)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu(title: "MainMenu")

        // App 菜单
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "WaifuX")
        appMenu.addItem(NSMenuItem(title: "About WaifuX", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        let settingsItem = NSMenuItem(title: t("settings") + "…", action: #selector(showSettingsWindow(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide WaifuX", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let quitItem = NSMenuItem(title: "Quit WaifuX", action: #selector(quitApplicationFromMainMenu(_:)), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit 菜单（使 TextField 支持 Cmd+C / Cmd+V / Cmd+A 等）
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window 菜单
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func quitApplicationFromMainMenu(_ sender: Any?) {
        quitApplication()
    }

    /// 是否为登录项启动：LaunchServices 随 `oapp` 事件在 `keyAEPropData` 里带 `lgit`。
    /// 四字符码取值来自 SDK 头（AE/AppleEvents.h `kAEOpenApplication='oapp'`、
    /// AERegistry.h `keyAEPropData='prdt'` / `keyAELaunchedAsLogInItem='lgit'`），
    /// 直接写字面量，避免引入 Carbon 导入。Apple 原话：登录启动的应用
    /// "probably shouldn't open up untitled documents" —— 对我们即不弹主窗口。
    /// 必须在启动事件派发期内同步调用；取不到事件时返回 false（保持原行为）。
    private static func wasLaunchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        guard event.eventID == AEEventID(0x6F61_7070) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(0x7072_6474))?.enumCodeValue == OSType(0x6C67_6974)
    }

    private func updateActivationPolicy(showDockIcon: Bool) {
        let desiredPolicy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != desiredPolicy {
            NSApp.setActivationPolicy(desiredPolicy)
        }
    }

    /// Drop the app's foreground identity once its user-facing windows are gone.
    /// Background wallpaper/render/download services keep running under accessory mode.
    private func enterBackgroundModeIfNoForegroundInterface(hideDockIcon: Bool) {
        let mainWindowVisible = window.map { $0.isVisible && !$0.isMiniaturized } ?? false
        let settingsWindowVisible = settingsWindowController?.window.map {
            $0.isVisible && !$0.isMiniaturized
        } ?? false
        guard !mainWindowVisible, !settingsWindowVisible else { return }

        if hideDockIcon {
            updateActivationPolicy(showDockIcon: false)
        }
        if NSApp.isActive {
            NSApp.deactivate()
        }
    }

    // MARK: - 设置窗口

    @objc func showSettingsWindow(_ sender: Any?) {
        updateActivationPolicy(showDockIcon: true)
        // 如果窗口已存在，直接显示（最快路径）
        if let settingsWindow = settingsWindowController?.window {
            if settingsWindow.isMiniaturized { settingsWindow.deminiaturize(nil) }
            WindowSpaceCoordinator.show(settingsWindow)
            return
        }

        // Run on the main actor without scheduling another task: rapid requests
        // must see the same controller instead of creating multiple windows.
        if settingsViewModel == nil {
            let vm = SettingsViewModel()
            vm.restoreSavedSettings()
            settingsViewModel = vm
        }
        createAndShowSettingsWindow()
    }

    private func createAndShowSettingsWindow() {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = t("settings")
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.titleVisibility = .hidden
        settingsWindow.isMovableByWindowBackground = false
        settingsWindow.backgroundColor = NSColor(Color(hex: "1C1C1E"))
        settingsWindow.setContentSize(NSSize(width: 680, height: 520))
        settingsWindow.minSize = NSSize(width: 680, height: 520)
        settingsWindow.maxSize = NSSize(width: 680, height: 520)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.level = .normal
        WindowSpaceCoordinator.prepare(settingsWindow)
        settingsWindow.center()
        settingsWindow.tabbingMode = .disallowed
        // 设置窗口复用 AppDelegate 作为 delegate，windowShouldClose 据此区分处理
        settingsWindow.delegate = self

        settingsWindow.contentView = EdgeToEdgeHostingView(
            rootView: SettingsView(viewModel: settingsViewModel!).defaultAppStorage(WaifuXPreferences.shared)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        )

        let windowController = NSWindowController(window: settingsWindow)
        settingsWindowController = windowController
        windowController.showWindow(nil)
        WindowSpaceCoordinator.show(settingsWindow)
    }

}

#if DEBUG
/// Runs the production close/terminate delegates on an empty AppKit window.
/// Full ContentView startup and real SMAppService registration are excluded.
@MainActor
private final class HelperUIExitProbeDelegate: AppDelegate {
    private var deferredExitObserved = false

    override func applicationDidFinishLaunching(_ notification: Notification) {
        installHelperQuitHandlers()
        let probeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        probeWindow.isReleasedWhenClosed = false
        probeWindow.delegate = self
        window = probeWindow
        Task {
            do {
                if let scenario = ProcessInfo.processInfo.environment["WAIFUX_UI_CLIENT_PROBE_SCENARIO"] {
                    try await runClientLifecycleProbe(scenario, window: probeWindow)
                    return
                }
                try await BackgroundAgentClient.shared.startIsolatedUIExitProbe()
                let operation = ProcessInfo.processInfo.environment["WAIFUX_UI_EXIT_PROBE_CLOUD"]
                if operation == "sync" { await CloudSyncService.shared.sync() }
                if operation == "restore" { await CloudSyncService.shared.restoreFromCloud() }
                if operation != nil {
                    guard CloudSyncService.shared.lastError == nil else {
                        throw CloudSyncService.shared.lastError!
                    }
                    print("UI_CLOUD_PROXY_PASSED operation=\(operation!)")
                }
                guard let value = ProcessInfo.processInfo.environment["WAIFUX_UI_EXIT_PROBE_VALUE"] else {
                    throw CocoaError(.coderInvalidValue)
                }
                print("UI_EXIT_PROBE_CONNECTED pid=\(getpid()) players=0 wallpaperWindows=0")

                if ProcessInfo.processInfo.environment["WAIFUX_UI_EXIT_PROBE_UNRESPONSIVE_HELPER"] == "1" {
                    try await BackgroundAgentClient.shared.pauseIsolatedHelperForExitProbe()
                    print("UI_EXIT_PROBE_HELPER_PAUSED")
                }
                // Do not wait for this write here: the actual close delegate
                // must drain the queued preference before terminating.
                WaifuXPreferences.shared.set(value, forKey: "regression_ui_exit_ack")
                let action = ProcessInfo.processInfo.environment["WAIFUX_UI_EXIT_PROBE_ACTION"]
                if action == "helper-quit" || action == "helper-stopped" {
                    print("UI_QUIT_PROBE_WAITING_FOR_HELPER")
                    fflush(stdout)
                    return
                }
                fflush(stdout)
                if action == "quit" { quitApplication(); return }
                if action == "main-menu-quit" {
                    guard NSApp.sendAction(Selector(("quitApplicationFromMainMenu:")), to: self, from: nil) else {
                        throw CocoaError(.featureUnsupported)
                    }
                    return
                }
                if action == "terminate" { NSApp.terminate(nil); return }
                if action == "relaunch-interface" { prepareForInterfaceExit(); NSApp.terminate(nil); return }
                if action == "escalate" { probeWindow.performClose(nil); quitApplication(); return }
                // A real close button arrives from AppKit's event loop, outside
                // the currently executing Swift concurrency job.
                if ProcessInfo.processInfo.environment["WAIFUX_UI_EXIT_PROBE_CLOSE_FROM_TASK"] == "1" {
                    probeWindow.performClose(nil)
                } else {
                    DispatchQueue.main.async { probeWindow.performClose(nil) }
                }
            } catch {
                fputs("UI_EXIT_PROBE_FAILED \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            fputs("UI_EXIT_PROBE_FAILED AppKit termination timed out\n", stderr)
            exit(3)
        }
    }

    private func runClientLifecycleProbe(_ scenario: String, window: NSWindow) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard BackgroundRuntimeRole.isIsolatedTest,
              let root = environment["WAIFUX_HELPER_TEST_ROOT"],
              let value = environment["WAIFUX_UI_EXIT_PROBE_VALUE"] else { throw CocoaError(.featureUnsupported) }
        let directory = URL(fileURLWithPath: root)
        func waitForFile(_ name: String) async throws {
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func installQuitRequest() {
            Task {
                try await waitForFile("client.quit.request")
                quitApplication()
            }
        }
        if scenario == "startup-quit" {
            WaifuXPreferences.shared.set(value, forKey: "regression_client_latest")
            let startup = Task { try await BackgroundAgentClient.shared.startIsolatedUIExitProbe() }
            try await waitForFile("startup.identified.reached")
            let mutation = try BackgroundPropertyList.encode(["key": "regression_client_queued", "value": value,
                "removed": false, "writerID": UUID().uuidString, "sequence": 1])
            BackgroundAgentClient.shared.send("preferences.set", ["mutation": mutation])
            installQuitRequest()
            try Data().write(to: directory.appendingPathComponent("client.ready"))
            try await startup.value
            return
        }
        if scenario == "acknowledged-stop-quit" {
            try await BackgroundAgentClient.shared.startIsolatedUIExitProbe()
            WaifuXPreferences.shared.set(value, forKey: "regression_client_latest")
            BackgroundAgentClient.shared.beginApplicationQuit()
            try await BackgroundAgentClient.shared.drainForUIExit()
            try await BackgroundAgentClient.shared.stopForApplicationQuit()
            print("UI_CLIENT_STOP_ACKNOWLEDGED helperExited=true")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }

        guard scenario == "reconnect-replay" || scenario == "reconnect-quit" else { throw CocoaError(.featureUnsupported) }
        try await BackgroundAgentClient.shared.startIsolatedUIExitProbe()
        WaifuXPreferences.shared.set(value + ".old", forKey: "regression_client_latest")
        _ = try await BackgroundAgentClient.shared.request("test.preference", ["key": "regression_client_latest"])
        try BackgroundAgentClient.shared.interruptIsolatedConnectionForProbe()
        WaifuXPreferences.shared.set(value, forKey: "regression_client_latest")
        try await waitForFile("reconnect.identified.reached")
        if scenario == "reconnect-quit" { installQuitRequest() }
        try Data().write(to: directory.appendingPathComponent("client.ready"))
        while !BackgroundAgentClient.shared.isConnected { try await Task.sleep(for: .milliseconds(20)) }
        guard scenario == "reconnect-replay" else { return }
        let saved = try await BackgroundAgentClient.shared.request("test.preference", ["key": "regression_client_latest"])
        guard saved["value"] as? String == value, try WaifuXPreferences.shared.pendingMutationData().isEmpty else {
            throw CocoaError(.coderInvalidValue)
        }
        try BackgroundAgentClient.shared.deliverObsoleteCallbacksForProbe()
        try await Task.sleep(for: .milliseconds(200))
        guard BackgroundAgentClient.shared.isConnected else { throw CocoaError(.xpcConnectionInvalid) }
        print("UI_CLIENT_REPLAY_PASSED latestValue=true acknowledged=true obsoleteCallbacksIgnored=true")
        fflush(stdout)
        window.performClose(nil)
    }

    override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = super.applicationShouldTerminate(sender)
        if reply == .terminateCancel { deferredExitObserved = true }
        return reply
    }

    override func applicationWillTerminate(_ notification: Notification) {
        super.applicationWillTerminate(notification)
        guard deferredExitObserved, !BackgroundAgentClient.shared.isConnected else { exit(4) }
        print("UI_APPKIT_EXIT_PROBE_PASSED deferredExit=true disconnected=true")
        fflush(stdout)
    }

    override func applicationQuitDidFail(interfaceOnly: Bool) {
        guard ProcessInfo.processInfo.environment["WAIFUX_UI_QUIT_PROBE_RETRY"] == "1" else {
            fputs("UI_QUIT_PROBE_FAILED unexpected quit failure\n", stderr)
            exit(5)
        }
        print("UI_QUIT_FAILURE_RETAINS_UI helperStillPaused=true")
        fflush(stdout)
        do {
            try BackgroundAgentClient.shared.resumeIsolatedHelperAfterQuitProbe()
            quitApplication()
        } catch { exit(6) }
    }
}
#endif

// MARK: - NSWindowDelegate
extension AppDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 设置窗口：有待应用的模块改动时弹三选项确认（立即重启/稍后/放弃更改）
        if sender === settingsWindowController?.window {
            return handleSettingsWindowClose(sender)
        }
        FolderLockService.shared.lockAllFolders()
        if sender === window,
           let settingsWindow = settingsWindowController?.window,
           settingsWindow.isVisible || settingsWindow.isMiniaturized {
            // Closing the library must not tear down an independent settings UI.
            hideMainWindow()
            return false
        }
        exitInterface()
        return true
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let minimizedWindow = notification.object as? NSWindow else { return }
        MainWindowVisibility.shared.refresh()
        if minimizedWindow === window {
            AppResponsivenessMonitor.noteWindowVisible(false)
            AppResponsivenessMonitor.noteScenePhase("mainWindowMiniaturized")
        }
        enterBackgroundModeIfNoForegroundInterface(hideDockIcon: false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let restoredWindow = notification.object as? NSWindow,
              restoredWindow === window else {
            return
        }
        MainWindowVisibility.shared.refresh()
        AppResponsivenessMonitor.noteWindowVisible(true)
        AppResponsivenessMonitor.noteScenePhase("mainWindowDeminiaturized")
    }

    func windowWillClose(_ notification: Notification) {
        // Wait until AppKit has removed the closed window from visibility/key-window state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enterBackgroundModeIfNoForegroundInterface(hideDockIcon: self.window?.isMiniaturized != true)
            if self.settingsWindowController == nil,
               self.window?.isVisible != true, self.window?.isMiniaturized != true {
                self.exitInterface()
            }
        }
    }

    /// 处理设置窗口关闭：若有待应用的模块开关改动，弹三选项确认。
    /// - 立即重启 → AppRelauncher.relaunch()
    /// - 稍后 → 允许关闭，保留 UserDefaults 改动（下次启动生效）
    /// - 放弃更改 → 回滚三标志到启动快照值后关闭
    @MainActor
    private func handleSettingsWindowClose(_ window: NSWindow) -> Bool {
        settingsWindowController = nil
        return true
    }
}

// MARK: - 窗口状态检测
extension AppDelegate {
    /// 检查是否有保存的窗口状态
    private func hasSavedWindowFrame() -> Bool {
        return Self.savedWindowFrame() != nil
    }

    /// 获取保存的窗口大小（如果有）
    private static func savedWindowFrame() -> NSSize? {
        let key = "NSWindow Frame \(WindowAutosaveName.mainWindow)"
        // AppKit owns NSWindow's autosave in the UI's standard defaults domain.
        // The shared Helper domain contains only the one-time migrated value.
        guard let frameString = UserDefaults.standard.string(forKey: key) else {
            return nil
        }
        // macOS 保存格式: "x y width height"
        let components = frameString.split(separator: " ")
        guard components.count >= 4,
              let width = Double(components[2]),
              let height = Double(components[3]) else {
            return nil
        }
        return NSSize(width: width, height: height)
    }
}

// MARK: - 布局异常处理代理

/// 记录 macOS 窗口布局循环异常（_postWindowNeedsLayout）。
/// 当 NSHostingView 和 NSCollectionView 混合布局时，窗口的 _layoutViewTree
/// 可能触发 _postWindowNeedsLayout 导致 NSGenericException 崩溃。
/// 注意：NSExceptionHandler 只能观察和记录，无法真正抑制异常传播。
/// 异常仍会被重新抛出并导致崩溃。真正的修复需确保 UI 操作在主线程执行。
/// NSExceptionHandlerDelegate 是 NSObject 的 category（非正式协议），
/// 直接在 NSObject 子类上实现方法即可，无需协议声明。
private final class LayoutExceptionHandlerDelegate: NSObject, @unchecked Sendable {
    static let shared = LayoutExceptionHandlerDelegate()

    /// 记录布局循环异常
    @objc override func exceptionHandler(
        _ sender: NSExceptionHandler,
        shouldHandle exception: NSException,
        mask: Int
    ) -> Bool {
        if exception.name.rawValue == "NSGenericException",
           let reason = exception.reason,
           reason.contains("Layout Window") {
            AppLogger.error(.general, "窗口布局循环异常: \(reason)")
        }
        return true
    }

    /// 控制布局循环异常的日志记录
    @objc override func exceptionHandler(
        _ sender: NSExceptionHandler,
        shouldLogException exception: NSException,
        mask: Int
    ) -> Bool {
        if exception.name.rawValue == "NSGenericException",
           let reason = exception.reason,
           reason.contains("Layout Window") {
            return false
        }
        return true
    }
}

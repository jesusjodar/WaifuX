import SwiftUI
import AppKit
import Kingfisher

/// macOS 15+ 的 Liquid Glass 改变了标题栏 safe area 行为，
/// NSHostingController 会报告标题栏高度作为 top safe area，
/// 但我们的 UI 已经通过 fullSizeContentView 自行处理布局。
/// 使用 SwiftUI 的 .ignoresSafeArea() 在视图层面解决。
private struct EdgeToEdgeContainer<Content: View>: View {
    let content: Content

    var body: some View {
        if #available(macOS 15.0, *) {
            content.ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
    }
}

@MainActor
private final class MainContentNavigationState: ObservableObject {
    @Published var selectedTab: MainTab = .home {
        didSet {
            if oldValue != selectedTab {
                AppLogger.error(.general, "[AnimTracker] tab -> \(selectedTab)")
            }
        }
    }
    @Published var isHomeChromeHidden = false
    @Published var isShowingDetail = false
    @Published var selectedWallpaper: Wallpaper?
    @Published var librarySelectedWallpaper: Wallpaper?
    @Published var libraryWallpaperContext: [Wallpaper] = []
    /// Click-time visual context, consumed once by openDetail; never published per scroll frame.
    var pendingCardSource: CardTransitionSource?
    var pendingCardSourceTab: MainTab?

    func prepareCardSource(_ source: CardTransitionSource?, from tab: MainTab) {
        guard selectedTab == tab else { return }
        pendingCardSource = source
        pendingCardSourceTab = source == nil ? nil : tab
    }

    private var mouseMovementMonitor: Any?
    private var mouseRevealOrigin: NSPoint?
    /// 鼠标移动节流时间戳。声明为非隔离：事件线程上的闸门要在进入 `@MainActor` 之前读它。
    private nonisolated(unsafe) static var lastMouseMoveDispatch: CFAbsoluteTime = 0

    func binding<Value>(for keyPath: ReferenceWritableKeyPath<MainContentNavigationState, Value>) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0 }
        )
    }

    func resetForMemoryRelease() {
        isHomeChromeHidden = false
        isShowingDetail = false
        mouseRevealOrigin = nil
        selectedWallpaper = nil
        librarySelectedWallpaper = nil
        libraryWallpaperContext.removeAll()
        pendingCardSource = nil
        pendingCardSourceTab = nil
        selectedTab = .home
    }

    func startMouseMovementMonitoring() {
        guard mouseMovementMonitor == nil else { return }
        mouseMovementMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            // `.mouseMoved` 按指针刷新率触发（60–120Hz），原实现每个事件都起一个
            // `Task { @MainActor }`。这里在进入 actor 之前先做 50ms 节流：普通移动
            // 期间最多 20 次/秒，指针静止时直接不产生 Task。
            // 用非隔离的单调时间戳做闸门，不碰任何 @MainActor 状态，避免在事件线程上
            // 读隔离属性（那才是必须起 Task 的原因）。
            let now = CFAbsoluteTimeGetCurrent()
            guard now - Self.lastMouseMoveDispatch >= 0.05 else { return event }
            Self.lastMouseMoveDispatch = now

            let location = event.locationInWindow
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isHomeChromeHidden else {
                    self.mouseRevealOrigin = nil
                    return
                }
                guard let origin = self.mouseRevealOrigin else {
                    self.mouseRevealOrigin = location
                    return
                }
                let dx = location.x - origin.x
                let dy = location.y - origin.y
                guard (dx * dx + dy * dy) >= 576 else { return }
                self.isHomeChromeHidden = false
                self.mouseRevealOrigin = nil
            }
            return event
        }
    }

    func stopMouseMovementMonitoring() {
        guard let mouseMovementMonitor else { return }
        NSEvent.removeMonitor(mouseMovementMonitor)
        self.mouseMovementMonitor = nil
    }
}

private struct MainTabContainerView: NSViewControllerRepresentable {
    @ObservedObject var navigationState: MainContentNavigationState
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    func makeNSViewController(context: Context) -> MainTabViewController {
        let controller = MainTabViewController()
        controller.configure(
            navigationState: navigationState,
            wallpaperViewModel: wallpaperViewModel
        )
        return controller
    }

    func updateNSViewController(_ controller: MainTabViewController, context: Context) {
        controller.select(tab: navigationState.selectedTab)
    }
}

private enum MainDetailRoute: Hashable {
    case wallpaper(Wallpaper, context: [Wallpaper]?)

    var transitionItemID: String? {
        switch self {
        case .wallpaper(let item, _): item.id
        }
    }
}

@MainActor
private final class MainTabViewController: NSTabViewController {
    private var isConfigured = false
    /// 实际添加的 tab 顺序（仅含启动快照启用的 tab），用于 select(tab:) 查找真实 index。
    /// 在 configure 一次性构建（快照不变），禁用的 tab 不加入，避免位置 Int 错位。
    private var addedTabs: [MainTab] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .unspecified
        tabView.tabViewType = .noTabsNoBorder
    }

    func configure(
        navigationState: MainContentNavigationState,
        wallpaperViewModel: WallpaperViewModel
    ) {
        guard !isConfigured else {
            select(tab: navigationState.selectedTab)
            return
        }

        // Build the three static wallpaper pages once and retain their navigation state.
        for tab in MainTab.allCases {
            switch tab {
            case .home:
                addPage(title: tab.title, view: HomeTabPage(
                    navigationState: navigationState,
                    wallpaperViewModel: wallpaperViewModel
                ))
            case .wallpaperExplore:
                addPage(title: tab.title, view: WallpaperExploreTabPage(
                    navigationState: navigationState,
                    wallpaperViewModel: wallpaperViewModel
                ))
            case .myMedia:
                addPage(title: tab.title, view: MyLibraryTabPage(
                    navigationState: navigationState,
                    wallpaperViewModel: wallpaperViewModel
                ))
            }
            addedTabs.append(tab)
        }

        isConfigured = true
        select(tab: navigationState.selectedTab)
    }

    func select(tab: MainTab) {
        // 用 addedTabs 的真实位置查找，不依赖固定 controllerIndex（禁用 tab 后会错位）。
        guard let targetIndex = addedTabs.firstIndex(of: tab) else {
            // tab 被禁用（不在 addedTabs 中），回退到 home
            if let homeIndex = addedTabs.firstIndex(of: .home) {
                if selectedTabViewItemIndex != homeIndex {
                    selectedTabViewItemIndex = homeIndex
                }
            }
            return
        }
        guard selectedTabViewItemIndex != targetIndex else { return }
        selectedTabViewItemIndex = targetIndex
    }

    private func addPage<Content: View>(title: String, view: Content) {
        let hostingController = NSHostingController(rootView: EdgeToEdgeContainer(content: view))
        let item = NSTabViewItem(viewController: hostingController)
        item.label = title
        addTabViewItem(item)
    }
}

private struct HomeTabPage: View {
    @ObservedObject var navigationState: MainContentNavigationState
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    var body: some View {
        HomeContentView(
            viewModel: wallpaperViewModel,
            selectedWallpaper: navigationState.binding(for: \.selectedWallpaper),
            isHomeChromeHidden: navigationState.binding(for: \.isHomeChromeHidden),
            onOpenWallpapers: { navigationState.selectedTab = .wallpaperExplore },
            isTabActive: navigationState.selectedTab == .home && !navigationState.isShowingDetail
        )
    }
}

private struct WallpaperExploreTabPage: View {
    @ObservedObject var navigationState: MainContentNavigationState
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    var body: some View {
        WallpaperExploreContentView(
            viewModel: wallpaperViewModel,
            selectedWallpaper: navigationState.binding(for: \.selectedWallpaper),
            isVisible: navigationState.selectedTab == .wallpaperExplore && !navigationState.isShowingDetail,
            onPrepareCardTransition: { navigationState.prepareCardSource($0, from: .wallpaperExplore) }
        )
    }
}

private struct MyLibraryTabPage: View {
    @ObservedObject var navigationState: MainContentNavigationState
    // 库页不订阅完整 ViewModel：探索页 isLoading/searchQuery 等不应刷库 body。
    // 列表刷新由 MyLibraryContentView 内 libraryContentRevision onReceive 驱动。
    let wallpaperViewModel: WallpaperViewModel

    var body: some View {
        MyLibraryContentView(
            viewModel: wallpaperViewModel,
            selectedWallpaper: navigationState.binding(for: \.librarySelectedWallpaper),
            wallpaperContext: navigationState.binding(for: \.libraryWallpaperContext),
            isVisible: navigationState.selectedTab == .myMedia && !navigationState.isShowingDetail,
            onPrepareCardTransition: { navigationState.prepareCardSource($0, from: .myMedia) }
        )
    }
}

struct ContentView: View {
    // 全局 ViewModel：由 AppDelegate 持有，通过 init 参数注入；
    // 用普通 let 持有而非 @StateObject —— ContentView 本身不响应这 3 个 ViewModel 的
    // @Published 变化（body 内只命令式调用其方法，不读响应式属性），从而不会因
    // 例如下载库记录变更时 WallpaperViewModel 的多次 @Published 更新
    // 而连锁触发整个 ContentView body 及下游 tab 子视图的反复重算。
    // 子视图（5 个 TabPage）继续以 @ObservedObject 接收这些 ViewModel —— 该响应链是必要的。
    let viewModel: WallpaperViewModel

    @StateObject private var navigationState = MainContentNavigationState()
    @StateObject private var guessYouLikeVM = GuessYouLikeViewModel()
    @StateObject private var cardMorph = WallpaperCardMorphCoordinator()
    @State private var activeCardSourceTab: MainTab?
    @ObservedObject private var localization = LocalizationService.shared
    @State private var detailPath: [MainDetailRoute] = []
    @State private var detailNavigation = PageNavigationMotion()
    /// 非动画重置也变更页面标识，以取消尚未结束的过渡，而不是再播放一次返回。
    @State private var detailPageRevision: UInt = 0
    /// 状态栏可在已有详情页上请求另一个详情；重建栈以避免 SwiftUI 复用旧 destination。
    @State private var detailNavigationStackID = UUID()
    @State private var pendingCurrentWallpaperRoute: MainDetailRoute?
    @State private var detailBackSwipeRegistration: UUID?

    init(
        wallpaperViewModel: WallpaperViewModel
    ) {
        self.viewModel = wallpaperViewModel
    }

    var body: some View {
        // 性能测量：开启 PERF_TRACE 编译标记后，会在控制台打印触发本 body 的属性来源
        #if PERF_TRACE
        let _ = Self._printChanges()
        #endif
        ZStack {
            detailNavigationContent
            WallpaperCardMorphOverlay(coordinator: cardMorph)

            // 全局提示与弹窗不跟随页面位移。
            globalOverlayLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            AppResponsivenessMonitor.noteTabChange(navigationState.selectedTab.title)
            AppResponsivenessMonitor.noteDetailDepth(detailPath.count)
            AppResponsivenessMonitor.noteScenePhase("contentViewVisible")
            registerDetailBackSwipeHandler()
            navigationState.startMouseMovementMonitoring()
            consumePendingWallpaperDetailRequest()
        }
        .onDisappear {
            unregisterDetailBackSwipeHandler()
            navigationState.stopMouseMovementMonitoring()
            cardMorph.cancelAll()
            activeCardSourceTab = nil
            navigationState.pendingCardSource = nil
            navigationState.pendingCardSourceTab = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDidHideWindow)) { _ in
            cardMorph.cancelAll()
            activeCardSourceTab = nil
            navigationState.pendingCardSource = nil
            navigationState.pendingCardSourceTab = nil
        }
        .onChange(of: navigationState.selectedTab) { _, tab in
            AppResponsivenessMonitor.noteTabChange(tab.title)
            navigationState.isHomeChromeHidden = false
            cardSourceTabDidChange(to: tab)
        }
        .onChange(of: detailPath.count) { _, depth in
            AppResponsivenessMonitor.noteDetailDepth(depth)
            // 详情页功能导览（WaifuX GuideKit）
            if depth > 0 {
                GuideEngine.shared.noteDetailOpened()
            }
        }
        // 必须位于详情页 NavigationStack 的外层，已有详情页显示时也要能收到替换请求。
        .onReceive(NotificationCenter.default.publisher(for: .openCurrentWallpaperDetail)) { _ in
            consumePendingWallpaperDetailRequest()
        }
        .onChange(of: navigationState.selectedWallpaper) { _, wallpaper in
            guard let wallpaper else { return }
            openDetail(.wallpaper(wallpaper, context: nil))
        }


        .onChange(of: navigationState.librarySelectedWallpaper) { _, wallpaper in
            guard let wallpaper else { return }
            let context = navigationState.libraryWallpaperContext.isEmpty ? nil : navigationState.libraryWallpaperContext
            openDetail(.wallpaper(wallpaper, context: context))
        }


        .task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await viewModel.initialLoad()
            guessYouLikeVM.preload()
        }
        .ignoresSafeArea()
        .applyTheme()
    }

    /// 从长 body 修饰符链中拆出，避免新增导航泛型增加 SwiftUI 类型检查负担。
    private var detailNavigationContent: some View {
        PageNavigationTransition(
            pageID: String(detailPageRevision),
            navigation: detailNavigation,
            isVisible: true,
            allowsSnapshot: detailPath.isEmpty
        ) {
            ZStack {
                // Retain the live list under the aperture while the native detail prepares.
                mainContent
                    .opacity(detailPath.isEmpty || cardMorph.isTransitioning ? 1 : 0)
                    .allowsHitTesting(detailPath.isEmpty)
                    .accessibilityHidden(!detailPath.isEmpty)
                NavigationStack(path: detailPathBinding) {
                    Color.clear
                        .navigationDestination(for: MainDetailRoute.self) { route in
                            detailDestination(for: route)
                        }
                }
                .id(detailNavigationStackID)
                .opacity(detailPath.isEmpty ? 0 : 1)
                .allowsHitTesting(!detailPath.isEmpty)
                .accessibilityHidden(detailPath.isEmpty)
                .modifier(CardMorphDestinationReveal(coordinator: cardMorph))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 独立 NSHostingView 会重新计算标题栏安全区；外层忽略设置不会跨根视图传入。
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Color(hex: "0D0D0D"))
    }

    private var globalOverlayLayer: some View {
        ZStack {
            // 下载进度与来源切换提示必须挂在 NavigationStack 外，保证详情页里也可见。
            VStack {
                Spacer()
                DownloadProgressToastHost(
                    onDismiss: { snapshot in
                        handleDownloadToastDismiss(snapshot)
                    },
                    onCancel: { snapshot in
                        handleDownloadToastCancel(snapshot)
                    },
                    onRemove: { snapshot in
                        handleDownloadToastRemove(snapshot)
                    },
                    onRetry: { snapshot in
                        handleDownloadToastRetry(snapshot)
                    }
                )
                BackgroundDownloadProgressToastHost(
                    onExpand: { DownloadTaskService.shared.restoreAllRunningToasts() }
                )
            }
            .zIndex(400)

            // 显示器选择弹窗覆盖层
            DisplaySelectorOverlay()
                .zIndex(700)

            // 猜你喜欢覆盖层
            if guessYouLikeVM.isShowing {
                GuessYouLikeOverlay(
                    viewModel: guessYouLikeVM,
                    onDetail: { [self] item in
                        handleGuessYouLikeDetail(item)
                    },
                    onDownload: { [self] item in
                        handleGuessYouLikeDownload(item)
                    }
                )
                .zIndex(800)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }

    private var mainContent: some View {
        mainContentBase
            .environment(\.mainTopBarContentPadding, MainTopBarLayout.legacyContentTopPadding)
            .overlay(alignment: .top) {
                topNavigationBar
                    .animation(.easeOut(duration: 0.18), value: navigationState.isHomeChromeHidden)
            }
    }

    private var mainContentBase: some View {
        ZStack {
            Color(hex: "0D0D0D")
                .ignoresSafeArea()

            MainTabContainerView(
                navigationState: navigationState,
                wallpaperViewModel: viewModel
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: .appShouldReleaseForegroundMemory)) { _ in
                releaseForegroundMemory()
            }
            .onAppear {
                consumePendingLibraryTabRequest()
                // 首启/版本更新后的功能导览自动播放（WaifuX GuideKit）
                GuideEngine.shared.noteTabActivated(navigationState.selectedTab, isInitial: true)
            }
            .onChange(of: navigationState.selectedTab) { _, tab in
                GuideEngine.shared.noteTabActivated(tab)
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToLibraryTab)) { _ in
                MainNavigationRequestStore.clearLibraryTabRequest()
                navigationState.selectedTab = .myMedia
            }
            .id(localization.currentLanguage)
            .environment(\.locale, Locale(identifier: localization.currentLanguage.rawValue))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationBarBackButtonHidden(true)
        .toolbar(navigationState.selectedTab == .myMedia ? .visible : .hidden, for: .automatic)
    }

    private var topNavigationBar: some View {
        TopNavigationBar(
            selectedTab: navigationState.binding(for: \.selectedTab),
            isChromeHidden: navigationState.selectedTab == .home && navigationState.isHomeChromeHidden,
            onOpenSettings: { openSettingsWindow() },
            onGuessYouLike: { guessYouLikeVM.show() },
            onClose: { hideMainWindow() },
            onMinimize: { minimizeWindow() },
            onMaximize: { maximizeWindow() },
            onZoom: { zoomWindow() }
        )
        .zIndex(100)
    }

    private func minimizeWindow() {
        NSApp.mainWindow?.miniaturize(nil)
    }

    private func maximizeWindow() {
        guard let window = NSApp.mainWindow else { return }
        window.toggleFullScreen(nil)
    }

    private func consumePendingLibraryTabRequest() {
        guard MainNavigationRequestStore.consumeLibraryTabRequest() else {
            return
        }
        navigationState.selectedTab = .myMedia
    }

    private func consumePendingWallpaperDetailRequest() {
        guard let request = MainNavigationRequestStore.consumeWallpaperDetailRequest() else { return }
        navigationState.selectedTab = .myMedia
        switch request {
        case .wallpaper(let wallpaper):
            replaceDetailWithCurrentWallpaper(.wallpaper(wallpaper, context: [wallpaper]))
        }
    }

    /// 先完整关闭当前详情页，再在下一轮主线程事件重建并打开目标详情。
    private func replaceDetailWithCurrentWallpaper(_ route: MainDetailRoute) {
        cardMorph.cancelAll()
        activeCardSourceTab = nil
        navigationState.pendingCardSource = nil
        navigationState.pendingCardSourceTab = nil
        pendingCurrentWallpaperRoute = route
        updateDetailPath([], animated: false)
        clearSelectedDetailBindings()
        detailNavigationStackID = UUID()
        Task { @MainActor in
            await Task.yield()
            guard pendingCurrentWallpaperRoute == route else { return }
            pendingCurrentWallpaperRoute = nil
            openDetail(route, animated: false)
        }
    }

    @ViewBuilder
    private func detailDestination(for route: MainDetailRoute) -> some View {
        switch route {
        case .wallpaper(let wallpaper, let context):
            WallpaperDetailSheet(
                wallpaper: wallpaper,
                viewModel: viewModel,
                contextWallpapers: context,
                onClose: popDetail,
                onNavigateToWallpaper: { selected in
                    cardMorph.cancelAll()
                    updateDetailPath(detailPath + [.wallpaper(selected, context: context)])
                },
                transitionImage: cardMorph.seedImage(for: wallpaper.id),
                onTransitionReady: { cardMorph.detailDidAppear(itemID: wallpaper.id) },
                onTransitionImageReady: { id, image in cardMorph.detailImageReady(itemID: id, image: image) },
                onDisplayedWallpaperChange: { cardMorph.detailChangedItem(to: $0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .automatic)

        }
    }

    /// Native dismiss and the custom back button share the same transition.
    private var detailPathBinding: Binding<[MainDetailRoute]> {
        Binding(
            get: { detailPath },
            set: { newPath in
                requestDetailPath(newPath)
            }
        )
    }

    private func updateDetailPath(_ newPath: [MainDetailRoute], animated: Bool = true) {
        guard detailPath != newPath else {
            if !animated {
                detailNavigation.suppressAnimation()
                detailPageRevision &+= 1
            }
            return
        }
        let direction: PageNavigationMotion.Direction = newPath.count < detailPath.count ? .backward : .forward
        // The native stack retains destinations/history; only the outer container animates.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if animated {
                detailNavigation.move(direction)
            } else {
                detailNavigation.suppressAnimation()
            }
            detailPageRevision &+= 1
            navigationState.isShowingDetail = !newPath.isEmpty
            detailPath = newPath
        }
    }

    private func cardSourceTabDidChange(to tab: MainTab) {
        // onChange may run after a click on the new page; only retire the old page's request.
        if activeCardSourceTab != tab {
            cardMorph.cancelAll()
            activeCardSourceTab = nil
        }
        if navigationState.pendingCardSourceTab != tab {
            navigationState.pendingCardSource = nil
            navigationState.pendingCardSourceTab = nil
        }
    }

    private func openDetail(_ route: MainDetailRoute, animated: Bool = true) {
        let source = navigationState.pendingCardSourceTab == navigationState.selectedTab
            ? navigationState.pendingCardSource : nil
        navigationState.pendingCardSource = nil
        navigationState.pendingCardSourceTab = nil
        cardMorph.cancelAll()
        activeCardSourceTab = navigationState.selectedTab
        clearTriggerBinding(for: route)
        if animated, detailPath.isEmpty, let source, source.itemID == route.transitionItemID,
           cardMorph.present(source, imageLayout: transitionImageLayout(for: route), prepareImage: { size, scale in
               guard let url = self.transitionImageURL(for: route) else { return nil }
               return await WallpaperTransitionImageLoader.load(url: url, viewportSize: size, displayScale: scale)
           }, open: { self.updateDetailPath([route], animated: false) }) {
            return
        }
        updateDetailPath([route], animated: animated)
    }

    private func transitionImageURL(for route: MainDetailRoute) -> URL? {
        switch route {
        case .wallpaper(let wallpaper, _):
            viewModel.localFileURLIfAvailable(for: wallpaper) ?? wallpaper.fullImageURL ?? wallpaper.thumbURL
        }
    }

    private func transitionImageLayout(for route: MainDetailRoute) -> CardMorphImageLayout {
        switch route {
        case .wallpaper(let wallpaper, _):
            wallpaper.dimensionY > wallpaper.dimensionX && wallpaper.dimensionX > 0 ? .portrait : .fill
        }
    }

    private func clearTriggerBinding(for route: MainDetailRoute) {
        navigationState.selectedWallpaper = nil
        navigationState.librarySelectedWallpaper = nil
    }

    private func requestDetailPath(_ newPath: [MainDetailRoute]) {
        guard newPath != detailPath else { return }
        if newPath.isEmpty, detailPath.count == 1,
           let itemID = detailPath[0].transitionItemID,
           cardMorph.close(itemID: itemID, pop: {
               self.updateDetailPath([], animated: false)
               self.clearSelectedDetailBindings()
           }) {
            return
        }
        cardMorph.cancelAll()
        updateDetailPath(newPath)
        if newPath.isEmpty { clearSelectedDetailBindings() }
    }

    private func popDetail() {
        if cardMorph.cancelOpening() { return }
        guard !detailPath.isEmpty else { return }
        requestDetailPath(Array(detailPath.dropLast()))
    }

    /// The wallpaper detail stack shares the native back gesture.
    private func registerDetailBackSwipeHandler() {
        guard detailBackSwipeRegistration == nil else { return }
        detailBackSwipeRegistration = TrackpadBackSwipeRouter.shared.register(
            priority: 100,
            isEnabled: { !self.detailPath.isEmpty || self.cardMorph.isOpening },
            action: { self.popDetail() }
        )
    }

    private func unregisterDetailBackSwipeHandler() {
        guard let detailBackSwipeRegistration else { return }
        TrackpadBackSwipeRouter.shared.unregister(detailBackSwipeRegistration)
        self.detailBackSwipeRegistration = nil
    }

    // MARK: - 猜你喜欢回调

    /// 将 GuessYouLikeItem 映射到 Wallpaper（用于详情与下载）
    private func resolveWallpaper(from item: GuessYouLikeItem) -> Wallpaper {
        let imageURL = item.imageURL
        return Wallpaper(
            id: item.id,
            title: nil,
            url: item.destination,
            shortUrl: nil,
            views: 0,
            favorites: 0,
            downloads: nil,
            source: nil,
            purity: "sfw",
            category: "general",
            dimensionX: 0,
            dimensionY: 0,
            resolution: item.subtitle,
            ratio: "",
            fileSize: nil,
            fileType: nil,
            createdAt: nil,
            colors: [],
            path: imageURL,
            thumbs: Wallpaper.Thumbs(large: imageURL, original: imageURL, small: imageURL),
            tags: nil,
            uploader: nil
        )
    }

    private func handleGuessYouLikeDetail(_ item: GuessYouLikeItem) {
        guessYouLikeVM.dismiss()
        navigationState.selectedWallpaper = resolveWallpaper(from: item)
    }

    private func handleGuessYouLikeDownload(_ item: GuessYouLikeItem) {
        guessYouLikeVM.dismiss()
        let wallpaper = resolveWallpaper(from: item)
        Task {
            do { try await viewModel.downloadWallpaper(wallpaper) }
            catch { viewModel.errorMessage = error.localizedDescription }
        }
    }

    private func clearSelectedDetailBindings() {
        navigationState.selectedWallpaper = nil
        navigationState.librarySelectedWallpaper = nil
    }

    private func zoomWindow() {
        NSApp.mainWindow?.zoom(nil)
    }

    private func openSettingsWindow() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.showSettingsWindow(nil)
    }

    private func hideMainWindow() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.hideMainWindow()
    }

    private func releaseForegroundMemory() {
        cardMorph.cancelAll()
        activeCardSourceTab = nil
        navigationState.pendingCardSource = nil
        navigationState.pendingCardSourceTab = nil
        ForegroundPrefetchManager.shared.stopAll()
        viewModel.releaseForegroundMemory()
        updateDetailPath([], animated: false)
        navigationState.resetForMemoryRelease()
    }

    private func handleDownloadToastDismiss(_ snapshot: DownloadToastSnapshot) {
        DownloadTaskService.shared.suppressAllRunningToasts()
    }

    private func handleDownloadToastCancel(_ snapshot: DownloadToastSnapshot) {
        let service = DownloadTaskService.shared
        service.markToastSuppressed(for: snapshot.id)
        service.cancelTask(id: snapshot.id)
        service.removeTask(id: snapshot.id)
    }

    /// 失败/已取消/暂停态的「取消任务」：终止队列残留并把任务从列表里移除。
    private func handleDownloadToastRemove(_ snapshot: DownloadToastSnapshot) {
        let service = DownloadTaskService.shared
        service.cancelTask(id: snapshot.id)
        service.removeTask(id: snapshot.id)
    }

    private func handleDownloadToastRetry(_ snapshot: DownloadToastSnapshot) {
        let service = DownloadTaskService.shared
        service.clearToastSuppression(for: snapshot.id)
        guard let task = service.task(for: snapshot.id) else { return }
        Task {
            do { try await viewModel.retryDownload(task: task) }
            catch { viewModel.errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - MyMediaContentView 已移除（死代码，未被任何视图引用）

/// 跟踪用户是否正在滚动列表。弹窗在滚动期间跳过进度动画提交，
/// 避免动画帧与列表滚动渲染争抢主线程（滚动停止 idleInterval 后自动恢复）。
@MainActor
private final class ScrollActivityTracker: ObservableObject {
    @Published private(set) var isScrolling = false

    private var monitor: Any?
    private var idleWorkItem: DispatchWorkItem?
    private let idleInterval: TimeInterval = 0.25

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.noteScrollActivity()
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        idleWorkItem?.cancel()
        idleWorkItem = nil
        if isScrolling {
            isScrolling = false
        }
    }

    private func noteScrollActivity() {
        // 只在状态翻转时发布，避免每个滚轮事件都触发 objectWillChange
        if !isScrolling {
            isScrolling = true
        }
        idleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isScrolling else { return }
            self.isScrolling = false
        }
        idleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + idleInterval, execute: item)
    }
}

// MARK: - iOS 丝滑风格下载进度弹窗宿主
private struct DownloadProgressToastHost: View {
    @StateObject private var viewModel = DownloadToastViewModel()
    @StateObject private var scrollTracker = ScrollActivityTracker()
    let onDismiss: (DownloadToastSnapshot) -> Void
    let onCancel: (DownloadToastSnapshot) -> Void
    let onRemove: (DownloadToastSnapshot) -> Void
    let onRetry: (DownloadToastSnapshot) -> Void

    @State private var displayedSnapshot: DownloadToastSnapshot?
    @State private var hideWorkItem: DispatchWorkItem?
    @State private var hideGeneration = 0

    // iOS 丝滑动画状态
    @State private var toastOpacity: Double = 0
    @State private var toastScale: Double = 0.92
    @State private var toastOffset: CGFloat = 10

    /// 入场动画：轻快弹簧，类似系统通知弹出
    private var iOSShowAnimation: Animation {
        .spring(response: 0.35, dampingFraction: 0.82, blendDuration: 0)
    }

    /// 退场动画：快速利落
    private var iOSDismissAnimation: Animation {
        .easeOut(duration: 0.20)
    }

    var body: some View {
        Group {
            if let snapshot = displayedSnapshot {
                DownloadProgressToast(
                    snapshot: snapshot,
                    activeTaskCount: viewModel.activeTaskCount,
                    suppressProgressAnimation: scrollTracker.isScrolling,
                    onDismiss: {
                        dismiss(snapshot)
                    },
                    onCancel: {
                        cancel(snapshot)
                    },
                    onRemove: {
                        remove(snapshot)
                    },
                    onRetry: {
                        retry(snapshot)
                    }
                )
                .frame(maxWidth: 440)
                .padding(.bottom, 26)
                .opacity(toastOpacity)
                .scaleEffect(toastScale, anchor: .bottom)
                .offset(y: toastOffset)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    )
                )
            }
        }
        .onAppear {
            scrollTracker.start()
            reconcileDisplayedSnapshot(viewModel.snapshot)
        }
        .onDisappear {
            scrollTracker.stop()
        }
        .onChange(of: viewModel.snapshot) { _, snapshot in
            reconcileDisplayedSnapshot(snapshot)
        }
    }

    // MARK: - 动画控制

    /// 入场：底部轻弹 + 缩放
    private func performShow() {
        toastOpacity = 0
        toastScale = 0.92
        toastOffset = 8

        withAnimation(iOSShowAnimation) {
            toastOpacity = 1
            toastScale = 1.0
            toastOffset = 0
        }
    }

    /// 退场：向下缩小淡出（精简不卡顿）
    private func performHide(completion: @escaping () -> Void) {
        let generation = hideGeneration
        withAnimation(iOSDismissAnimation) {
            toastOpacity = 0
            toastScale = 0.96
            toastOffset = 6
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            guard generation == hideGeneration else { return }
            completion()
        }
    }

    private func reconcileDisplayedSnapshot(_ snapshot: DownloadToastSnapshot?) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        hideGeneration &+= 1

        guard let snapshot else {
            performHide {
                displayedSnapshot = nil
            }
            return
        }

        if viewModel.isSuppressed(taskID: snapshot.id) {
            displayedSnapshot = nil
            return
        }

        if snapshot.isRunning {
            // 同一下载队列中的任务交接只替换内容，不重置透明度；
            // 否则每完成一项都会先淡出再把下一项弹进来。
            let isToastVisible = displayedSnapshot != nil && toastOpacity > 0.01
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayedSnapshot = snapshot
            }
            if isToastVisible {
                // Interrupt a hide animation if the next task arrives while
                // the old toast is still fading out.
                withAnimation(iOSShowAnimation) {
                    toastOpacity = 1
                    toastScale = 1
                    toastOffset = 0
                }
            } else {
                performShow()
            }
            return
        }

        if snapshot.status == .completed {
            viewModel.clearSuppression(taskID: snapshot.id)
            if displayedSnapshot?.id != snapshot.id {
                displayedSnapshot = snapshot
                performShow()
            }

            let generation = hideGeneration
            let workItem = DispatchWorkItem { [self] in
                guard generation == hideGeneration else { return }
                performHide {
                    guard generation == hideGeneration,
                          displayedSnapshot?.id == snapshot.id else {
                        return
                    }
                    displayedSnapshot = nil
                }
            }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: workItem)
            return
        }

        if snapshot.isActionable {
            if displayedSnapshot?.id != snapshot.id {
                displayedSnapshot = snapshot
                performShow()
            } else {
                withAnimation(iOSShowAnimation) {
                    displayedSnapshot = snapshot
                }
            }
            return
        }

        performHide {
            displayedSnapshot = nil
        }
    }

    private func dismiss(_ snapshot: DownloadToastSnapshot) {
        onDismiss(snapshot)
        performHide {
            if displayedSnapshot?.id == snapshot.id {
                displayedSnapshot = nil
            }
        }
    }

    private func cancel(_ snapshot: DownloadToastSnapshot) {
        onCancel(snapshot)
        performHide {
            if displayedSnapshot?.id == snapshot.id {
                displayedSnapshot = nil
            }
        }
    }

    private func remove(_ snapshot: DownloadToastSnapshot) {
        onRemove(snapshot)
        performHide {
            if displayedSnapshot?.id == snapshot.id {
                displayedSnapshot = nil
            }
        }
    }

    private func retry(_ snapshot: DownloadToastSnapshot) {
        onRetry(snapshot)
        performHide {
            if displayedSnapshot?.id == snapshot.id {
                displayedSnapshot = nil
            }
        }
    }
}

// MARK: - Compact background download surface
private struct BackgroundDownloadProgressToastHost: View {
    @ObservedObject private var downloadService = DownloadTaskService.shared
    let onExpand: () -> Void

    private var backgroundTasks: [DownloadTask] {
        downloadService.runningTasks.filter { downloadService.isToastSuppressed(for: $0.id) }
    }

    var body: some View {
        Group {
            if let task = downloadService.compactOverlayTask {
                BackgroundTaskProgressToast(
                    title: String(format: t("download.backgroundProgress"), Int((task.progress * 100).rounded())),
                    detail: remainingDetail(backgroundTasks.count - 1),
                    progress: task.progress,
                    onTap: onExpand
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private func remainingDetail(_ count: Int) -> String? {
        count > 0 ? String(format: t("progress.remainingCount"), count) : nil
    }
}

private struct BackgroundTaskProgressToast: View {
    let title: String
    let detail: String?
    let progress: Double
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 92, height: 5)

                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.78))
                    .frame(width: 92 * min(1, max(0, progress)), height: 5)
            }

            if let detail {
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .liquidGlassSurface(.prominent, tint: Color.white.opacity(0.06), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { onTap?() }
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }
}

// MARK: - iOS 丝滑风格下载进度 Toast
private struct DownloadProgressToast: View {
    let snapshot: DownloadToastSnapshot
    let activeTaskCount: Int
    /// 列表滚动期间为 true：进度直接跳变，不启动新动画（避免与滚动渲染抢主线程）
    var suppressProgressAnimation: Bool = false
    let onDismiss: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    let onRetry: () -> Void

    @State private var animatedProgress: Double = 0

    private var tint: Color {
        switch snapshot.status {
        case .pending:
            return Color.white.opacity(0.7)
        case .downloading:
            return Color.white.opacity(0.85)
        case .paused:
            return Color.white.opacity(0.6)
        case .completed:
            return LiquidGlassColors.onlineGreen
        case .failed:
            return Color.white.opacity(0.7)
        case .cancelled:
            return Color.white.opacity(0.5)
        }
    }

    private var iconName: String {
        switch snapshot.kind {
        case .wallpaper:
            return "photo.fill"
        }
    }

    private var statusText: String {
        switch snapshot.status {
        case .pending:   return t("status.pending")
        case .downloading: return t("status.downloading")
        case .paused:     return t("status.paused")
        case .completed:   return t("status.completed")
        case .failed:      return t("status.failed")
        case .cancelled:   return t("status.cancelled")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if activeTaskCount > 1 && snapshot.isRunning {
            let base = snapshot.subtitle.isEmpty ? "\(activeTaskCount) \(t("items"))" : "\(snapshot.subtitle) · \(activeTaskCount) \(t("items"))"
            parts.append(base)
        } else {
            if !snapshot.subtitle.isEmpty { parts.append(snapshot.subtitle) }
            if !snapshot.badgeText.isEmpty { parts.append(snapshot.badgeText) }
        }
        return parts.isEmpty ? "" : parts.joined(separator: " · ")
    }

    private var isCompleted: Bool { snapshot.status == .completed }
    private var showsRetry: Bool {
        snapshot.status == .failed || snapshot.status == .cancelled || snapshot.status == .paused
    }
    private var showsCancel: Bool {
        snapshot.status == .pending
            || snapshot.status == .downloading
    }

    /// 进度条动画：临界阻尼 spring，约 0.3s 收敛。
    /// 原 interpolatingSpring(stiffness: 120, damping: 20) 欠阻尼长尾在 ~6.7fps
    /// 进度更新下几乎从不静止，弹窗会持续产生动画帧，滚动列表时叠加掉帧。
    private var progressAnimation: Animation {
        .spring(response: 0.3, dampingFraction: 1.0)
    }

    private enum ToastActionRole {
        case secondary
        case retry
        case destructive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                // 图标：完成时变绿色 + 微弹性
                Image(systemName: isCompleted ? "checkmark" : iconName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(
                        // 轻量半透明填充：玻璃卡片上的小元素不再叠加 material
                        // 采样层（原来每层都是实时 backdrop blur，滚动时逐帧重采样）
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .scaleEffect(isCompleted ? 1.08 : 1.0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                // 状态标签（统一样式，只变色）
                Text(statusText)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )

                // 右上角快捷操作：下载中=取消本次下载（含排队），
                // 其余状态（完成/失败/暂停/已取消）=关闭弹窗
                Button(action: snapshot.isRunning ? onCancel : onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(snapshot.isRunning ? t("取消下载") : t("captcha.close"))
            }

            // 进度区域
            if !isCompleted {
                // 进度条
                LiquidGlassLinearProgressBar(
                    progress: animatedProgress,
                    height: 6,
                    tintColor: tint,
                    trackOpacity: 0.15
                )

                HStack {
                    Text(t("wallpaper.downloads"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))

                    Spacer()

                    Text("\(Int((max(0, min(animatedProgress, 1)) * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                        // 去掉 contentTransition(.numericText())：每次进度更新都会
                        // 创建文本 morph 动画层，monospacedDigit 直接跳变视觉等效且更省
                }
            } else {
                // 完成行：简洁显示
                HStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LiquidGlassColors.onlineGreen)
                    Text(t("status.completed"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.onlineGreen)
                    Spacer()
                }
            }

            if showsCancel || showsRetry {
                HStack(spacing: 10) {
                    toastActionButton(
                        title: showsCancel ? t("后台继续") : t("captcha.close"),
                        icon: showsCancel ? "arrow.down.circle" : "xmark",
                        role: .secondary,
                        action: onDismiss
                    )

                    if showsCancel {
                        toastActionButton(
                            title: t("取消下载"),
                            icon: "xmark.circle.fill",
                            role: .destructive,
                            action: onCancel
                        )
                    } else {
                        // 失败/已取消/暂停态：除了重试，还要能直接取消并移除任务，
                        // 否则永远下载不了的资源只能反复「重新下载」或干等弹窗超时。
                        toastActionButton(
                            title: t("取消任务"),
                            icon: "xmark.circle.fill",
                            role: .destructive,
                            action: onRemove
                        )

                        toastActionButton(
                            title: t("library.redownload.item"),
                            icon: "arrow.clockwise",
                            role: .retry,
                            action: onRetry
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 440)
        .liquidGlassSurface(
            .prominent,
            tint: Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        // 精简动画：只用颜色过渡，避免复杂的 layout transition 导致卡顿
        .animation(.easeInOut(duration: 0.20), value: isCompleted)
        .onChange(of: snapshot.progress) { _, newProgress in
            if suppressProgressAnimation {
                // 滚动期间：禁用动画直接跳变，弹窗层不产生新的动画帧
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    animatedProgress = newProgress
                }
            } else {
                withAnimation(progressAnimation) {
                    animatedProgress = newProgress
                }
            }
        }
        .onAppear {
            animatedProgress = snapshot.progress
        }
    }

    @ViewBuilder
    private func toastActionButton(title: String, icon: String, role: ToastActionRole, action: @escaping () -> Void) -> some View {
        let fillColor: Color = {
            switch role {
            case .secondary:
                return Color.white.opacity(0.08)
            case .retry:
                return Color(red: 0.58, green: 0.82, blue: 0.72).opacity(0.96)
            case .destructive:
                return Color(red: 0.93, green: 0.42, blue: 0.42).opacity(0.94)
            }
        }()

        let foregroundColor: Color = {
            switch role {
            case .secondary:
                return Color.white.opacity(0.88)
            case .retry, .destructive:
                return Color.black.opacity(0.84)
            }
        }()

        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(fillColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .stroke(
                                role == .secondary ? Color.white.opacity(0.08) : Color.white.opacity(0.16),
                                lineWidth: 0.8
                            )
                    )
            )
            .shadow(
                color: role == .secondary ? .clear : fillColor.opacity(0.24),
                radius: 10,
                y: 4
            )
        }
        .buttonStyle(.plain)
    }
}

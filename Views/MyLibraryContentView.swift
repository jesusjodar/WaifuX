import SwiftUI
import Kingfisher
import AppKit

// MARK: - Scroll State
private final class LibraryScrollRuntimeState: ObservableObject {
    var currentOffset: CGFloat = 0
    /// 不发布到 SwiftUI，仅记录滚停时应从哪张可见卡继续预取。
    var lastWallpaperItemID: String?
}

// MARK: - Scroll 观察与恢复辅助组件
/// 直接观察底层 NSScrollView，避免滚动时通过 PreferenceKey 持续触发整棵 SwiftUI 内容重算。
private struct LibraryScrollObserver: NSViewRepresentable {
    let restoreOffset: CGFloat
    let restoreTrigger: Int
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        scheduleInstall(from: view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        scheduleInstall(from: nsView, context: context)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    private func scheduleInstall(from view: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.install(
                from: view,
                restoreOffset: restoreOffset,
                restoreTrigger: restoreTrigger
            )
        }
    }

    @MainActor
    final class Coordinator {
        var onScroll: (CGFloat) -> Void
        private weak var observedScrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var lastRestoreTrigger = -1

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        func install(from view: NSView, restoreOffset: CGFloat, restoreTrigger: Int) {
            guard let scrollView = findParentScrollView(from: view) else { return }

            if observedScrollView !== scrollView {
                stopObserving()
                observedScrollView = scrollView
                scrollView.contentView.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak self, weak scrollView] _ in
                    guard let scrollView else { return }
                    MainActor.assumeIsolated { self?.handleScroll(scrollView) }
                }
            }

            if restoreTrigger != lastRestoreTrigger {
                lastRestoreTrigger = restoreTrigger
                restore(scrollView: scrollView, targetOffset: restoreOffset)
            }

            handleScroll(scrollView)
        }

        func stopObserving() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            boundsObserver = nil
            observedScrollView = nil
        }

        private func handleScroll(_ scrollView: NSScrollView) {
            onScroll(max(0, scrollView.contentView.bounds.origin.y))
        }

        private func restore(scrollView: NSScrollView, targetOffset: CGFloat) {
            guard targetOffset > 0 else { return }
            let currentY = scrollView.contentView.bounds.origin.y
            if abs(currentY - targetOffset) > 1 {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        private func findParentScrollView(from view: NSView) -> NSScrollView? {
            var current = view.superview
            while let candidate = current {
                if let scrollView = candidate as? NSScrollView {
                    return scrollView
                }
                current = candidate.superview
            }
            return nil
        }
    }
}

struct MyLibraryContentView: View {
    // @Published（探索页 searchQuery/isLoading 等），任一变化都会刷整页库 body。
    // 库内容变更只听 libraryContentRevision（onReceive），数据用 viewModel.xxx 命令式读取。
    let viewModel: WallpaperViewModel
    // - 背景 → LibraryAtmosphereBackground 自行观察
    // - 当前壁纸标记 → activeWallpaperRevision 快照 + 卡片布尔
    // - 文件夹解锁 → folderUnlockRevision 快照
    // 命令式访问共享单例（不订阅 objectWillChange）
    private let folderStore = LibraryFolderStore.shared
    private let gridOrderStore = LibraryGridOrderStore.shared
    @Environment(\.mainTopBarContentPadding) private var mainTopBarContentPadding

    // 分类筛选
    @State private var selectedContentType: ContentType = .wallpaper
    @Binding var selectedWallpaper: Wallpaper?
    @Binding var wallpaperContext: [Wallpaper]
    let isVisible: Bool
    // 默认值必须为 var 才会保留在 Swift 自动生成的 memberwise init 参数中。
    var onPrepareCardTransition: ((CardTransitionSource?) -> Void)? = nil

    // 子标签：收藏 / 已下载
    @State private var selectedSubTab: SubTab = .downloads
    @State private var didRestoreLastLibraryPage = false
    @State private var librarySearchQuery = ""
    @State private var isLibrarySearchExpanded = false
    @FocusState private var isLibrarySearchFocused: Bool
    /// 搜索输入期间不要每个字符都同步重配 NSCollectionView。
    @State private var librarySearchDebounce: DispatchWorkItem?
    @State private var librarySearchTask: Task<Void, Never>?
    @State private var librarySearchGeneration: UInt64 = 0

    // 编辑状态
    @State private var isEditing = false
    @State private var selectedItems = Set<String>()
    /// 本页拖拽排序预期写入的 gridOrderStore revision；-1 表示没有待认领的本地写入。
    @State private var expectedLocalGridOrderRevision = -1

    // MARK: - AppKit 网格状态（2026-09 迁移：NSCollectionView 自滚动 + cell 真复用）
    /// 收藏/排序/选择/当前壁纸标记等「数量不变但内容变化」时递增，强制重配可见 cell。
    @State private var gridReloadToken: Int = 0
    /// 切子标签/内容类型/进出文件夹时递增，滚回网格顶部。
    @State private var gridScrollToTopToken: Int = 0
    /// tab 切回时强制 AppKit 网格重布局。
    @State private var gridLayoutRefreshToken: Int = 0

    // 图片预加载由 onAppear 直接触发，无需追踪可见卡片 ID

    // MARK: - Scroll 恢复
    @StateObject private var libraryScrollRuntimeState = LibraryScrollRuntimeState()
    /// 当前活跃壁纸路径快照（仅路径集合变化时递增，驱动卡片 isCurrent 布尔刷新）
    @State private var activeWallpaperFilePaths: Set<String> = []
    @State private var activeWallpaperURLStrings: Set<String> = []
    @State private var activeWallpaperRevision: UInt = 0
    /// 文件夹解锁集合变化时递增，驱动文件夹卡锁态刷新（不观察 FolderLockService 全对象）
    @State private var folderUnlockRevision: UInt = 0
    /// 详情页导航前保存的滚动位置（>=0 表示需要恢复）
    @State private var savedLibraryScrollOffset: CGFloat = -1
    /// 恢复成功后自增，驱动 LibraryScrollRestorer 重新触发
    @State private var libraryScrollRestoreToken: Int = 0
    /// 库页首次出现时完成一次引导加载（全量 update + initialLoad）。
    /// 详情往返的 re-appear 不再重跑：详情打开期间 revision publisher 仍在线上，
    /// 数据变化已通过 debouncedUpdate 流入网格；重跑只会白白 gridReloadToken++
    /// 触发整网格 reconfigure + 重发网络请求。
    @State private var didBootstrapLibraryGrid = false

    // 壁纸比例筛选
    @State private var wallpaperRatioFilter: WallpaperRatioFilter = .all

    @State private var wallpaperItems: [AnyWallpaperItem] = []
    /// 未应用文字搜索的当前目录快照；搜索只在此快照上做后台筛选，
    /// 避免连续输入时反复从服务层重建整个列表。
    @State private var wallpaperSearchBaseItems: [AnyWallpaperItem] = []
    @State private var wallpaperSearchEntries: [LibrarySearchEntry] = []
    @State private var wallpaperFolderDisplay: [String: FolderDisplayInfo] = [:]
    // ⚡ 滚动 prefetch 用的 ID→Index 字典缓存（O(1) 查找替代 firstIndex(where:) O(N)）。
    @State private var wallpaperIDIndexCache: [String: Int] = [:]
    @State private var lastWallpaperPrefetchBucket: Int?
    @State private var updateWallpaperDebounce: DispatchWorkItem?
    /// 懒构建标记：非当前类型的列表被外部修订时只标脏，切过去/回可见时才重建。
    @State private var wallpaperItemsStale = false
    /// 封面后台预热的防抖任务：目录切换/搜索/收藏变化会连续重建网格，只跑最后一次。
    @State private var coverBackfillDebounce: Task<Void, Never>?
    /// 首次进入库页时的加载占位：数据快照（由 Helper 异步推送）与本地索引就绪前显示骨架，
    /// 避免「还没有数据」被误渲染成「没有下载」。只在进程内第一次进入时为 true。
    @State private var libraryFirstLoadPlaceholderVisible = true
    /// 后台服务连接状态。库记录只由 Helper 异步推送，断连时列表必然为空 ——
    /// 必须观察它，才能在空列表时把「服务没连上」和「确实没有内容」区分开。
    @ObservedObject private var helper = BackgroundAgentClient.shared
    /// 等库快照的兜底位：Helper 连着但迟迟不交付快照（或压根没连上）时置 true，
    /// 让骨架收摊并显示「后台服务未连接」，而不是无限骨架。
    /// 注意这不是「加载完成」信号：超时后仍没有快照时，列表为空**不能**判成
    /// 「没有下载」，只有 `librarySnapshotIsArrived` 才允许显示真的空态。
    @State private var librarySnapshotWaitTimedOut = false
    @State private var librarySnapshotWatchdog: Task<Void, Never>?
    /// 拉取任务的世代号：被取消的旧任务结束时不能把新任务的句柄抹掉。
    @State private var librarySnapshotFetchGeneration: UInt64 = 0
    /// 快照到达后「等缓存重建 → 构建列表」的任务句柄（重复到达只保最后一次）。
    @State private var librarySnapshotRebuildTask: Task<Void, Never>?
    /// 当前内容页（类型 + 子标签 + 目录）是否已经真正构建过一次。
    /// 快照到达 ≠ 网格有数据：列表由 ViewModel 的 revision 去抖重建，比快照晚一步。
    /// 骨架必须等「到达 + 已构建」，否则撤下瞬间仍是空列表。
    @State private var libraryCurrentPageIsBuilt = false
    private let wallpaperPrefetchNamespace = "library.wallpapers"

    // 文件夹导航
    @State private var currentWallpaperFolderID: String? = nil
    @State private var wallpaperFolderStack: [String] = []  // 面包屑栈
    @State private var folderNavigation = LibraryFolderNavigation()

    // 触摸板双指右滑返回（文件夹内）
    @State private var folderBackSwipeRegistration: UUID?
    @State private var folderBackKeyboardMonitor: Any?

    // 新建文件夹
    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var renamingFolder: LibraryFolder?
    @State private var renameFolderName = ""
    @State private var pendingWallpaperDeletion: AnyWallpaperItem?

    // 添加壁纸到文件夹
    @State private var showAddToFolderSheet = false

    // 拖拽排序 UI 状态
    /// 当前 hover 中的插入位置：插入到该 entry ID 之前。nil = 未 hover 任何插入条。
    @State private var hoveredInsertionID: String? = nil

    // 全部更新（Wallpaper Engine 数据）

    enum WallpaperRatioFilter: String, CaseIterable {
        case all = "all"
        case landscape = "landscape"
        case portrait = "portrait"

        var title: String {
            switch self {
            case .all: return LocalizationService.shared.t("filter.all")
            case .landscape: return LocalizationService.shared.t("filter.landscape")
            case .portrait: return LocalizationService.shared.t("filter.portrait")
            }
        }
    }

    enum SubTab: String, CaseIterable {
        case favorites = "favorites"
        case downloads = "downloads"

        var title: String {
            switch self {
            case .favorites: return LocalizationService.shared.t("my.favorites")
            case .downloads: return LocalizationService.shared.t("my.downloads")
            }
        }
    }

    private struct FolderDisplayInfo: Equatable {
        let previewURLs: [URL]
        let itemCount: Int
    }

    private struct LibrarySearchEntry: Sendable {
        let id: String
        let searchableText: String
    }

    /// 文件夹叠图后台预热任务（按 content+subTab 合并，避免快速切换时堆积）
    @State private var folderPreviewWarmupTask: Task<Void, Never>?

    private enum LastLibraryPageStore {
        private static let contentTypeKey = "my_library_last_content_type_v1"
        private static let subTabKey = "my_library_last_sub_tab_v1"

        static func load() -> (contentType: ContentType, subTab: SubTab)? {
            let defaults = WaifuXPreferences.shared
            guard let contentValue = defaults.string(forKey: contentTypeKey),
                  let contentType = ContentType(rawValue: contentValue) else {
                return nil
            }
            let subTabValue = defaults.string(forKey: subTabKey)
            let subTab = subTabValue.flatMap(SubTab.init(rawValue:)) ?? .downloads
            return (contentType, subTab)
        }

        static func save(contentType: ContentType, subTab: SubTab) {
            let defaults = WaifuXPreferences.shared
            defaults.set(contentType.rawValue, forKey: contentTypeKey)
            defaults.set(subTab.rawValue, forKey: subTabKey)
        }
    }

    private var libraryAtmosphereTint: ExploreAtmosphereTint {
        switch selectedContentType {
        case .wallpaper:
            return .wallpaperFallback
        }
    }

    private var trimmedLibrarySearchQuery: String {
        librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasActiveLibrarySearch: Bool {
        !trimmedLibrarySearchQuery.isEmpty
    }

    /// 当前内容类型的数据是否「可信」——可信才允许显示空态，否则显示骨架。
    ///
    /// 判据必须是「快照到没到」，不能是「列表空不空」：库记录由 Helper 异步推送，
    /// 首帧晚到时用空列表判空，会把「还没加载」渲染成「还没有下载壁纸」的假空态
    /// （2026-10-26 用户截图：库里 995 条壁纸，界面说没有下载）。
    /// 旧实现用「任意库类型有记录」+ 1.2s 超时兜底，两个洞都在：别的类型先到达
    /// 就摘掉当前页骨架；Helper 首帧 publish 要等 startRuntime 尾部（实测远超 1.2s），
    /// 超时一到照样塌成假空态。
    private var libraryHelperLooksDown: Bool {
        !helper.isConnected && (helper.lastError != nil || helper.requiresApproval)
    }

    /// 当前内容类型的数据是否可信（可信才允许显示空态，否则显示骨架）。
    private var libraryCurrentTypeIsLoaded: Bool {
        // 当前页已经有内容就放行：Helper 短暂重连（换包 / repair）时快照位会
        // 回落，但屏幕上的列表仍然有效，不该被骨架盖回去。
        if libraryHasAnyVisibleContent { return true }
        switch selectedContentType {
        case .wallpaper:
            return libraryHelperLooksDown
                || librarySnapshotWaitTimedOut
                || (helper.librarySnapshotIsArrived && libraryCurrentPageIsBuilt)
        }
    }

    /// 当前内容类型下是否已有可显示条目（文件夹也算）。
    private var libraryHasAnyVisibleContent: Bool {
        switch selectedContentType {
        case .wallpaper:
            return !wallpaperItems.isEmpty || !currentWallpaperFolders.isEmpty
        }
    }

    /// 骨架显隐：一次性首屏引导，加上「当前类型数据仍不可信」。
    /// 搜索态不参与（命中 0 条要直接显示搜索结果空态）。
    private var libraryGridPlaceholderVisible: Bool {
        guard !hasActiveLibrarySearch else { return false }
        if libraryFirstLoadPlaceholderVisible { return true }
        return !libraryCurrentTypeIsLoaded
    }

    /// 列表为空时，先判断是不是「后台服务没连上」。
    ///
    /// 库记录全部经 `BackgroundRuntimeBridge.observeLibrary` 由 Helper 推送，
    /// 会以为数据丢了（2026-10-19 用户反馈的正是这个读感），而真实动作是
    /// 恢复后台服务、不是重新下载。
    private var libraryBackendUnavailable: Bool {
        return libraryHelperLooksDown
            // 连接名义上正常、但看门狗到点仍没有快照：按「后台不可用」处理，
            // 比显示「还没有下载壁纸」诚实。
            || (librarySnapshotWaitTimedOut && !helper.librarySnapshotIsArrived)
    }

    /// 空态入口：断连时替换文案，连接正常时保持原有语义。
    @ViewBuilder
    private func libraryEmptySurface(
        title: String,
        subtitle: String,
        icon: String,
        accent: Color
    ) -> some View {
        if libraryBackendUnavailable {
            emptyLibrarySurface(
                title: t("library.backend.unavailable.title"),
                subtitle: t("library.backend.unavailable.hint"),
                icon: "bolt.slash",
                accent: accent
            )
        } else {
            emptyLibrarySurface(title: title, subtitle: subtitle, icon: icon, accent: accent)
        }
    }

    var body: some View {
        // 性能测量：开启 PERF_TRACE 编译标记后，会在控制台打印触发本 body 的属性来源
        #if PERF_TRACE
        let _ = Self._printChanges()
        #endif
        // body 拆成三段（根内容 / 事件监听 / 弹窗警告），避免单表达式类型检查超时
        librarySheetsAndAlerts(
            libraryEventObservers(libraryRootContent)
        )
    }

    /// 主体内容（背景 + 固定头部 + AppKit 网格）
    private var libraryRootContent: some View {
        ZStack(alignment: .topLeading) {
            if isEditing {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation {
                            isEditing = false
                            selectedItems.removeAll()
                        }
                    }
                    .allowsHitTesting(true)
            }

            // 背景渲染下沉到独立子视图：自行观察 ArcBackgroundSettings，
            // 外观设置变化只重建本背景，不触发整个库视图 body 重算。
            LibraryAtmosphereBackground(tint: libraryAtmosphereTint)
                // 把多层渐变+点阵+噪点合并成一个 Metal 纹理，减少 WindowServer 合成层数
                .drawingGroup(opaque: true)
                // 滚动时暂停背景重绘（背景是静态的，不需要每帧更新）
                .allowsHitTesting(false)

            GeometryReader { geometry in
                let contentWidth = max(0, geometry.size.width - 56)
                let gridConfig = LibraryGridConfig(contentWidth: contentWidth)

                VStack(spacing: 0) {
                    // 固定头部
                    VStack(alignment: .leading, spacing: 0) {
                        libraryHero
                        libraryControlPanel
                            .padding(.top, 20)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, mainTopBarContentPadding)
                    .padding(.bottom, 12)

                    // 2026-09 网格迁移：SwiftUI ScrollView + LazyVGrid → ExploreGridContainer
                    // 面包屑固定在网格上方，不再随内容滚出；滚动位置恢复由容器
                    // restoreScrollToken 接管（替代旧 LibraryScrollObserver）。
                    contentSections(config: gridConfig)
                        .padding(.horizontal, 28)
                        .padding(.top, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(CurrentWallpaperService.shared)
    }

    /// 等本地库缓存重建结束后再构建当前页列表。
    ///
    /// 快照到达 ≠ 缓存已反映快照：VM 的缓存在记录写入后还要重建一会儿，
    /// 直接重建会读到旧的空缓存，出现「撤骨架 → 空态闪现 → 内容」三段跳
    /// （用户说的「占位提前消失」）。重复触发只保最后一次。
    private func rebuildCurrentListsAfterCacheReady(reason: String) {
        librarySnapshotRebuildTask?.cancel()
        librarySnapshotRebuildTask = Task { @MainActor in
            await viewModel.awaitLocalLibraryCacheReady()
            // 沉降窗口：VM 的重建是「先起 Task 再 sleep 100ms」，只 await 在飞任务
            // 仍可能早于下一次重建。多等一拍，让「快照到达 → 缓存重建 → 列表构建」
            // 收敛成一次干净的交接，而不是骨架撤下后闪一下空态。
            // 后续若真漏了一拍，重建完成会推 libraryContentRevision → debouncedUpdate
            // → 重新判定 built，所以这里只需吸收常态延迟，不必穷尽时序。
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            rebuildCurrentLibraryLists(reason: reason)
            librarySnapshotRebuildTask = nil
        }
    }

    /// 主动拉库快照（有限次重试），直到快照到达或看门狗到点。
    ///
    /// 不等 Helper 的 publish：Helper 首次 publish 排在 `startRuntime()` 尾部
    /// （渲染器/屏保恢复之后），实测远超旧版 1.2s 兜底，被动等会把骨架塌成
    /// 假空态。Helper 未就绪时这次读明确失败，下一拍再试；到点仍无快照则转
    /// 「后台服务未连接」文案，不把骨架钉死。
    ///
    /// 首屏 `.task` 和每次 `onAppear` 都要调：`.task` 的引导分支只跑一次，
    /// 而离开库页会取消本任务 —— 少了这一处，再进库页就没人再拉快照了。
    private func startLibrarySnapshotFetchIfPending() {
        guard !helper.librarySnapshotIsArrived else { return }
        guard librarySnapshotWatchdog == nil else { return }
        if librarySnapshotWaitTimedOut { librarySnapshotWaitTimedOut = false }
        librarySnapshotFetchGeneration &+= 1
        let generation = librarySnapshotFetchGeneration
        librarySnapshotWatchdog = Task { @MainActor in
            let retryNanoseconds: UInt64 = 700_000_000
            let deadline = Date().addingTimeInterval(15)
            var attempts = 0
            // 无论成功、取消还是到点都要让出句柄（否则「断连后重新拉取」会被
            // 顶部的 guard 挡掉，骨架再也没人推进）；只在自己的世代仍是当前
            // 世代时清，避免被取消的旧任务抹掉新任务的句柄。
            defer {
                if generation == librarySnapshotFetchGeneration {
                    librarySnapshotWatchdog = nil
                }
            }
            while !Task.isCancelled, Date() < deadline {
                if helper.librarySnapshotIsArrived { return }
                attempts += 1
                do {
                    try await BackgroundAgentClient.shared.refreshLibrarySnapshot()
                } catch {
                    // 只记第一次失败：Helper 未就绪时这条必然失败，逐次刷屏
                    // 没有信息量，最终结论由超时日志给出。
                    if attempts == 1 {
                        AppLogger.debug(.general, "[LibraryLoad] 主动拉取库快照失败", metadata: [
                            "attempt": "\(attempts)",
                            "error": error.localizedDescription,
                        ])
                    }
                }
                if helper.librarySnapshotIsArrived { return }
                try? await Task.sleep(nanoseconds: retryNanoseconds)
            }
            guard !Task.isCancelled else { return }
            if !helper.librarySnapshotIsArrived {
                librarySnapshotWaitTimedOut = true
                AppLogger.debug(.general, "[LibraryLoad] 等待库快照超时", metadata: [
                    "attempts": "\(attempts)",
                    "connected": helper.isConnected ? "1" : "0",
                    "lastError": helper.lastError ?? "nil",
                ])
            }
        }
    }

    /// 生命周期 / 数据源 / 状态监听（从 body 拆出，降低类型检查开销）
    private func libraryEventObservers(_ content: some View) -> some View {
        content
        .task {
            // 每次出现都确保本地索引可用（缓存温热时是 no-op；失效时会重建并
            // 经 libraryContentRevision → debouncedUpdate 刷新网格）。
            let loadStart = Date()
            await viewModel.ensureLocalWallpaperIndex()
            let indexReady = Date()

            // 引导加载只跑一次：详情往返的 re-appear 跳过全量 update 与
            // initialLoad，避免返回时封面整网格重载。
            guard !didBootstrapLibraryGrid else {
                // 兜底：任何路径都不让首屏骨架留在屏幕上。
                libraryFirstLoadPlaceholderVisible = false
                return
            }
            didBootstrapLibraryGrid = true

            // 只构建当前内容类型；另一套标脏，切过去时重建。
            rebuildCurrentLibraryLists(reason: "initial-bootstrap")
            let itemsReady = Date()

            async let initialLoad: Void = viewModel.initialLoad()

            startLibrarySnapshotFetchIfPending()

            // 一次性引导的结束不再靠固定超时：骨架的持续显隐由
            // libraryCurrentTypeIsLoaded 决定，快照晚到时仍显示骨架而不是塌成假空态。
            // 这里只保证最短展示防闪，并在快照已到位时同步重建一次当前页列表。
            defer { libraryFirstLoadPlaceholderVisible = false }
            let minimumVisible: TimeInterval = 0.18
            let elapsed = Date().timeIntervalSince(loadStart)
            if elapsed < minimumVisible {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64((minimumVisible - elapsed) * 1_000_000_000)
                    )
                } catch {}
            }
            if helper.librarySnapshotIsArrived {
                rebuildCurrentListsAfterCacheReady(reason: "bootstrap-snapshot-ready")
            }

            _ = await initialLoad

            // 分段耗时：定位「我的库加载慢」到底卡在索引、条目构建还是快照到达。
            // snapshotArrived / counts 用来证明骨架撤下时数据是否真在（假空态取证）。
            AppLogger.debug(.general, "[LibraryLoad] 我的库加载分段耗时", metadata: [
                "indexMS": Int(indexReady.timeIntervalSince(loadStart) * 1000),
                "itemsMS": Int(itemsReady.timeIntervalSince(indexReady) * 1000),
                "loadMS": Int(Date().timeIntervalSince(itemsReady) * 1000),
                "snapshotMS": Int(Date().timeIntervalSince(loadStart) * 1000),
                "snapshotArrived": helper.librarySnapshotIsArrived ? "1" : "0",
                "helperConnected": helper.isConnected ? "1" : "0",
                "content": "wallpaper",
                "counts": "\(wallpaperItems.count)",
                "records": "\(WallpaperLibraryService.shared.downloadRecords.count)",
            ])
        }
        .onAppear {
            startLibrarySnapshotFetchIfPending()
            restoreLastLibraryPageIfNeeded()
            // ✅ 从详情返回时触发 ScrollView 滚动位置恢复
            if savedLibraryScrollOffset > 0 {
                libraryScrollRestoreToken += 1
            }
            // 注册触摸板双指右滑返回手势（文件夹内）。
            registerFolderBackSwipeHandler()
            registerFolderBackKeyboardHandler()
            syncActiveWallpaperSnapshot()
            // 详情往返/切回库页：继续上次未补完的封面预热（服务内去重）。
            scheduleLibraryCoverBackfillIfNeeded()
        }
        .onDisappear {
            librarySnapshotWatchdog?.cancel()
            librarySnapshotWatchdog = nil
            librarySnapshotRebuildTask?.cancel()
            librarySnapshotRebuildTask = nil
            unregisterFolderBackSwipeHandler()
            unregisterFolderBackKeyboardHandler()
            librarySearchDebounce?.cancel()
            librarySearchTask?.cancel()
            coverBackfillDebounce?.cancel()
            coverBackfillDebounce = nil
            LibraryCoverBackfillService.shared.cancel(reason: "library-disappear")
        }

        .onReceive(NotificationCenter.default.publisher(for: .libraryScrollDidBecomeIdle)) { _ in
            guard isVisible else { return }
            resumeLibraryPrefetchAfterScroll()
        }
        .onChange(of: librarySearchQuery) { _, _ in
            scheduleLibrarySearchUpdate()
        }
        .onChange(of: isVisible) { _, visible in
            if !visible {
                isLibrarySearchExpanded = false
                persistLastLibraryPage()
            } else {
                restoreLastLibraryPageIfNeeded()
                // 回到库页时同步一次当前壁纸快照（可能在其他页被切换）
                syncActiveWallpaperSnapshot()
                // 库页重新可见：被标脏的另一套列表此时补齐
                rebuildStaleLibraryListsIfNeeded()
                // tab 切回时让 AppKit 网格主动补一次布局
                gridLayoutRefreshToken &+= 1
            }
        }
        // AppKit 网格「数量不变但内容变化」的重配触发器
        .onChange(of: isEditing) { _, _ in
            gridReloadToken &+= 1
        }
        .onChange(of: selectedItems) { _, _ in
            gridReloadToken &+= 1
        }
        .onChange(of: activeWallpaperRevision) { _, _ in
            gridReloadToken &+= 1
        }
        .onChange(of: folderUnlockRevision) { _, _ in
            gridReloadToken &+= 1
        }
        // ViewModel 不再 @ObservedObject：用 publisher 只听库内容 revision
        .onReceive(viewModel.$libraryContentRevision) { _ in

                debouncedUpdateWallpaperItems()

        }

        .onChange(of: helper.librarySnapshotIsArrived) { _, arrived in
            guard arrived else {
                // 断连/换 Helper：上一帧快照不再可信，回到「未构建」，并重新起
                // 拉取（当前页此刻仍空，否则骨架会一直钉到用户离开再进来）。
                libraryCurrentPageIsBuilt = false
                startLibrarySnapshotFetchIfPending()
                return
            }
            libraryCurrentPageIsBuilt = false
            librarySnapshotWaitTimedOut = false
            librarySnapshotWatchdog?.cancel()
            librarySnapshotWatchdog = nil
            // 快照到达：先重建当前页列表再放行渲染。顺序反了会出现三段跳
            // （骨架撤下 → 空态闪现 → 内容），正是用户看到的「占位提前消失」。
            rebuildCurrentListsAfterCacheReady(reason: "snapshot-arrived")
            AppLogger.debug(.general, "[LibraryLoad] 库快照到达并重建列表", metadata: [
                "content": "wallpaper",
                "counts": "\(wallpaperItems.count)",
            ])
        }
        .onChange(of: selectedSubTab) { _, _ in
            persistLastLibraryPage()
            // 切换子标签时重置文件夹导航和滚动位置
            savedLibraryScrollOffset = -1
            currentWallpaperFolderID = nil
            wallpaperFolderStack.removeAll()
            isEditing = false
            selectedItems.removeAll()
            gridScrollToTopToken &+= 1
            rebuildCurrentLibraryLists(reason: "subtab-switch")

        }
        .onChange(of: wallpaperRatioFilter) { _, _ in
            debouncedUpdateWallpaperItems()
        }

        .onReceive(folderStore.$wallpaperFolders) { _ in
            debouncedUpdateWallpaperItems()
        }

        .onReceive(gridOrderStore.$revision) { revision in
            handleGridOrderRevision(revision)
        }
        // 当前壁纸 / 文件夹解锁：只在集合真变化时写 @State，避免无关 @Published 刷整页
        .onReceive(CurrentWallpaperService.shared.$activeFilePaths) { paths in
            guard paths != activeWallpaperFilePaths else { return }
            activeWallpaperFilePaths = paths
            activeWallpaperRevision &+= 1
        }
        .onReceive(CurrentWallpaperService.shared.$activeURLStrings) { urls in
            guard urls != activeWallpaperURLStrings else { return }
            activeWallpaperURLStrings = urls
            activeWallpaperRevision &+= 1
        }
        .onReceive(FolderLockService.shared.$unlockedFolderIDs) { _ in
            folderUnlockRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .appShouldReleaseForegroundMemory)) { _ in
            releaseForegroundMemory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDidReceiveMemoryPressure)) { _ in
            stopLibraryPrefetchers()
        }

    }

    /// 弹窗 / 警告框挂载（从 body 拆出，降低类型检查开销）
    private func librarySheetsAndAlerts(_ content: some View) -> some View {
        content
        .sheet(isPresented: $showNewFolderSheet) {
            NewFolderSheet(
                folderName: $newFolderName,
                onConfirm: {
                    let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let contentType: LibraryFolder.FolderContentType = .wallpaper
                    let parentID = currentWallpaperFolderID
                    let collection: LibraryFolder.FolderCollection = selectedSubTab == .favorites ? .favorites : .downloads
                    folderStore.createFolder(name: name, contentType: contentType, parentID: parentID, collection: collection)
                    newFolderName = ""
                    showNewFolderSheet = false
                    rebuildCurrentLibraryLists(reason: "folder-mutation")
                },
                onCancel: {
                    newFolderName = ""
                    showNewFolderSheet = false
                }
            )
        }
        .sheet(item: $renamingFolder) { folder in
            NewFolderSheet(
                title: t("folder.rename"),
                confirmTitle: t("rename"),
                folderName: $renameFolderName,
                onConfirm: {
                    let name = renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    folderStore.renameFolder(id: folder.id, contentType: folder.contentType, newName: name)
                    renameFolderName = ""
                    renamingFolder = nil
                    rebuildCurrentLibraryLists(reason: "folder-mutation")
                },
                onCancel: {
                    renameFolderName = ""
                    renamingFolder = nil
                }
            )
        }
        .sheet(isPresented: $showAddToFolderSheet) {
            addToFolderSheetContent
        }
        // AppKit 网格上方使用系统弹窗；按钮持有呈现时的 item，避免关闭 Binding 清空待删对象。
        .alert(t("delete"), isPresented: wallpaperDeletionAlertPresented,
               presenting: pendingWallpaperDeletion) { item in
            Button(t("delete"), role: .destructive) {
                deleteWallpaperItem(item)
                pendingWallpaperDeletion = nil
            }
            Button(t("cancel"), role: .cancel) {
                pendingWallpaperDeletion = nil
            }
        } message: { _ in
            Text(t("deleteConfirmMessage"))
        }
    }

    private var wallpaperDeletionAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingWallpaperDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingWallpaperDeletion = nil
                }
            }
        )
    }

    private func restoreLastLibraryPageIfNeeded() {
        guard isVisible, !didRestoreLastLibraryPage else { return }
        didRestoreLastLibraryPage = true
        guard let lastPage = LastLibraryPageStore.load() else {
            persistLastLibraryPage()
            return
        }

        var didChange = false
        if selectedContentType != lastPage.contentType {
            selectedContentType = lastPage.contentType
            didChange = true
        }
        if selectedSubTab != lastPage.subTab {
            selectedSubTab = lastPage.subTab
            didChange = true
        }
        if didChange {
            savedLibraryScrollOffset = -1
            currentWallpaperFolderID = nil
            wallpaperFolderStack.removeAll()
            isEditing = false
            selectedItems.removeAll()
            rebuildCurrentLibraryLists(reason: "library-reset")
        }
    }

    private func persistLastLibraryPage() {
        LastLibraryPageStore.save(contentType: selectedContentType, subTab: selectedSubTab)
    }

    private func releaseForegroundMemory() {
        // 列表被清空：数据不再可信，骨架重新接管，避免下一次进库页闪「没有下载」。
        libraryCurrentPageIsBuilt = false
        librarySnapshotWaitTimedOut = false
        viewModel.releaseForegroundMemory()

        savedLibraryScrollOffset = -1
        libraryScrollRestoreToken &+= 1
        selectedWallpaper = nil
        wallpaperContext.removeAll()
        librarySearchTask?.cancel()
        librarySearchDebounce?.cancel()
        librarySearchGeneration &+= 1
        wallpaperItems.removeAll()
        wallpaperSearchBaseItems.removeAll()
        wallpaperSearchEntries.removeAll()
        wallpaperFolderDisplay.removeAll()
        wallpaperIDIndexCache.removeAll()
        currentWallpaperFolderID = nil
        wallpaperFolderStack.removeAll()
        selectedItems.removeAll()
        isEditing = false
        showNewFolderSheet = false
        newFolderName = ""
        lastWallpaperPrefetchBucket = nil
        stopLibraryPrefetchers()
    }

    private func stopLibraryPrefetchers() {
        ForegroundPrefetchManager.shared.stop(namespace: wallpaperPrefetchNamespace)
    }

    private func handleLibraryScroll(_ offset: CGFloat) {
        // 只写运行时 offset + 滚动门控；不触发任何 @State，避免滚动帧刷整页 body
        libraryScrollRuntimeState.currentOffset = offset
        let wasScrolling = LibraryScrollHoverGate.shared.isScrolling
        LibraryScrollHoverGate.shared.noteScrollActivity()
        // 刚进入滚动：立刻停掉正在进行的 Kingfisher 预取（不写 @State）
        if !wasScrolling {
            ForegroundPrefetchManager.shared.stop(namespace: wallpaperPrefetchNamespace)
        }
    }

    private var libraryHero: some View {
        HStack(alignment: .bottom) {
            Text(t("my.media.library"))
                .font(.system(size: 42, weight: .bold, design: .serif))
                .foregroundStyle(.white.opacity(0.96))

            Spacer()

            let (count, icon, color, key) = heroBadgeInfo
            SettingsStatusBadge(
                title: "\(count) \(t(key))",
                systemImage: icon,
                color: color
            )
        }
    }

    private var heroBadgeInfo: (count: Int, icon: String, color: Color, key: String) {
        switch selectedContentType {
        case .wallpaper:
            if selectedSubTab == .favorites {
                return (viewModel.favorites.count, "heart.fill", LiquidGlassColors.primaryPink, "item.favorites")
            } else {
                return (viewModel.allLocalWallpapers.count, "arrow.down.circle.fill", LiquidGlassColors.accentCyan, "item.downloads")
            }
        }
    }

    private var activeLibraryTint: Color {
        switch selectedContentType {
        case .wallpaper:
            return LiquidGlassColors.primaryPink
        }
    }

    private var libraryControlPanel: some View {
        let tint = activeLibraryTint

        return HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ContentTypePicker(selected: $selectedContentType)
                librarySearchControl

                subTabDropdown
            }

            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 10) {

                    wallpaperRatioPicker(color: tint)

                libraryToolbarActions(tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassContainer(spacing: 12)
    }

    // MARK: - Content Sections
    @ViewBuilder
    private func contentSections(config: LibraryGridConfig) -> some View {
        switch selectedContentType {
        case .wallpaper:
            wallpaperSection(config: config)
        }
    }

    // MARK: - Wallpaper Section
    private func wallpaperSection(config: LibraryGridConfig) -> some View {
        LibraryFolderTransition(
            pageID: "wallpaper/\(selectedSubTab.rawValue)/\(currentWallpaperFolderID ?? "root")",
            navigation: folderNavigation,
            isVisible: isVisible
        ) {
            VStack(alignment: .leading, spacing: 12) {
                // 文件夹导航面包屑与内容同层进退；固定工具栏不参与过渡。
                folderBreadcrumb(
                    folderStack: wallpaperFolderStack,
                    isInFolder: currentWallpaperFolderID != nil,
                    onBack: popWallpaperFolder,
                    onRoot: { navigateToWallpaperFolder(nil) },
                    onAdd: { showAddToFolderSheet = true }
                )

                if libraryGridPlaceholderVisible {
                    libraryGridLoadingPlaceholder(config: config)
                } else if wallpaperItems.isEmpty && currentWallpaperFolders.isEmpty {
                    libraryEmptySurface(
                        title: hasActiveLibrarySearch ? t("error.empty.title") : (selectedSubTab == .favorites ? t("no.wallpaper.favorites") : t("no.wallpaper.downloads")),
                        subtitle: hasActiveLibrarySearch ? t("error.empty.message") : (selectedSubTab == .favorites ? t("no.wallpaper.favorites.hint") : t("no.wallpaper.downloads.hint")),
                        icon: hasActiveLibrarySearch ? "magnifyingglass" : (selectedSubTab == .favorites ? "heart.slash" : "arrow.down.circle"),
                        accent: LiquidGlassColors.primaryPink
                    )
                } else {
                    wallpaperGridContainer(config: config)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// 壁纸网格（文件夹 + 壁纸混排，NSCollectionView cell 复用）
    private func wallpaperGridContainer(config: LibraryGridConfig) -> some View {
        let entries = orderedWallpaperGridItems
        let folderDisplay = wallpaperFolderDisplay
        let editing = isEditing
        let selection = selectedItems
        let accent: NSColor = selectedSubTab == .favorites ? LibraryGridAccent.pink : LibraryGridAccent.cyan

        return ExploreGridContainer(
            itemCount: { entries.count },
            aspectRatio: { _ in
                LibraryGridCellMetrics.cardAspectRatio(columnWidth: config.cardWidth)
            },
            configureCell: { cell, idx in
                guard idx < entries.count else { return }
                switch entries[idx] {
                case .folder(let folder):
                    guard let folderCell = cell as? LibraryFolderGridCell else { return }
                    folderCell.configure(
                        with: makeWallpaperFolderCellModel(
                            folder,
                            display: folderDisplay[folder.id]
                        ),
                        isFavorite: false
                    )
                case .item(let item):
                    guard let itemCell = cell as? LibraryWallpaperGridCell else { return }
                    itemCell.configure(
                        with: makeWallpaperCellModel(
                            item,
                            editing: editing,
                            selection: selection,
                            accent: accent
                        ),
                        isFavorite: false
                    )
                }
            },
            cellClass: LibraryWallpaperGridCell.self,
            cellClassForItem: { idx in
                guard idx < entries.count, entries[idx].isFolderEntry else {
                    return LibraryWallpaperGridCell.self
                }
                return LibraryFolderGridCell.self
            },
            additionalCellClasses: [LibraryFolderGridCell.self],
            gridSpacing: 16,
            onSelect: { idx in
                guard idx < entries.count else { return }
                switch entries[idx] {
                case .folder(let folder):
                    handleFolderTap(folder)
                case .item(let item):
                    handleWallpaperTap(item.wallpaper)
                }
            },
            onSelectionSource: { idx, source in
                guard !editing, !isEditing, isVisible, selectedContentType == .wallpaper,
                      !libraryGridPlaceholderVisible, entries.indices.contains(idx),
                      case .item(let item) = entries[idx],
                      libraryCardTransitionContentIsUnlocked(
                          folderID: currentWallpaperFolderID, contentType: .wallpaper
                      ), let source, source.itemID == item.wallpaper.id else {
                    onPrepareCardTransition?(nil)
                    return
                }
                onPrepareCardTransition?(source)
            },
            selectionItemIdentifier: { idx in
                guard entries.indices.contains(idx), case .item(let item) = entries[idx] else { return "" }
                return item.wallpaper.id
            },
            onVisibleItemsChange: { indexPaths in
                handleWallpaperVisibleChange(indexPaths, entries: entries)
            },
            onScrollOffsetChange: { offset in
                handleLibraryScroll(offset)
            },
            onReachBottom: {},
            scrollToTopToken: gridScrollToTopToken,
            restoreScrollToken: libraryScrollRestoreToken,
            restoreScrollOffset: savedLibraryScrollOffset,
            reloadToken: gridReloadToken,
            layoutRefreshToken: gridLayoutRefreshToken,
            allowsScrolling: true,
            isVisible: isVisible,
            layoutWidth: config.contentWidth,
            gridColumnCount: config.columnCount,
            hoverExpansionAllowance: 0,
            contentInsets: NSEdgeInsets(top: 0, left: 0, bottom: 80, right: 0),
            pasteboardWriterForItem: { idx in
                guard idx < entries.count else { return nil }
                return NSString(string: dragPayload(for: entries[idx].id))
            },
            onValidateReorderDrop: { payloads, _ in
                guard isEditing else { return false }
                // 拖拽 hover 期间每次鼠标移动都会走这里。不调 currentItemIDs（它会重新取文件夹、
                // 重新排序）；直接用渲染时已算好的集合，只做一次 Set 构建。
                let availableIDs = Set(entries.map(\.id))
                return LibraryDragPayload.ids(from: payloads).contains { availableIDs.contains($0) }
            },
            onPerformReorderDrop: { payloads, targetIndex in
                let targetID: String? = targetIndex < entries.count ? entries[targetIndex].id : nil
                return handleGridReorderDrop(payloads, before: targetID)
            },
            itemIdentifier: { idx in
                idx < entries.count ? entries[idx].id : ""
            }
        )
    }

    /// 可见区变化：维护「最后出现」的壁纸项并驱动预取（替代旧 LazyVGrid .onAppear）
    private func handleWallpaperVisibleChange(
        _ indexPaths: Set<IndexPath>,
        entries: [LibraryGridEntry<AnyWallpaperItem>]
    ) {
        guard let index = indexPaths.map(\.item).filter({ entries.indices.contains($0) }).sorted(by: >).first(where: {
            if case .item = entries[$0] { return true }
            return false
        }), case .item(let item) = entries[index] else { return }
        libraryScrollRuntimeState.lastWallpaperItemID = item.id
        preloadNearbyWallpapers(in: entries, at: index)
    }

    @MainActor
    private func makeWallpaperCellModel(
        _ item: AnyWallpaperItem,
        editing: Bool,
        selection: Set<String>,
        accent: NSColor
    ) -> LibraryWallpaperCellModel {
        // configureCell 在滚动复用/批量重配（选中、token 递增）时高频执行，
        // 同步打磁盘会卡主线程；旧 SwiftUI contextMenu 闭包同样只在右键时求值。
        let menuProvider: () -> [LibraryGridMenuEntry] = { [self] in
            var menuEntries: [LibraryGridMenuEntry] = []
            if !wallpaperMoveTargetFolders.isEmpty {
                menuEntries.append(
                    .submenu(
                        title: t("move.to.folder"),
                        icon: "folder.badge.gearshape",
                        entries: wallpaperMoveTargetFolders.map { folder in
                            .item(title: folder.name, icon: "folder", destructive: false) {
                                moveWallpapersToFolder(ids: [item.id], folderID: folder.id)
                            }
                        }
                    )
                )
            }
            if currentWallpaperFolderID != nil {
                menuEntries.append(
                    .item(title: t("remove.from.folder"), icon: "folder.badge.minus", destructive: false) {
                        gridOrderStore.removeIDs([item.id], from: currentGridOrderScope)
                        folderStore.moveWallpaperToFolder(
                            wallpaperID: item.id,
                            folderID: nil,
                            scope: currentWallpaperFolderScope
                        )
                        updateWallpaperItems()
                    }
                )
            }

            menuEntries.append(.divider)
            menuEntries.append(
                .item(title: t("delete"), icon: "trash", destructive: true) {
                    pendingWallpaperDeletion = item
                }
            )
            return menuEntries
        }

        return LibraryWallpaperCellModel(
            wallpaper: item.wallpaper,
            localFileURL: item.localFileURL,
            isEditing: editing,
            isSelected: selection.contains(item.id),
            isCurrentWallpaper: isActiveWallpaperURL(item.localFileURL)
                || isActiveWallpaperURL(item.wallpaper.fullImageURL),
            accent: accent,
            makeMenuEntries: menuProvider,
            isCardTransitionAllowed: {
                libraryCardTransitionContentIsUnlocked(
                    folderID: currentWallpaperFolderID, contentType: .wallpaper
                )
            }
        )
    }

    @MainActor
    private func makeWallpaperFolderCellModel(
        _ folder: LibraryFolder,
        display: FolderDisplayInfo?
    ) -> LibraryFolderCellModel {
        // 依赖 folderUnlockRevision，解锁集合变化时刷新锁态
        _ = folderUnlockRevision
        let isUnlocked = FolderLockService.shared.isFolderUnlocked(folder.id)

        var menuEntries: [LibraryGridMenuEntry] = []
        menuEntries.append(
            .item(title: t("folder.rename"), icon: "pencil", destructive: false) {
                startRenamingFolder(folder)
            }
        )
        if folder.isLocked, isUnlocked {
            menuEntries.append(
                .item(title: t("folder.relock"), icon: "lock.fill", destructive: false) {
                    FolderLockService.shared.lockFolder(folder.id)
                }
            )
        }
        menuEntries.append(
            .item(
                title: folder.isLocked ? t("folder.unlock") : t("folder.lock"),
                icon: folder.isLocked ? "lock.open" : "lock",
                destructive: false
            ) {
                folderStore.toggleFolderLock(id: folder.id, contentType: .wallpaper)
            }
        )
        menuEntries.append(.divider)

        menuEntries.append(
            .item(title: t("disband.folder"), icon: "folder.badge.minus", destructive: true) {
                folderStore.deleteFolder(id: folder.id, contentType: .wallpaper)
                gridOrderStore.removeIDs(["folder_\(folder.id)"], from: currentGridOrderScope)
                updateWallpaperItems()
            }
        )
        menuEntries.append(
            .item(title: t("delete.folder.with.contents"), icon: "trash", destructive: true) {
                deleteFolderWithContents(folderID: folder.id, contentType: .wallpaper)
            }
        )

        return LibraryFolderCellModel(
            folder: folder,
            previewURLs: display?.previewURLs ?? [],
            itemCount: display?.itemCount ?? 0,
            isUnlocked: isUnlocked,
            menuEntries: menuEntries,
            onDrop: { ids in
                moveWallpapersToFolder(ids: ids, folderID: folder.id)
            },
            onRelock: {
                FolderLockService.shared.lockFolder(folder.id)
            }
        )
    }

    private func navigateToWallpaperFolder(_ folderID: String?) {
        guard currentWallpaperFolderID != folderID else { return }
        folderNavigation.move(folderID == nil ? .backward : .forward)
        if folderID == nil {
            wallpaperFolderStack.removeAll()
        } else if let current = currentWallpaperFolderID {
            wallpaperFolderStack.append(current)
        }
        currentWallpaperFolderID = folderID
        gridScrollToTopToken &+= 1
        updateWallpaperItems()
    }

    private func popWallpaperFolder() {
        guard currentWallpaperFolderID != nil else { return }
        folderNavigation.move(.backward)
        currentWallpaperFolderID = wallpaperFolderStack.popLast()
        gridScrollToTopToken &+= 1
        updateWallpaperItems()
    }

    /// Esc navigates up one folder level. Keep the focused search field's own Esc behavior intact.
    private func handleEscapeKey() -> Bool {
        guard isVisible, !isLibrarySearchFocused else { return false }

        switch selectedContentType {
        case .wallpaper:
            guard currentWallpaperFolderID != nil else { return false }
            popWallpaperFolder()
            return true
        }
    }

    /// 「全部更新」菜单标签：空闲显示入口文案，运行中显示检查/进度；
    /// 检查阶段 total 尚未回填，先显示「检查更新中...」。

    private var isPresentingLibraryModal: Bool {
        showNewFolderSheet || renamingFolder != nil || showAddToFolderSheet || pendingWallpaperDeletion != nil || NSApp.modalWindow != nil
    }

    private func registerFolderBackKeyboardHandler() {
        guard folderBackKeyboardMonitor == nil else { return }

        folderBackKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard NSApp.isActive,
                  event.window?.isKeyWindow == true,
                  event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !CropAdjustOverlayController.shared.isAdjusting,
                  !self.isPresentingLibraryModal else {
                return event
            }

            return self.handleEscapeKey() ? nil : event
        }
    }

    private func unregisterFolderBackKeyboardHandler() {
        guard let folderBackKeyboardMonitor else { return }
        NSEvent.removeMonitor(folderBackKeyboardMonitor)
        self.folderBackKeyboardMonitor = nil
    }

    // MARK: - 触摸板双指右滑返回

    private var isInAnyFolder: Bool {
        isVisible && currentWallpaperFolderID != nil
    }

    /// 注册共享滚动事件路由：详情页的优先级更高，避免返回详情时同时退出后台文件夹。
    private func registerFolderBackSwipeHandler() {
        guard folderBackSwipeRegistration == nil else { return }
        folderBackSwipeRegistration = TrackpadBackSwipeRouter.shared.register(
            priority: 10,
            isEnabled: { self.isInAnyFolder },
            action: {
                if self.selectedContentType == .wallpaper {
                    self.popWallpaperFolder()
                }
            }
        )
    }

    private func unregisterFolderBackSwipeHandler() {
        guard let folderBackSwipeRegistration else { return }
        TrackpadBackSwipeRouter.shared.unregister(folderBackSwipeRegistration)
        self.folderBackSwipeRegistration = nil
    }

    private var currentWallpaperFolderScope: WallpaperLibraryService.FolderMembershipScope {
        selectedSubTab == .favorites ? .favorites : .downloads
    }

    private func moveTargetFolders(
        contentType: LibraryFolder.FolderContentType,
        excluding currentFolderID: String?
    ) -> [LibraryFolder] {
        let collection: LibraryFolder.FolderCollection = selectedSubTab == .favorites ? .favorites : .downloads
        let folders = folderStore.wallpaperFolders
        return folders
            .filter { $0.collection == collection && $0.id != currentFolderID }
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.id < rhs.id
            }
    }

    private var wallpaperMoveTargetFolders: [LibraryFolder] {
        moveTargetFolders(contentType: .wallpaper, excluding: currentWallpaperFolderID)
    }

    private func moveWallpapersToFolder(ids: [String], folderID: String) {
        // 空字符串不是合法文件夹 ID，统一视为根目录 nil，避免写入 "" 后变成“幽灵归属”
        let normalizedFolderID = WallpaperLibraryService.normalizedFolderID(folderID)
        // 「全选」会连文件夹卡一起选中，但文件夹不能被收纳进文件夹（本 App 不做嵌套）：
        // 过滤掉，顺带避免 gridOrderStore 连带清掉文件夹自己的排序记录。
        let itemIDs = ids.filter { !$0.hasPrefix("folder_") }
        AppLogger.debug(.grid, "[DragDiag] 壁纸拖入文件夹", metadata: [
            "folderID": normalizedFolderID ?? "<根目录>",
            "movedItems": itemIDs.count,
            "skippedFolders": ids.count - itemIDs.count
        ])
        gridOrderStore.removeIDs(Set(itemIDs), from: currentGridOrderScope)
        let scope = currentWallpaperFolderScope
        let unifiedByID: [String: UnifiedLocalWallpaper] = Dictionary(
            uniqueKeysWithValues: viewModel.allLocalWallpapers.map { ($0.id, $0) }
        )
        for id in itemIDs {
            // 对「扫描进来但还没有 DownloadRecord」的项传 fallback，
            // 让 Service 层自动补登记，确保 folderID 写得进去。
            let fallback: (wallpaper: Wallpaper, fileURL: URL)?
            if scope == .downloads, let unified = unifiedByID[id], unified.downloadRecord == nil {
                fallback = (unified.wallpaper, unified.fileURL)
            } else {
                fallback = nil
            }
            folderStore.moveWallpaperToFolder(
                wallpaperID: id,
                folderID: normalizedFolderID,
                scope: scope,
                fallback: fallback
            )
        }
        updateWallpaperItems()
    }

    /// 只重建当前内容类型的列表；另一套只标脏（切过去/库页回可见时才重建）。
    /// 封面 URL 解析）不再每次同时执行。
    private func rebuildCurrentLibraryLists(reason: String) {
        // 换页/重建前先判「本页数据不可信」，由 update 成功构建后再翻回可信。
        libraryCurrentPageIsBuilt = false
        switch selectedContentType {
        case .wallpaper:
            updateWallpaperItems()
        }
    }

    /// 库页回可见时把标脏的另一套补齐。
    private func rebuildStaleLibraryListsIfNeeded() {
        if wallpaperItemsStale {
            wallpaperItemsStale = false
            updateWallpaperItems()
        }

    }

    private func debouncedUpdateWallpaperItems() {
        updateWallpaperDebounce?.cancel()
        let work = DispatchWorkItem { [self] in
            updateWallpaperItems()
        }
        updateWallpaperDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// 搜索只影响当前打开的内容类型；输入过程中合并更新，避免每个字符都
    /// 在主线程重建两个列表并触发网格重配。文字匹配在后台索引上进行，
    /// 主线程只接收最终的匹配位置并重配一次当前网格。
    private func scheduleLibrarySearchUpdate() {
        librarySearchDebounce?.cancel()
        librarySearchTask?.cancel()
        librarySearchGeneration &+= 1

        let generation = librarySearchGeneration
        let contentType = selectedContentType
        let query = trimmedLibrarySearchQuery
        let normalizedQuery = query.localizedLowercase

        // 清空搜索时直接恢复当前目录快照，不经过后台任务。
        guard !query.isEmpty else {
            switch contentType {
            case .wallpaper:
                updateWallpaperItems()
            }
            syncSelectionWithVisibleItems()
            return
        }

        let entries = wallpaperSearchEntries
        let work = DispatchWorkItem { [self] in
            guard generation == librarySearchGeneration else { return }
            librarySearchTask = Task { @MainActor [self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled, generation == librarySearchGeneration else { return }

                let matchingTask = Task.detached(priority: .userInitiated) {
                    var result: [Int] = []
                    result.reserveCapacity(entries.count / 4)
                    for (index, entry) in entries.enumerated() {
                        guard !Task.isCancelled else { return [Int]() }
                        if entry.searchableText.contains(normalizedQuery) {
                            result.append(index)
                        }
                    }
                    return result
                }
                let matchingIndices = await withTaskCancellationHandler(operation: {
                    await matchingTask.value
                }, onCancel: {
                    matchingTask.cancel()
                })

                guard !Task.isCancelled, generation == librarySearchGeneration else { return }
                switch contentType {
                case .wallpaper:
                    wallpaperItems = matchingIndices.map { wallpaperSearchBaseItems[$0] }
                    var idMap: [String: Int] = [:]
                    idMap.reserveCapacity(wallpaperItems.count)
                    for (index, item) in wallpaperItems.enumerated() {
                        idMap[item.id] = index
                    }
                    wallpaperIDIndexCache = idMap
                    gridReloadToken &+= 1
                    refreshWallpaperFolderDisplay()
                }
                syncSelectionWithVisibleItems()
            }
        }
        librarySearchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
    }

    // MARK: - 当前壁纸快照（不订阅 CurrentWallpaperService 全对象）

    private func syncActiveWallpaperSnapshot() {
        let service = CurrentWallpaperService.shared
        let paths = service.activeFilePaths
        let urls = service.activeURLStrings
        if paths != activeWallpaperFilePaths {
            activeWallpaperFilePaths = paths
        }
        if urls != activeWallpaperURLStrings {
            activeWallpaperURLStrings = urls
        }
    }

    /// 与 `CurrentWallpaperService.isCurrentWallpaper` 等价，但只读本地快照，
    /// 避免顶层 @ObservedObject 在任意活跃路径重建时刷整页 body。
    private func isActiveWallpaperURL(_ url: URL?) -> Bool {
        // 引用 revision，确保路径/URL 集合变化时 SwiftUI 会重算依赖该布尔的卡片
        _ = activeWallpaperRevision
        guard let url else { return false }
        if activeWallpaperURLStrings.contains(url.absoluteString) {
            return true
        }
        guard url.isFileURL else { return false }
        guard !activeWallpaperFilePaths.isEmpty else { return false }
        let candidate = url.standardizedFileURL.path
        if activeWallpaperFilePaths.contains(candidate) {
            return true
        }
        for activePath in activeWallpaperFilePaths {
            if candidate.hasPrefix(activePath + "/") || activePath.hasPrefix(candidate + "/") {
                return true
            }
        }
        return false
    }

    private func updateWallpaperItems() {
        librarySearchTask?.cancel()
        librarySearchGeneration &+= 1
        lastWallpaperPrefetchBucket = nil
        let baseItems: [AnyWallpaperItem]
        switch selectedSubTab {
        case .favorites:
            let allFavorites = viewModel.favorites
            let folderID = WallpaperLibraryService.normalizedFolderID(currentWallpaperFolderID)
            let filtered = allFavorites.filter { wallpaper in
                guard let record = WallpaperLibraryService.shared.favoriteRecord(for: wallpaper.id) else { return false }
                return WallpaperLibraryService.normalizedFolderID(record.folderID) == folderID
            }
            baseItems = filtered.map {
                AnyWallpaperItem(
                    wallpaper: $0,
                    localFileURL: viewModel.localFileURLIfAvailable(for: $0)
                )
            }
        case .downloads:
            let allLocal = viewModel.allLocalWallpapers
            let folderID = WallpaperLibraryService.normalizedFolderID(currentWallpaperFolderID)
            let filtered = allLocal.filter { unified in
                // 实时查活跃记录：cachedAllLocalWallpapers 里的 downloadRecord 是上次重建的旧拷贝，
                // 移动/删除后的同步刷新会读到旧 folderID / 旧存活状态，表现为「要操作两次才生效」。
                // downloadRecord(for:) 的索引只含 isActive 记录：软删 / 不存在 → 剔除。
                if let record = WallpaperLibraryService.shared.downloadRecord(for: unified.id) {
                    return WallpaperLibraryService.normalizedFolderID(record.folderID) == folderID
                }
                return false
            }
            baseItems = filtered.map { AnyWallpaperItem(unified: $0) }
        }
        let filteredBaseItems: [AnyWallpaperItem]
        switch wallpaperRatioFilter {
        case .all:
            filteredBaseItems = baseItems
        case .landscape:
            filteredBaseItems = baseItems.filter { $0.wallpaper.dimensionX >= $0.wallpaper.dimensionY }
        case .portrait:
            filteredBaseItems = baseItems.filter { $0.wallpaper.dimensionX < $0.wallpaper.dimensionY }
        }
        wallpaperSearchBaseItems = filteredBaseItems
        wallpaperSearchEntries = filteredBaseItems.map(Self.makeWallpaperSearchEntry)
        wallpaperItems = filteredBaseItems
        if hasActiveLibrarySearch {
            let query = trimmedLibrarySearchQuery
            wallpaperItems = wallpaperItems.filter { matchesLibrarySearch(for: $0, query: query) }
        }
        // ⚡ prefetch 用的 ID→Index 缓存与 wallpaperItems 同步刷新
        var idMap: [String: Int] = [:]
        idMap.reserveCapacity(wallpaperItems.count)
        for (idx, item) in wallpaperItems.enumerated() { idMap[item.id] = idx }
        wallpaperIDIndexCache = idMap
        gridReloadToken &+= 1
        refreshWallpaperFolderDisplay()
        libraryCurrentPageIsBuilt = helper.librarySnapshotIsArrived
            && !viewModel.isLibraryCachePending
        syncSelectionWithVisibleItems()
        scheduleLibraryCoverBackfillIfNeeded()
    }

    private var orderedWallpaperGridItems: [LibraryGridEntry<AnyWallpaperItem>] {
        let entries = currentWallpaperFolders.map { LibraryGridEntry<AnyWallpaperItem>.folder($0) }
            + wallpaperItems.map { LibraryGridEntry<AnyWallpaperItem>.item($0) }
        return orderedGridEntries(entries)
    }

    /// 当前内容类型下可选中的项目总数（用于全选/取消全选判断）
    private var selectableItemCount: Int {
        switch selectedContentType {
        case .wallpaper:
            return wallpaperItems.count + currentWallpaperFolders.count
        }
    }

    private var currentWallpaperFolders: [LibraryFolder] {
        let collection: LibraryFolder.FolderCollection = selectedSubTab == .favorites ? .favorites : .downloads
        let folders = folderStore.folders(for: .wallpaper, parentID: currentWallpaperFolderID, collection: collection)
        guard hasActiveLibrarySearch else { return folders }
        let query = trimmedLibrarySearchQuery
        return folders.filter { matchesLibrarySearch(for: $0, query: query) }
    }

    /// 可添加到文件夹的壁纸（不在任何文件夹中的根目录壁纸）
    private var availableWallpapersForFolder: [(id: String, name: String, thumbURL: URL?, localFileURL: URL?)] {
        switch selectedSubTab {
        case .favorites:
            return WallpaperLibraryService.shared.favoriteWallpapers(inFolder: nil).map {
                (id: $0.id, name: $0.id, thumbURL: $0.thumbURL, localFileURL: nil)
            }
        case .downloads:
            let downloads = WallpaperLibraryService.shared.downloadedWallpapers(inFolder: nil)
            let scanned = viewModel.allLocalWallpapers.filter { $0.downloadRecord == nil }
            var result = downloads.map {
                (id: $0.wallpaper.id, name: $0.wallpaper.id, thumbURL: $0.wallpaper.thumbURL, localFileURL: $0.localFileURL)
            }
            for s in scanned {
                guard !result.contains(where: { $0.id == s.id }) else { continue }
                result.append((id: s.id, name: s.wallpaper.id, thumbURL: s.wallpaper.thumbURL, localFileURL: s.fileURL))
            }
            return result
        }
    }

    private func orderedGridEntries<Item>(_ entries: [LibraryGridEntry<Item>]) -> [LibraryGridEntry<Item>] {
        let orderedIDs = gridOrderStore.orderedIDs(for: entries.map(\.id), scope: currentGridOrderScope)
        let entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return orderedIDs.compactMap { entryByID[$0] }
    }

    private var currentGridOrderScope: LibraryGridOrderScope {
        LibraryGridOrderScope(
            content: .wallpaper,
            collection: selectedSubTab == .favorites ? .favorites : .downloads,
            parentFolderID: currentWallpaperFolderID
        )
    }

    private func startRenamingFolder(_ folder: LibraryFolder) {
        renameFolderName = folder.name
        renamingFolder = folder
    }

    @MainActor

    private var activeRatioFilter: WallpaperRatioFilter {
        wallpaperRatioFilter
    }

    /// 拖拽负载：选中项 + 被拖动的这一张。
    ///
    /// NSCollectionView 的鼠标按下本身就是一次选中操作（点击切换选中全靠它），
    /// 所以按下「已选中」的卡片时它会先被反选、从 `selectedItems` 掉出去；
    /// 负载若只认 `selectedItems`，「编辑 → 全选 → 拖拽」就退化成只拖一张。
    private func dragPayload(for itemID: String) -> String {
        let availableIDs = Set(currentItemIDs)
        var movingIDs = Array(selectedItems.lazy.filter { availableIDs.contains($0) })
        if availableIDs.contains(itemID), !movingIDs.contains(itemID) {
            movingIDs.append(itemID)
        }
        guard movingIDs.count > 1 else { return "waifux:item:\(itemID)" }
        return "waifux:items:\(movingIDs.sorted().joined(separator: "\n"))"
    }

    // MARK: - 拖拽反馈辅助

    /// 单条插入条 drop zone：贴在卡片左侧内缘，命中时显示一根蓝色指示条。
    /// 占用卡片左侧约 14pt 命中宽。不挡卡片其他区域的点击/hover。
    @ViewBuilder
    private func insertionDropZone(before entryID: String) -> some View {
        let isActive = hoveredInsertionID == entryID
        ZStack(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            Color.clear
                .frame(width: 14)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { payloads, _ in
                    handleGridReorderDrop(payloads, before: entryID)
                } isTargeted: { hovering in
                    if hovering {
                        hoveredInsertionID = entryID
                    } else if hoveredInsertionID == entryID {
                        hoveredInsertionID = nil
                    }
                }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    /// gridOrderStore 每次写入都会发布 revision。
    /// 本页拖拽排序自己写入的这一版：网格已经在动画里换好位置，不再整表重建两套列表
    /// （重建会在移动动画进行中重配所有可见卡片）。云同步等外部改动照常重建。
    private func handleGridOrderRevision(_ revision: Int) {
        if revision == expectedLocalGridOrderRevision {
            expectedLocalGridOrderRevision = -1
            return
        }
        debouncedUpdateWallpaperItems()
    }

    /// 处理排序 drop。
    /// - Parameter targetID: 插入到该 entry 之前；传 nil 表示插入到末尾。
    @discardableResult
    private func handleGridReorderDrop(_ payloads: [String], before targetID: String?) -> Bool {
        let orderedItemIDs = currentItemIDs
        let payloadIDs = Set(payloads.flatMap(parseDropPayload))
        // 按网格里的现有先后排列（负载里是按字符串排序的），多选拖动后保持原相对顺序。
        let movingIDs = orderedItemIDs.filter { payloadIDs.contains($0) }
        let movingSet = Set(movingIDs)
        AppLogger.debug(.grid, "[DragDiag] 排序落点", metadata: [
            "payloadStrings": payloads.count,
            "movingItems": movingIDs.count,
            "target": targetID ?? "<末尾>",
            "isEditing": isEditing
        ])
        guard !movingIDs.isEmpty else { return false }

        // 落点在被拖动的那一块里面（多选时最常见）：顺延到它后面第一张不在拖动集合里的卡片。
        var effectiveTargetID: String? = nil
        if let targetID {
            guard let targetIndex = orderedItemIDs.firstIndex(of: targetID) else { return false }
            effectiveTargetID = orderedItemIDs[targetIndex...].first { !movingSet.contains($0) }
        }

        var nextOrder = orderedItemIDs.filter { !movingSet.contains($0) }
        let insertIndex = effectiveTargetID.flatMap { nextOrder.firstIndex(of: $0) } ?? nextOrder.endIndex
        nextOrder.insert(contentsOf: movingIDs, at: insertIndex)
        // 放回原位：不写盘、不重建，卡片直接落回去。
        guard nextOrder != orderedItemIDs else {
            hoveredInsertionID = nil
            return true
        }

        let revisionBefore = gridOrderStore.revision
        expectedLocalGridOrderRevision = revisionBefore + 1
        gridOrderStore.reorder(
            moving: movingIDs,
            before: effectiveTargetID,
            availableIDs: orderedItemIDs,
            scope: currentGridOrderScope
        )
        guard gridOrderStore.revision != revisionBefore else {
            expectedLocalGridOrderRevision = -1
            return false
        }
        // 顺序在 body 里由 orderedGridEntries 实时套用，不需要重建列表；
        // 网格按 itemIdentifier 发现换序，用移动动画把卡片滑到新位置。
        gridReloadToken &+= 1
        hoveredInsertionID = nil
        return true
    }

    private func parseDropPayload(_ payload: String) -> [String] {
        if payload.hasPrefix("waifux:items:") {
            return String(payload.dropFirst(13))
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
        }
        if payload.hasPrefix("waifux:item:") {
            return [String(payload.dropFirst(12))]
        }
        return []
    }

    private func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - Image Preloading
    //
    // ⚡ 滚动时每个 grid item 的 .onAppear 都会调 preloadNearbyXxx；旧实现内部走
    // `firstIndex(where:)` 是 O(N)，大库（数千项）时每次滚动 mount 几十张就会做几十次
    // 全表扫描。改用 ID→Index 字典做 O(1) 查找。

    private func resumeLibraryPrefetchAfterScroll() {
        switch selectedContentType {
        case .wallpaper:
            let entries = orderedWallpaperGridItems
            guard let id = libraryScrollRuntimeState.lastWallpaperItemID,
                  let index = entries.firstIndex(where: { $0.id == id }) else { return }
            preloadNearbyWallpapers(in: entries, at: index)
        }
    }

    // MARK: - 封面后台预热

    /// 把当前列表里缺封面的条目交给 `LibraryCoverBackfillService` 后台补齐。
    ///
    /// 数据层（列表构建）只读已有缓存；真正缺封面时由这里一次性、限速地补，
    /// 而不是让每个 cell 在滚停后各自现场抽帧。服务内做去重、滚动门控与轮次上限。
    private func scheduleLibraryCoverBackfillIfNeeded() {
        coverBackfillDebounce?.cancel()
        coverBackfillDebounce = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_200_000_000)
            } catch {
                return
            }
            guard isVisible else { return }

            let wallpapers = wallpaperItems.map {
                LibraryCoverBackfillService.Candidate(
                    id: $0.id,
                    kind: .wallpaper,
                    localFileURL: $0.localFileURL
                )
            }

            LibraryCoverBackfillService.shared.schedule(wallpapers, reason: "library-grid")
        }
    }

    private func preloadNearbyWallpapers(
        in entries: [LibraryGridEntry<AnyWallpaperItem>], at index: Int
    ) {
        // 快速滚动时跳过预取/SSD 生成，避免与滚动抢 I/O 与主线程
        guard !LibraryScrollHoverGate.shared.isScrolling,
              entries.indices.contains(index) else { return }
        let bucket = prefetchBucket(for: index)
        guard lastWallpaperPrefetchBucket != bucket else { return }
        lastWallpaperPrefetchBucket = bucket

        // 与 LibraryWallpaperGridCell.coverImageOptions 同尺寸（384pt@2x = 768px），
        // 预热产物 processor identifier 必须与正式加载逐字一致才命中。
        let targetSize = CGSize(width: 384, height: 384)
        let range = prefetchRange(around: index, totalCount: entries.count)
        // 优先本机 SSD 列表缩略图 / 站点 thumb，绝不 prefetch 外置原图路径
        let urls = range
            .filter { $0 != index }
            .compactMap { idx -> URL? in
                guard case .item(let entry) = entries[idx] else { return nil }
                if let local = entry.localFileURL,
                   LocalImageThumbnailCache.isRasterImageFile(local),
                   let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
                    return cached
                }
                return entry.wallpaper.thumbURL ?? entry.wallpaper.smallThumbURL
            }

        ForegroundPrefetchManager.shared.stop(namespace: wallpaperPrefetchNamespace)
        ForegroundPrefetchManager.shared.start(
            urls: urls,
            options: [
                .processor(DownsamplingImageProcessor(size: targetSize)),
                .targetCache(LibraryCoverImageCache.imageCache)
            ],
            namespace: wallpaperPrefetchNamespace
        )

        // 后台为附近静图生成 SSD 缩略图；滚动中不启动，滚停后由卡片 ensure 补齐
        let nearbyLocals = range.compactMap { idx -> URL? in
            guard case .item(let entry) = entries[idx] else { return nil }
            return entry.localFileURL
        }
            .filter { LocalImageThumbnailCache.isRasterImageFile($0) }
        if !nearbyLocals.isEmpty {
            Task { @MainActor in
                guard !LibraryScrollHoverGate.shared.isScrolling else { return }
                for url in nearbyLocals.prefix(8) {
                    if LibraryScrollHoverGate.shared.isScrolling { return }
                    _ = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: url)
                }
            }
        }
    }

    private func prefetchBucket(for index: Int) -> Int {
        // 更粗的 bucket：减少滚动时 stop/start prefetcher 频率
        index / 8
    }

    private func prefetchRange(around index: Int, totalCount: Int) -> Range<Int> {
        // 收窄窗口：±5，降低 Kingfisher 与磁盘压力
        max(0, index - 5)..<min(totalCount, index + 6)
    }

    private func refreshWallpaperFolderDisplay() {
        let folders = currentWallpaperFolders
        guard !folders.isEmpty else {
            wallpaperFolderDisplay = [:]
            return
        }

        // ⚡ O(N) 预分组：按 folderID 建索引，避免对每个文件夹线性扫描全部记录。
        // 收藏/下载集合各自只读对应记录，避免跨集合污染封面与计数。
        var next: [String: FolderDisplayInfo] = [:]
        var warmupTargets: [(local: URL?, remote: URL?)] = []

        if selectedSubTab == .favorites {
            var favoriteByFolder: [String: [WallpaperFavoriteRecord]] = [:]
            for r in WallpaperLibraryService.shared.favoriteRecords where r.isActive {
                guard let fid = WallpaperLibraryService.normalizedFolderID(r.folderID) else { continue }
                favoriteByFolder[fid, default: []].append(r)
            }
            for folder in folders {
                let wallpapers = favoriteByFolder[folder.id, default: []].map(\.wallpaper)
                let preview = Self.wallpaperFolderPreviewURLs(from: wallpapers, localPathByID: [:])
                next[folder.id] = FolderDisplayInfo(
                    previewURLs: preview.urls,
                    itemCount: wallpapers.count
                )
                warmupTargets.append(contentsOf: preview.warmup)
            }
        } else {
            var downloadedByFolder: [String: [WallpaperDownloadRecord]] = [:]
            for r in WallpaperLibraryService.shared.downloadRecords where r.isActive {
                guard let fid = WallpaperLibraryService.normalizedFolderID(r.folderID) else { continue }
                downloadedByFolder[fid, default: []].append(r)
            }
            for folder in folders {
                let records = downloadedByFolder[folder.id, default: []]
                let wallpapers = records.map(\.wallpaper)
                var localPathByID: [String: URL] = [:]
                for r in records {
                    localPathByID[r.wallpaper.id] = r.localFileURL
                }
                let preview = Self.wallpaperFolderPreviewURLs(from: wallpapers, localPathByID: localPathByID)
                next[folder.id] = FolderDisplayInfo(
                    previewURLs: preview.urls,
                    itemCount: wallpapers.count
                )
                warmupTargets.append(contentsOf: preview.warmup)
            }
        }
        // 变化才写状态 + 递增 token：updateWallpaperItems 高频触发，
        // 无差别赋值 + 重配会让文件夹叠图反复 setImage（闪动来源）
        if next != wallpaperFolderDisplay {
            wallpaperFolderDisplay = next
            gridReloadToken &+= 1
        }
        scheduleWallpaperFolderPreviewWarmup(targets: warmupTargets)
    }

    /// 壁纸夹叠图：优先本机 SSD 列表小图 / 本地文件，再远程 thumb（避免夹外永远糊远程图）。
    private static func wallpaperFolderPreviewURLs(
        from wallpapers: [Wallpaper],
        localPathByID: [String: URL]
    ) -> (urls: [URL], warmup: [(local: URL?, remote: URL?)]) {
        var urls: [URL] = []
        var warmup: [(local: URL?, remote: URL?)] = []
        urls.reserveCapacity(3)
        for wallpaper in wallpapers.prefix(3) {
            let local = localPathByID[wallpaper.id]
                ?? WallpaperLibraryService.shared.localFileURLIfAvailable(for: wallpaper)
            let remote = wallpaper.thumbURL ?? wallpaper.smallThumbURL
            if let local, local.isFileURL {
                if LocalImageThumbnailCache.isRasterImageFile(local),
                   let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
                    urls.append(cached)
                    continue
                }
                // 无 SSD 小图：先远程占位，后台预热
                if let remote {
                    urls.append(remote)
                } else {
                    urls.append(local)
                }
                warmup.append((local, remote))
            } else if let remote {
                urls.append(remote)
            }
        }
        return (urls, warmup)
    }

    private func scheduleWallpaperFolderPreviewWarmup(targets: [(local: URL?, remote: URL?)]) {
        let needWarmup = targets.compactMap(\.local).filter { local in
            LocalImageThumbnailCache.isRasterImageFile(local)
                && LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) == nil
        }
        guard !needWarmup.isEmpty else { return }

        folderPreviewWarmupTask?.cancel()
        folderPreviewWarmupTask = Task { @MainActor in
            var any = false
            for url in needWarmup.prefix(12) {
                guard !Task.isCancelled else { return }
                if await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: url) != nil {
                    any = true
                }
            }
            guard any, !Task.isCancelled else { return }
            // 小图落盘后重算夹外预览，替换远程糊图
            refreshWallpaperFolderDisplayWithoutWarmup()
        }
    }

    /// 预热完成后刷新，避免递归再 schedule 同一批任务。
    private func refreshWallpaperFolderDisplayWithoutWarmup() {
        let folders = currentWallpaperFolders
        guard !folders.isEmpty else {
            wallpaperFolderDisplay = [:]
            return
        }
        var next: [String: FolderDisplayInfo] = [:]
        if selectedSubTab == .favorites {
            var favoriteByFolder: [String: [WallpaperFavoriteRecord]] = [:]
            for r in WallpaperLibraryService.shared.favoriteRecords where r.isActive {
                guard let fid = WallpaperLibraryService.normalizedFolderID(r.folderID) else { continue }
                favoriteByFolder[fid, default: []].append(r)
            }
            for folder in folders {
                let wallpapers = favoriteByFolder[folder.id, default: []].map(\.wallpaper)
                let preview = Self.wallpaperFolderPreviewURLs(from: wallpapers, localPathByID: [:])
                next[folder.id] = FolderDisplayInfo(previewURLs: preview.urls, itemCount: wallpapers.count)
            }
        } else {
            var downloadedByFolder: [String: [WallpaperDownloadRecord]] = [:]
            for r in WallpaperLibraryService.shared.downloadRecords where r.isActive {
                guard let fid = WallpaperLibraryService.normalizedFolderID(r.folderID) else { continue }
                downloadedByFolder[fid, default: []].append(r)
            }
            for folder in folders {
                let records = downloadedByFolder[folder.id, default: []]
                let wallpapers = records.map(\.wallpaper)
                var localPathByID: [String: URL] = [:]
                for r in records {
                    localPathByID[r.wallpaper.id] = r.localFileURL
                }
                let preview = Self.wallpaperFolderPreviewURLs(from: wallpapers, localPathByID: localPathByID)
                next[folder.id] = FolderDisplayInfo(previewURLs: preview.urls, itemCount: wallpapers.count)
            }
        }
        // 变化才写状态：updateWallpaperItems 高频触发，无差别赋值 + 递增 token
        // 会让可见 cell 反复 reconfigure（文件夹叠图重复 setImage → 闪动）
        if next != wallpaperFolderDisplay {
            wallpaperFolderDisplay = next
            gridReloadToken &+= 1
        }
    }

    /// 夹外叠图：后台为前若干项生成列表抽帧/静图小图，完成后刷新 display。

    /// 下载 tab：按番剧聚合的缓存组

    // MARK: - Section Header

    private func formatStat(_ count: Int) -> String {
        if count >= 10000 {
            return String(format: "%.1fw", Double(count) / 10000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    // MARK: - 添加到文件夹弹窗

    private var addToFolderSheetContent: some View {
        AddToFolderSheetView(
            contentType: selectedContentType,
            subTab: selectedSubTab,
            availableWallpapers: availableWallpapersForFolder,
                        onAdd: { selectedIDs in
                addSelectedItemsToFolder(ids: selectedIDs)
            },
            onDismiss: {
                showAddToFolderSheet = false
            }
        )
    }

    private func addSelectedItemsToFolder(ids: [String]) {
        switch selectedContentType {
        case .wallpaper:
            // 只允许在已进入某个文件夹时添加；根目录没有目标 folderID
            if let folderID = currentWallpaperFolderID {
                moveWallpapersToFolder(ids: ids, folderID: folderID)
            }
        }
        showAddToFolderSheet = false
    }

    private var librarySearchControl: some View {
        HStack(spacing: 0) {
            if isLibrarySearchExpanded {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))

                    TextField(t("search.placeholder"), text: $librarySearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .focused($isLibrarySearchFocused)
                        .onSubmit {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isLibrarySearchExpanded = false
                            }
                        }
                        .onExitCommand {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isLibrarySearchExpanded = false
                            }
                        }

                    if !librarySearchQuery.isEmpty {
                        Button {
                            librarySearchQuery = ""
                            // 清空后自动收起
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isLibrarySearchExpanded = false
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: 240)
                .frame(height: 42)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isLibrarySearchExpanded = true
                        isLibrarySearchFocused = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .liquidGlassSurface(.regular, in: Capsule(style: .continuous), lightweight: true)
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: isLibrarySearchExpanded)
        .guideAnchor(.librarySearchControl)
        .onChange(of: isLibrarySearchFocused) { _, focused in
            if !focused {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isLibrarySearchExpanded = false
                }
            }
        }
    }

    private func libraryToolbarActions(tint: Color) -> some View {
        HStack(spacing: 8) {
            // 编辑模式下：全选 + 删除 放在完成左边
            if isEditing {
                let totalCount = selectableItemCount
                // 全选/取消全选
                Button {
                    toggleSelectAll()
                } label: {
                    Text(selectedItems.count == totalCount ? t("deselect.all") : t("select.all"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.regularMaterial)
                                .opacity(0.5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                // 删除按钮
                Button {
                    deleteSelectedItems()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(t("delete")) (\(selectedItems.count))")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.red.opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.red.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(selectedItems.isEmpty)
                .opacity(selectedItems.isEmpty ? 0.5 : 1)
            }

            toolbarCapsuleButton(
                title: isEditing ? t("done") : t("edit"),
                systemImage: isEditing ? "checkmark.circle.fill" : "checkmark.circle",
                tint: tint,
                prominence: isEditing ? .primary : .secondary
            ) {
                withAnimation {
                    isEditing.toggle()
                    selectedItems.removeAll()
                }
            }
            .guideAnchor(.libraryEditButton)

                toolbarCapsuleButton(
                    title: t("new.folder"),
                    systemImage: "folder.badge.plus",
                    tint: tint,
                    prominence: .secondary
                ) {
                    showNewFolderSheet = true
                }

            libraryUtilityMenu(tint: tint)
        }
    }

    private var subTabDropdown: some View {
        Menu {
            ForEach(SubTab.allCases, id: \.self) { tab in
                Button(tab.title) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedSubTab = tab
                        isEditing = false
                        selectedItems.removeAll()
                    }
                }
            }
        } label: {
            Text(selectedSubTab.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .liquidGlassSurface(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous), lightweight: true)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .pointingHandCursor()
    }

    private func wallpaperRatioPicker(color: Color) -> some View {
        HStack(spacing: 0) {
            ForEach(WallpaperRatioFilter.allCases, id: \.self) { filter in
                Button {
                    wallpaperRatioFilter = filter
                    isEditing = false
                    selectedItems.removeAll()
                } label: {
                    Text(filter.title)
                        .font(.system(size: 12, weight: activeRatioFilter == filter ? .semibold : .medium))
                        .foregroundStyle(activeRatioFilter == filter ? .white : .white.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(activeRatioFilter == filter ? color.opacity(0.35) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .liquidGlassSurface(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous), lightweight: true)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func libraryUtilityMenu(tint: Color) -> some View {
        let hasMenuItems = selectedSubTab == .downloads

        if hasMenuItems {
            Menu {
                if selectedSubTab == .downloads {
                    switch selectedContentType {
                    case .wallpaper:
                        Button {
                            openFolderInFinder(DownloadPathManager.shared.wallpapersFolderURL)
                        } label: {
                            Label(t("open.in.finder"), systemImage: "folder")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.84))
                    .frame(width: 36, height: 36)
                    .liquidGlassSurface(.regular, in: Circle(), lightweight: true)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
            }
            .guideAnchor(.libraryMoreMenuButton)
            .menuStyle(.borderlessButton)
            .pointingHandCursor()
        }
    }

    private enum ToolbarButtonProminence {
        case primary
        case secondary
    }

    private func toolbarCapsuleButton(
        title: String,
        systemImage: String,
        tint: Color,
        prominence: ToolbarButtonProminence,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Group {
                    if prominence == .primary {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tint.opacity(0.3))
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.regularMaterial)
                            .opacity(0.5)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(prominence == .primary ? tint.opacity(0.24) : Color.white.opacity(0.15), lineWidth: 1)
                )
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - 文件夹面包屑
    @ViewBuilder
    private func folderBreadcrumb(
        folderStack: [String],
        isInFolder: Bool,
        onBack: @escaping () -> Void,
        onRoot: @escaping () -> Void,
        onAdd: @escaping () -> Void
    ) -> some View {
        if isInFolder {
            HStack(spacing: 6) {
                Button(action: onRoot) {
                    Image(systemName: "house")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                if !folderStack.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))

                    Text("...")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }

                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 10))
                        Text(t("back"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.regularMaterial)
                            .opacity(0.4)
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Spacer()

                Button(action: onAdd) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text(t("add"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.regularMaterial)
                            .opacity(0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - 首屏加载占位

    /// 与真实网格同列数、同卡片比例的骨架；数据到位替换成网格时不跳版。
    private func libraryGridLoadingPlaceholder(config: LibraryGridConfig) -> some View {
        let cardHeight = config.cardWidth
            / LibraryGridCellMetrics.cardAspectRatio(columnWidth: config.cardWidth)
        return LazyVGrid(columns: config.gridItems, alignment: .leading, spacing: config.spacing) {
            ForEach(0..<(config.columnCount * 3), id: \.self) { _ in
                SkeletonCard(
                    width: config.cardWidth,
                    height: cardHeight,
                    cornerRadius: LibraryGridCellMetrics.cornerRadius
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Empty State
    private func emptyLibrarySurface(title: String, subtitle: String, icon: String, accent: Color) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(accent.opacity(0.8))

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Actions

    /// 解锁状态在点击时重查；目录重配前的旧封面不能成为仍锁定内容的转场 seed。
    private func libraryCardTransitionContentIsUnlocked(
        folderID: String?,
        contentType: LibraryFolder.FolderContentType
    ) -> Bool {
        var nextFolderID = folderID
        var visited = Set<String>()
        while let id = nextFolderID {
            guard visited.insert(id).inserted,
                  let folder = folderStore.folder(withID: id, contentType: contentType),
                  !folder.isLocked || FolderLockService.shared.isFolderUnlocked(id) else { return false }
            nextFolderID = folder.parentFolderID
        }
        return true
    }

    private func handleWallpaperTap(_ wallpaper: Wallpaper) {
        if isEditing {
            toggleSelection(wallpaper.id)
        } else {
            savedLibraryScrollOffset = libraryScrollRuntimeState.currentOffset
            wallpaperContext = wallpaperItems.map(\.wallpaper)
            selectedWallpaper = wallpaper
        }
    }

    private func handleFolderTap(_ folder: LibraryFolder) {
        if isEditing {
            toggleSelection("folder_\(folder.id)")
            return
        }

        // 加密文件夹需要认证
        if folder.isLocked {
            let lockService = FolderLockService.shared
            if !lockService.isFolderUnlocked(folder.id) {
                Task { @MainActor in
                    let reason = String(format: t("folder.unlockReason"), folder.name)
                    let success = await lockService.unlockFolder(folderID: folder.id, reason: reason)
                    if success {
                        navigateToFolder(folder)
                    }
                }
                return
            }
        }

        navigateToFolder(folder)
    }

    private func navigateToFolder(_ folder: LibraryFolder) {
        switch folder.contentType {
        case .wallpaper:
            navigateToWallpaperFolder(folder.id)
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedItems.contains(id) {
            selectedItems.remove(id)
        } else {
            selectedItems.insert(id)
        }
    }

    private func toggleSelectAll() {
        let allIDs = Set(currentItemIDs)
        selectedItems = selectedItems.count == allIDs.count ? [] : allIDs
    }

    private func syncSelectionWithVisibleItems() {
        guard isEditing else { return }
        selectedItems = selectedItems.intersection(Set(currentItemIDs))
    }

    private var currentItemIDs: [String] {
        switch selectedContentType {
        case .wallpaper:
            return orderedWallpaperGridItems.map(\.id)
        }
    }

    private func deleteSelectedItems() {
        let removedOrderIDs = selectedItems
        // 分离文件夹 ID 和普通项目 ID
        let folderIDs = selectedItems.filter { $0.hasPrefix("folder_") }
        let itemIDs = selectedItems.filter { !$0.hasPrefix("folder_") }

        // 先删除文件夹
        for folderID in folderIDs {
            let realID = String(folderID.dropFirst(7))
            switch selectedContentType {
            case .wallpaper:
                folderStore.deleteFolder(id: realID, contentType: .wallpaper)
            }
        }

        // 再删除普通项目
        switch selectedContentType {
        case .wallpaper:
            if selectedSubTab == .favorites {
                let favoriteIDs = Set(viewModel.favorites.map(\.id))
                let ids = itemIDs.intersection(favoriteIDs)
                if !ids.isEmpty {
                    viewModel.removeWallpaperFavorites(withIDs: ids)
                }
            } else {
                let allLocal = viewModel.allLocalWallpapers
                let ids = itemIDs.intersection(Set(allLocal.map(\.id)))
                if !ids.isEmpty {
                    deleteLocalWallpapers(allLocal.filter { ids.contains($0.id) })
                }
            }

        }

            gridOrderStore.removeIDs(removedOrderIDs, from: currentGridOrderScope)

        selectedItems.removeAll()
        isEditing = false
        rebuildCurrentLibraryLists(reason: "bulk-action")
    }

    private func deleteWallpaperItem(_ item: AnyWallpaperItem) {
        if selectedSubTab == .favorites {
            viewModel.removeWallpaperFavorites(withIDs: [item.id])
        } else {
            _ = viewModel.deleteLocalWallpaper(item.wallpaper)
        }
        gridOrderStore.removeIDs([item.id], from: currentGridOrderScope)
        updateWallpaperItems()
    }

    /// 删除文件夹及其所有内容（包括子文件夹中的项目）
    private func deleteFolderWithContents(folderID: String, contentType: LibraryFolder.FolderContentType) {
        // 收集该文件夹及所有子文件夹的 ID
        var allFolderIDs = [folderID]
        var visited = Set([folderID])
        func collectSubfolders(_ parentID: String) {
            let children = folderStore.subfolders(of: parentID, contentType: contentType)
            for child in children where visited.insert(child.id).inserted {
                allFolderIDs.append(child.id)
                collectSubfolders(child.id)
            }
        }
        collectSubfolders(folderID)

        // 收集所有项目 ID 并删除
        var allItemIDs = Set<String>()

            for fid in allFolderIDs {
                let favs = WallpaperLibraryService.shared.favoriteWallpapers(inFolder: fid)
                allItemIDs.formUnion(favs.map(\.id))
                let dls = WallpaperLibraryService.shared.downloadedWallpapers(inFolder: fid)
                allItemIDs.formUnion(dls.map(\.wallpaper.id))
            }
            // 删除项目
            if selectedSubTab == .favorites {
                let favIDs = Set(viewModel.favorites.map(\.id)).intersection(allItemIDs)
                if !favIDs.isEmpty { viewModel.removeWallpaperFavorites(withIDs: favIDs) }
            } else {
                let allLocal = viewModel.allLocalWallpapers.filter { allItemIDs.contains($0.id) }
                if !allLocal.isEmpty { deleteLocalWallpapers(allLocal) }
            }

        // 删除文件夹本身
        folderStore.deleteFolder(id: folderID, contentType: contentType)
        gridOrderStore.removeIDs(["folder_\(folderID)"], from: currentGridOrderScope)
        rebuildCurrentLibraryLists(reason: "bulk-action")
    }

    /// 单个库内壁纸重新下载：保留原文件夹归属（若有），先入队再删旧文件。

    /// 先持久化下载队列，再清优化状态与旧文件，最后启动传输。

    private func matchesLibrarySearch(for folder: LibraryFolder, query: String) -> Bool {
        folder.name.localizedCaseInsensitiveContains(query)
    }

    private static func makeWallpaperSearchEntry(_ item: AnyWallpaperItem) -> LibrarySearchEntry {
        let wallpaper = item.wallpaper
        let directMatches = [
            item.localFileURL?.deletingPathExtension().lastPathComponent,
            wallpaper.id,
            wallpaper.title,
            wallpaper.category,
            wallpaper.categoryDisplayName,
            wallpaper.purity,
            wallpaper.purityDisplayName,
            wallpaper.effectiveResolutionLabel,
            wallpaper.ratio,
            wallpaper.source,
            wallpaper.uploader?.username,
            wallpaper.primaryTagName
        ]
        let tags = wallpaper.tags?.flatMap { [$0.name, $0.alias] } ?? []
        return LibrarySearchEntry(
            id: item.id,
            searchableText: (directMatches + tags).compactMap { $0 }.joined(separator: "\u{1F}").localizedLowercase
        )
    }

    private func matchesLibrarySearch(for item: AnyWallpaperItem, query: String) -> Bool {
        let wallpaper = item.wallpaper
        let directMatches = [
            item.localFileURL?.deletingPathExtension().lastPathComponent,
            wallpaper.id,
            wallpaper.title,
            wallpaper.category,
            wallpaper.categoryDisplayName,
            wallpaper.purity,
            wallpaper.purityDisplayName,
            wallpaper.effectiveResolutionLabel,
            wallpaper.ratio,
            wallpaper.source,
            wallpaper.uploader?.username,
            wallpaper.primaryTagName
        ]
        if directMatches.contains(where: { $0?.localizedCaseInsensitiveContains(query) == true }) {
            return true
        }
        return wallpaper.tags?.contains(where: {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.alias?.localizedCaseInsensitiveContains(query) ?? false)
        }) ?? false
    }

    /// 删除本地壁纸（含物理文件删除）
    private func deleteLocalWallpapers(_ items: [UnifiedLocalWallpaper]) {
        let fileManager = FileManager.default

        for item in items {
            if let record = item.downloadRecord {
                viewModel.removeWallpaperDownloads(withIDs: [record.wallpaper.id])
            }
            let filePath = item.fileURL.path
            if fileManager.fileExists(atPath: filePath) {
                do {
                    try fileManager.removeItem(atPath: filePath)
                    print("[MyLibrary] ✅ Deleted file: \(filePath)")
                } catch {
                    print("[MyLibrary] ❌ Failed to delete file \(filePath): \(error)")
                }
            }
        }

        viewModel.loadFavorites()
    }

    // MARK: - Grid Config
    private struct LibraryGridConfig {
        let columnCount: Int
        let spacing: CGFloat
        let cardWidth: CGFloat
        let contentWidth: CGFloat
        let gridItems: [GridItem]

        init(contentWidth: CGFloat) {
            self.contentWidth = contentWidth
            self.columnCount = contentWidth > 1200 ? 4 : (contentWidth > 800 ? 3 : 2)
            self.spacing = 16
            let totalSpacing = spacing * CGFloat(columnCount - 1)
            self.cardWidth = floor((contentWidth - totalSpacing) / CGFloat(columnCount))
            self.gridItems = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: columnCount)
        }
    }

    @ViewBuilder
    private func libraryWaterfallGrid<Item: Identifiable, Content: View>(
        entries: [Item],
        config: LibraryGridConfig,
        estimatedHeight: CGFloat,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        // ⚡ 库卡片高度是统一的（LibraryCardMetrics.thumbnailHeight = 180 + 元数据栏），
        // 不需要瀑布流。改用 LazyVGrid 替代 `HStack { LazyVStack × N }` 的多列模式
        // ——后者在 macOS 上会让所有列在每帧滚动期间反复同步对齐，是已知 hitch 来源。
        LazyVGrid(columns: config.gridItems, alignment: .leading, spacing: config.spacing) {
            ForEach(entries) { item in
                content(item)
            }
        }
    }

    // MARK: - Import & Folder
    private func openFolderInFinder(_ url: URL) {
        DownloadPathManager.shared.createDirectoryStructure()
        NSWorkspace.shared.open(url)
    }

    /// 获取用户订阅列表（已过滤已下载），展示选择 Sheet

    /// 下载用户勾选的订阅项

    /// 网页爬取/网页登录对同步与下载都无效，已移除回退）。

    // MARK: - 全部更新（Wallpaper Engine 数据）

    /// 重下有更新的项（与详情页单条「更新壁纸」共用 ViewModel 链路）。

}

// MARK: - 库视图氛围背景（独立观察 ArcBackgroundSettings）
/// 从 MyLibraryContentView 下沉而来：自行观察 ArcBackgroundSettings，
/// 外观设置（点阵/噪点/颗粒度）变化时只重建本背景，不触发整个库视图 body 重算。
private struct LibraryAtmosphereBackground: View {
    let tint: ExploreAtmosphereTint
    @ObservedObject private var arcSettings = ArcBackgroundSettings.shared

    var body: some View {
        ArcAtmosphereBackground(
            tint: tint,
            referenceImage: nil,
            isLightMode: false,
            dotGridOpacity: arcSettings.dotGridOpacity,
            useNoise: arcSettings.useNoiseTexture,
            grainIntensity: arcSettings.grainIntensity,
            lightweight: true
        )
    }
}

// MARK: - Content Type Picker
struct ContentTypePicker: View {
    @Binding var selected: ContentType

    @Namespace private var selectionNamespace
    @State private var hoveredType: ContentType?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ContentType.allCases, id: \.self) { type in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selected = type
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: type.icon)
                            .font(.system(size: 13, weight: .semibold))

                        Text(type.displayName)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(labelColor(for: type))
                    .frame(minWidth: 86, minHeight: 32)
                    .padding(.horizontal, 10)
                    .background {
                        if selected == type {
                            selectedTypeGlass
                        } else if hoveredType == type {
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.1))
                        }
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Capsule(style: .continuous))
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.16)) {
                        hoveredType = hovering ? type : (hoveredType == type ? nil : hoveredType)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .liquidGlassSurface(.regular, in: Capsule(style: .continuous))
    }

    private func labelColor(for type: ContentType) -> Color {
        if selected == type {
            return .white.opacity(0.96)
        }
        if hoveredType == type {
            return .white.opacity(0.86)
        }
        return .white.opacity(0.72)
    }

    @ViewBuilder
    private var selectedTypeGlass: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(0.12))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.34),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .matchedGeometryEffect(id: "libraryContentTypeGlass", in: selectionNamespace)
    }
}

// MARK: - AnyWallpaperItem (统一封装用于 ForEach)
private struct AnyWallpaperItem: Identifiable {
    let id: String
    let wallpaper: Wallpaper
    let localFileURL: URL?
    let downloadDate: Date?

    init(wallpaper: Wallpaper, localFileURL: URL? = nil) {
        self.id = wallpaper.id
        self.wallpaper = wallpaper
        self.localFileURL = localFileURL
        self.downloadDate = nil
    }

    init(unified: UnifiedLocalWallpaper) {
        self.id = unified.id
        self.wallpaper = unified.wallpaper
        self.localFileURL = unified.fileURL
        self.downloadDate = unified.downloadRecord?.downloadedAt
    }
}

private enum LibraryGridEntry<Item: Identifiable>: Identifiable where Item.ID == String {
    case folder(LibraryFolder)
    case item(Item)

    var id: String {
        switch self {
        case .folder(let folder):
            return "folder_\(folder.id)"
        case .item(let item):
            return item.id
        }
    }

    var isFolderEntry: Bool {
        if case .folder = self {
            return true
        }
        return false
    }
}

// MARK: - Cursor Extension
private extension View {
    func pointingHandCursor() -> some View {
        self.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

import AppKit
import Kingfisher

// MARK: - 我的库网格 cell 公共定义
//
// 2026-09 我的库网格从 SwiftUI ScrollView + LazyVGrid 迁到 ExploreGridContainer
// （NSCollectionView 自滚动 + cell 真复用），视觉与交互 1:1 对齐旧 SwiftUI 卡片：
// - WallpaperEditCard → LibraryWallpaperGridCell
// - LibraryFolderCard → LibraryFolderGridCell（叠图 + 中央 drop 区 + 加密锁态）
// 旧 SwiftUI 卡片组件保留不删，探索页/其他场景仍可复用。

// MARK: - 库封面专用缓存

/// 「我的库」网格封面专用缓存层。
///
/// 详情页 hero 大图（单张解码后 20-30MB）与探索页缩略图共享 `ImageCache.default` 时，
/// 进一次详情就会按 LRU 把整屏网格封面挤出内存池（全局内存缓存仅 128MB / 5 分钟过期），
/// 返回网格后所有封面只能逐张走磁盘解码，观感等同无缓存。这里做两层隔离：
/// 1. `imageCache`：独立 Kingfisher 缓存（内存 30 分钟过期），库 cell 的 kf.setImage
///    走 `.targetCache`，详情页大图不再挤掉库封面，内存条目也不再 5 分钟蒸发；
/// 2. `snapshotCache`：itemID → 已处理 NSImage 的进程级快照。详情往返会拆掉重建
///    AppKit 网格（这也是点击卡片时要保存/恢复滚动偏移的原因），新 cell 的
///    coverImageView 从 nil 起步；configure 时同步回填快照，即使 Kingfisher 异步
///    链路再慢也不会出现空白闪烁。
enum LibraryCoverImageCache {
    static let imageCache: ImageCache = {
        let cache = WallpaperImageCache.make(name: "library-covers")
        // 中间帧出图 768px（384pt@2x，≈2.3MB/张）：512px 在 Retina 网格卡上实测偏糊。
        // 256MB 可驻约 108 张（滚动往返不驱逐重载）。处理器 identifier 含尺寸，
        // 旧尺寸条目自然失效，无需迁移。
        cache.memoryStorage.config.totalCostLimit = 256 * 1024 * 1024 // 256MB
        cache.memoryStorage.config.countLimit = 800
        cache.memoryStorage.config.expiration = .seconds(30 * 60)    // 30 min
        cache.memoryStorage.config.cleanInterval = 60
        // 磁盘独立小缓存：512 降采样 JPEG 体积很小；远程 thumb 首次迁移会重下一次。
        cache.diskStorage.config.sizeLimit = 500 * 1024 * 1024
        cache.diskStorage.config.expiration = .days(30)
        return cache
    }()

    /// NSCache 本身线程安全；Swift 6 严格并发下用 nonisolated(unsafe) 标注
    /// 表示我们依赖 NSCache 的内部锁而不是编译器保护。
    private nonisolated(unsafe) static let snapshotCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 800
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    static func snapshot(forKey key: String) -> NSImage? {
        snapshotCache.object(forKey: key as NSString)
    }

    static func storeSnapshot(_ image: NSImage, forKey key: String) {
        guard let rep = image.representations.max(
            by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        ) else { return }
        snapshotCache.setObject(image, forKey: key as NSString, cost: rep.pixelsWide * rep.pixelsHigh * 4)
    }

    // MARK: - 竖卡模糊底

    /// 竖图卡片的模糊填充底：同一张封面的超小模糊副本（48px 长边一次高斯模糊，放大铺满）。
    /// 走「预生成 + 缓存」而不是给图层挂 CIFilter —— 滚动时零滤镜合成成本。
    private nonisolated(unsafe) static let blurredSnapshotCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func blurredSnapshot(forKey key: String) -> NSImage? {
        blurredSnapshotCache.object(forKey: key as NSString)
    }

    static func storeBlurredSnapshot(_ image: NSImage, forKey key: String) {
        blurredSnapshotCache.setObject(image, forKey: key as NSString)
    }

    /// 共享 CIContext：每次新建要 10ms 以上，共享后单张 48px 模糊只剩 1–3ms。
    private nonisolated(unsafe) static let blurContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 把图缩到 48px 长边再模糊，成本与原始尺寸无关。
    nonisolated static func makeBlurredSnapshot(from image: NSImage) -> NSImage? {
        guard let cgSource = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cgSource)
        let longest = max(input.extent.width, input.extent.height)
        guard longest > 0 else { return nil }

        let scale = 48 / longest
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(small, forKey: kCIInputImageKey)
        blur.setValue(6, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage?.cropped(to: small.extent) else { return nil }

        let context = Self.blurContext
        guard let cgImage = context.createCGImage(output, from: small.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// 我的库卡片统一布局度量（与 LibraryCardMetrics 对齐）
enum LibraryGridCellMetrics {
    /// 封面区固定高度（thumb）
    static let thumbHeight: CGFloat = 180
    /// 底部信息栏高度（壁纸/媒体/文件夹通用）
    static let infoBarHeight: CGFloat = 44
    /// 卡片外圆角
    static let cornerRadius: CGFloat = 22
    /// 卡片底色
    static let cardBackground = NSColor(calibratedRed: 26.0/255, green: 29.0/255, blue: 36.0/255, alpha: 1)
    /// 动漫底部信息栏
    static let animeInfoBarHeight: CGFloat = 52

    /// 壁纸/媒体/文件夹卡的整卡宽高比（含信息栏）
    static func cardAspectRatio(columnWidth: CGFloat) -> CGFloat {
        guard columnWidth > 0 else { return 1.2 }
        return columnWidth / (thumbHeight + infoBarHeight)
    }

    /// 动漫卡整卡宽高比（10:14 封面 + 52pt 信息栏）
    static func animeAspectRatio(columnWidth: CGFloat) -> CGFloat {
        guard columnWidth > 0 else { return 0.7 }
        return columnWidth / (columnWidth * 1.4 + animeInfoBarHeight)
    }
}

// MARK: - 右键菜单负载

/// 我的库 cell 右键菜单条目（SwiftUI 侧构建，cell 转 NSMenu）
enum LibraryGridMenuEntry {
    case divider
    case item(title: String, icon: String?, destructive: Bool, handler: () -> Void)
    case submenu(title: String, icon: String?, entries: [LibraryGridMenuEntry])
}

/// NSMenuItem.target 是 weak 引用，用小对象包住 handler 并由 cell 持有存活。
final class LibraryMenuActionTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc func performAction() {
        handler()
    }
}

/// 我的库卡片强调色（与 LiquidGlassColors 同源 hex；AppKit cell 侧使用）
enum LibraryGridAccent {
    static let pink = NSColor(srgbRed: 1.0, green: 51 / 255.0, blue: 102 / 255.0, alpha: 1)      // FF3366
    static let cyan = NSColor(srgbRed: 0, green: 212 / 255.0, blue: 1, alpha: 1)                 // 00D4FF
    static let violet = NSColor(srgbRed: 139 / 255.0, green: 92 / 255.0, blue: 246 / 255.0, alpha: 1) // 8B5CF6
}

/// 我的库拖拽负载解析（与旧 SwiftUI 卡片的 "waifux:item:" / "waifux:items:" 协议一致）
enum LibraryDragPayload {
    static func ids(from strings: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for payload in strings {
            let parsed: [String]
            if payload.hasPrefix("waifux:items:") {
                parsed = String(payload.dropFirst(13))
                    .split(separator: "\n")
                    .map(String.init)
                    .filter { !$0.isEmpty }
            } else if payload.hasPrefix("waifux:item:") {
                parsed = [String(payload.dropFirst(12))]
            } else {
                parsed = []
            }
            for id in parsed where seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    static func ids(fromPasteboard pasteboard: NSPasteboard) -> [String] {
        var strings: [String] = []
        if let objects = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String] {
            strings = objects
        } else if let single = pasteboard.string(forType: .string) {
            strings = [single]
        }
        return ids(from: strings)
    }
}

// MARK: - Cell 配置模型

struct LibraryWallpaperCellModel {
    let wallpaper: Wallpaper
    let localFileURL: URL?
    let isEditing: Bool
    let isSelected: Bool
    let isCurrentWallpaper: Bool
    let accent: NSColor
    /// （fileExists + 最多 8 层 project.json 读取），不能进 configureCell 滚动热路径。
    let makeMenuEntries: () -> [LibraryGridMenuEntry]
    /// 点击与返回重新解析锚点时都核实祖先目录锁态。
    var isCardTransitionAllowed: (() -> Bool)? = nil
}

struct LibraryFolderCellModel {
    let folder: LibraryFolder
    let previewURLs: [URL]
    let itemCount: Int
    let isUnlocked: Bool
    let menuEntries: [LibraryGridMenuEntry]
    let onDrop: ([String]) -> Void
    let onRelock: () -> Void
}

// MARK: - 共享子视图

/// 胶囊元信息标签（monospaced 10 bold，黑底 0.3，高 20）
final class LibraryCapsuleBadgeView: NSView {
    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        label.textColor = NSColor.white.withAlphaComponent(0.82)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        layer?.cornerRadius = 10
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var preferredSize: CGSize {
        guard !label.stringValue.isEmpty else { return .zero }
        let textSize = label.fittingSize
        guard textSize.width.isFinite, textSize.width > 0 else { return .zero }
        return CGSize(
            width: ceil(textSize.width + 8 * 2),
            height: 20
        )
    }

    func configure(text: String?) {
        label.stringValue = text ?? ""
        isHidden = label.stringValue.isEmpty
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else {
            label.frame = .zero
            return
        }
        let textSize = label.fittingSize
        label.frame = CGRect(
            x: 8,
            y: floor((bounds.height - textSize.height) / 2),
            width: max(0, bounds.width - 16),
            height: max(textSize.height, 1)
        ).integral
    }
}

/// 「当前壁纸使用中」绿色胶囊（checkmark.circle.fill + 文案）
final class LibraryCurrentWallpaperBadgeView: NSView {
    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = NSColor.white.withAlphaComponent(0.95)
        return label
    }()

    private let iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = NSColor.white.withAlphaComponent(0.95)
        return view
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 52.0/255, green: 211.0/255, blue: 153.0/255, alpha: 1).withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 11
        iconView.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        addSubview(iconView)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String) {
        label.stringValue = text
        needsLayout = true
    }

    var preferredSize: CGSize {
        let textSize = label.fittingSize
        // 左右各 8 + 12pt 图标 + 图标与文字 4pt；旧计算少了 6pt，
        // 中文“正在使用”会在胶囊右侧被裁掉。
        return CGSize(width: ceil(8 + 12 + 4 + textSize.width + 8), height: 22)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        iconView.frame = CGRect(x: 8, y: 5, width: 12, height: 12)
        let textSize = label.fittingSize
        label.frame = CGRect(
            x: iconView.frame.maxX + 4,
            y: floor((bounds.height - textSize.height) / 2),
            width: max(0, bounds.width - iconView.frame.maxX - 4 - 8),
            height: max(textSize.height, 1)
        ).integral
    }
}

/// 编辑态左上角复选框
final class LibraryEditCheckboxView: NSView {
    private let iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }()

    private let circleBackground: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        return view
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(circleBackground)
        addSubview(iconView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(isSelected: Bool, accent: NSColor) {
        let symbolName = isSelected ? "checkmark.circle.fill" : "circle"
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
        iconView.contentTintColor = isSelected ? accent : NSColor.white.withAlphaComponent(0.8)
        circleBackground.layer?.backgroundColor = (
            isSelected ? NSColor.white : NSColor.black.withAlphaComponent(0.4)
        ).cgColor
    }

    override func layout() {
        super.layout()
        circleBackground.frame = CGRect(x: 1, y: 1, width: 20, height: 20)
        iconView.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
    }
}

// MARK: - 库转场可见性

/// 独立封面管线只登记实际显示的原图；模糊/保护层存在时不提供 seed。
@MainActor
private func libraryCardTransitionCoverIsUnfiltered(_ cell: ExploreGridItem) -> Bool {
    guard cell.isViewLoaded else { return false }
    var ancestor: NSView? = cell.coverImageView
    while let current = ancestor {
        guard current.layer?.filters?.isEmpty != false else { return false }
        ancestor = current.superview
    }
    return true
}

// MARK: - 壁纸卡 Cell

/// 还原 WallpaperEditCard 视觉：180pt 封面 + 44pt 信息栏（作者 + heart/eye/file 统计）
final class LibraryWallpaperGridCell: ExploreGridItem {
    static let newReuseIdentifier = NSUserInterfaceItemIdentifier("LibraryWallpaperGridCell")
    override class var gridReuseIdentifier: NSUserInterfaceItemIdentifier { newReuseIdentifier }

    private enum Layout {
        static let infoBarHeight = LibraryGridCellMetrics.infoBarHeight
        static let cornerRadius = LibraryGridCellMetrics.cornerRadius
        static let overlayPadding: CGFloat = 12
        static let horizontalPadding: CGFloat = 14
        static let verticalPadding: CGFloat = 12
    }

    private var currentModel: LibraryWallpaperCellModel?
    private var menuActionTargets: [LibraryMenuActionTarget] = []

    /// 本地静图 SSD 列表缩略图（生成后替换远程封面）
    private var localThumbEnsureTask: Task<Void, Never>?
    private var localThumbIdleToken: UUID?
    /// `.equatable()` 旧卡片不会在数据未变时重新挂载 KFImage；AppKit cell
    /// 需要自己记住当前源，避免详情返回/状态刷新时重复 setImage 造成闪屏。
    private var coverSourceKey: String?
    private var coverLoadGeneration = 0
    private var coverRetryCount = 0
    private var coverRetrySourceKey: String?
    private var coverRetryTask: Task<Void, Never>?

    private let bottomBar: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.cgColor
        return view
    }()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

    private let heartStat = LibraryStatLabelView()
    private let eyeStat = LibraryStatLabelView()
    private let fileStat = LibraryStatLabelView()

    private let categoryBadge = LibraryCapsuleBadgeView()
    private let purityBadge = LibraryCapsuleBadgeView()
    private let resolutionBadge = LibraryCapsuleBadgeView()
    private let checkboxView = LibraryEditCheckboxView()
    private let selectionMask: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        return view
    }()
    private let currentBadge = LibraryCurrentWallpaperBadgeView()

    override var hoverScaleFactor: CGFloat { 1.01 }
    override var shouldAnimateBorderOnHover: Bool { true }
    override var allowsHoverInteraction: Bool { currentModel?.isEditing != true }

    override var cardTransitionItemID: String? {
        guard let model = currentModel, !model.isEditing,
              model.isCardTransitionAllowed?() != false else { return nil }
        return model.wallpaper.id
    }

    override func cardTransitionSnapshot(for itemID: String) -> (image: NSImage, anchor: CardTransitionAnchor, window: NSWindow)? {
        guard libraryCardTransitionCoverIsUnfiltered(self) else { return nil }
        return super.cardTransitionSnapshot(for: itemID)
    }

    override func setupContentLayout() {
        containerView.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.cgColor
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        setCardCornerRadius(Layout.cornerRadius)
        setNormalBorder(width: 1, color: NSColor.white.withAlphaComponent(0.08))

        contentView.addSubview(bottomBar)
        bottomBar.addSubview(titleLabel)
        bottomBar.addSubview(heartStat)
        bottomBar.addSubview(eyeStat)
        bottomBar.addSubview(fileStat)

        // 竖图卡片的模糊填充底必须在 coverImageView 之下（封面 fit 后两侧露底）。
        containerView.addSubview(coverBackdropView, positioned: .below, relativeTo: coverImageView)

        contentView.addSubview(categoryBadge)
        contentView.addSubview(purityBadge)
        contentView.addSubview(resolutionBadge)
        contentView.addSubview(checkboxView)
        contentView.addSubview(selectionMask)
        contentView.addSubview(currentBadge)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentModel = nil
        titleLabel.stringValue = ""
        coverImageView.kf.cancelDownloadTask()
        coverRetryTask?.cancel()
        coverRetryTask = nil
        coverSourceKey = nil
        coverLoadGeneration &+= 1
        coverRetryCount = 0
        coverRetrySourceKey = nil
        localThumbEnsureTask?.cancel()
        localThumbEnsureTask = nil
        if let token = localThumbIdleToken {
            LibraryScrollHoverGate.shared.cancelIdleWork(token: token)
            localThumbIdleToken = nil
        }
        menuActionTargets.removeAll()
        [categoryBadge, purityBadge, resolutionBadge].forEach { $0.configure(text: nil) }
        checkboxView.isHidden = true
        selectionMask.isHidden = true
        currentBadge.isHidden = true
    }

    override func configure(with item: Any, isFavorite: Bool) {
        guard let model = item as? LibraryWallpaperCellModel else { return }
        if currentModel?.wallpaper.id != model.wallpaper.id {
            localThumbEnsureTask?.cancel()
            localThumbEnsureTask = nil
            if let token = localThumbIdleToken {
                LibraryScrollHoverGate.shared.cancelIdleWork(token: token)
                localThumbIdleToken = nil
            }
            coverImageView.kf.cancelDownloadTask()
            coverRetryTask?.cancel()
            coverRetryTask = nil
            coverSourceKey = nil
            coverLoadGeneration &+= 1
            coverRetryCount = 0
            coverRetrySourceKey = nil
            coverImageView.image = LibraryCoverImageCache.snapshot(forKey: model.wallpaper.id)
            recordDisplayedCardTransitionImage(coverImageView.image, itemID: model.wallpaper.id)
        }
        currentModel = model
        if model.isEditing {
            clearHover(animated: false)
        }

        titleLabel.stringValue = model.wallpaper.uploader?.username ?? model.wallpaper.categoryDisplayName
        categoryBadge.configure(text: model.wallpaper.categoryDisplayName)
        purityBadge.configure(text: model.wallpaper.purityDisplayName)
        resolutionBadge.configure(text: model.wallpaper.resolution)
        heartStat.configure(icon: "heart.fill", value: compactNumber(model.wallpaper.favorites), tint: NSColor(hexString: "FF5A7D"))
        eyeStat.configure(icon: "eye.fill", value: compactNumber(model.wallpaper.views), tint: NSColor.white.withAlphaComponent(0.5))
        fileStat.configure(icon: "doc.fill", value: model.wallpaper.fileSizeLabel, tint: NSColor.white.withAlphaComponent(0.5))

        checkboxView.configure(isSelected: model.isSelected, accent: model.accent)
        checkboxView.isHidden = !model.isEditing
        selectionMask.isHidden = !(model.isEditing && model.isSelected)
        if !model.isEditing, model.isCurrentWallpaper {
            currentBadge.configure(text: t("wallpaper.currentlyActive"))
            currentBadge.isHidden = false
        } else {
            currentBadge.isHidden = true
        }

        applyPortraitCoverLayout(for: model)
        loadCoverImages(model: model)

        if containerView.bounds.width > 0, containerView.bounds.height > 0 {
            layoutContentFrames()
        } else {
            view.needsLayout = true
            containerView.needsLayout = true
            contentView.needsLayout = true
        }
    }

    override func layoutContentFrames() {
        let bounds = containerView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        contentView.frame = bounds
        let imageHeight = max(0, bounds.height - Layout.infoBarHeight)
        coverImageView.frame = CGRect(x: 0, y: Layout.infoBarHeight, width: bounds.width, height: imageHeight)
        coverImageView.layer?.cornerRadius = 0
        coverImageView.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.cgColor

        bottomBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Layout.infoBarHeight)
        titleLabel.frame = CGRect(
            x: Layout.horizontalPadding,
            y: floor((Layout.infoBarHeight - 16) / 2),
            width: max(40, bounds.width - Layout.horizontalPadding * 2 - 150),
            height: 16
        ).integral

        // 右侧统计：heart / eye / file 依次向左排
        var nextMaxX = bounds.width - Layout.horizontalPadding
        for stat in [fileStat, eyeStat, heartStat] {
            if stat.isHidden { continue }
            let size = stat.preferredSize
            stat.frame = CGRect(
                x: nextMaxX - size.width,
                y: floor((Layout.infoBarHeight - size.height) / 2),
                width: size.width,
                height: size.height
            ).integral
            nextMaxX = stat.frame.minX - 5
        }

        layoutTopBadges(in: bounds, imageHeight: imageHeight)
        layoutSelectionOverlay(in: bounds, imageHeight: imageHeight)

        // 竖图模糊底与封面同框：封面 fit 后两侧露底，由这一层铺满
        coverBackdropView.frame = coverImageView.frame
        coverBackdropView.layer?.cornerRadius = coverImageView.layer?.cornerRadius ?? 0
        coverBackdropView.layer?.maskedCorners = coverImageView.layer?.maskedCorners ?? []
    }

    private func layoutTopBadges(in bounds: CGRect, imageHeight: CGFloat) {
        let topEdge = Layout.infoBarHeight + imageHeight
        var nextX = Layout.overlayPadding
        for badge in [categoryBadge, purityBadge] where !badge.isHidden {
            let size = badge.preferredSize
            guard size.width > 0 else { continue }
            badge.frame = CGRect(
                x: nextX,
                y: topEdge - Layout.overlayPadding - size.height,
                width: size.width,
                height: size.height
            ).integral
            nextX = badge.frame.maxX + 8
        }
        if !resolutionBadge.isHidden {
            let size = resolutionBadge.preferredSize
            resolutionBadge.frame = CGRect(
                x: bounds.width - Layout.overlayPadding - size.width,
                y: topEdge - Layout.overlayPadding - size.height,
                width: size.width,
                height: size.height
            ).integral
        }
    }

    private func layoutSelectionOverlay(in bounds: CGRect, imageHeight: CGFloat) {
        checkboxView.frame = CGRect(x: Layout.overlayPadding, y: Layout.infoBarHeight + imageHeight - Layout.overlayPadding - 22, width: 22, height: 22)
        selectionMask.frame = CGRect(x: 0, y: Layout.infoBarHeight, width: bounds.width, height: imageHeight)
        if !currentBadge.isHidden {
            let size = currentBadge.preferredSize
            currentBadge.frame = CGRect(
                x: Layout.overlayPadding,
                y: Layout.infoBarHeight + Layout.overlayPadding,
                width: size.width,
                height: size.height
            ).integral
        }
    }

    override func cellMenu(for event: NSEvent) -> NSMenu? {
        guard let model = currentModel else { return nil }
        let entries = model.makeMenuEntries()
        guard !entries.isEmpty else { return nil }
        return Self.buildMenu(from: entries, targets: &menuActionTargets)
    }

    static func buildMenu(
        from entries: [LibraryGridMenuEntry],
        targets: inout [LibraryMenuActionTarget]
    ) -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            switch entry {
            case .divider:
                menu.addItem(.separator())
            case let .item(title, icon, destructive, handler):
                let target = LibraryMenuActionTarget(handler)
                targets.append(target)
                let menuItem = NSMenuItem(
                    title: title,
                    action: #selector(LibraryMenuActionTarget.performAction),
                    keyEquivalent: ""
                )
                menuItem.target = target
                if let icon {
                    let symbolConfiguration = NSImage.SymbolConfiguration(
                        pointSize: 13,
                        weight: .regular
                    ).applying(
                        destructive
                            ? NSImage.SymbolConfiguration(hierarchicalColor: NSColor.systemRed)
                            : NSImage.SymbolConfiguration()
                    )
                    menuItem.image = NSImage(
                        systemSymbolName: icon,
                        accessibilityDescription: nil
                    )?.withSymbolConfiguration(symbolConfiguration)
                }
                if destructive {
                    menuItem.attributedTitle = NSAttributedString(
                        string: title,
                        attributes: [.foregroundColor: NSColor.systemRed]
                    )
                }
                menu.addItem(menuItem)
            case let .submenu(title, icon, subEntries):
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if let icon {
                    menuItem.image = NSImage(
                        systemSymbolName: icon,
                        accessibilityDescription: nil
                    )?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
                }
                menuItem.submenu = buildMenu(from: subEntries, targets: &targets)
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    // MARK: 封面

    /// 封面加载选项：与旧 WallpaperEditCard 的 KFImage 同源
    /// （768px 降采样、disk 缓存，对齐 LocalImageThumbnailCache 的 SSD 缩略图），
    /// 但走库封面专用缓存 `LibraryCoverImageCache`：
    /// 30 分钟内存过期，且与详情页大图隔离。不走基类 loadImage 管线。
    private static let coverImageOptions: KingfisherOptionsInfo = [
        .processor(DownsamplingImageProcessor(size: CGSize(width: 384, height: 384))),
        .targetCache(LibraryCoverImageCache.imageCache),
        .backgroundDecode,
        .keepCurrentImageWhileLoading,
        .memoryCacheExpiration(.seconds(30 * 60)),
        .retryStrategy(DelayRetryStrategy(maxRetryCount: 1, retryInterval: .seconds(0.5)))
    ]

    /// 竖图卡片的模糊填充底：封面在竖图上改成 fit（完整显示）后，两侧露出的空白
    /// 由同一张图的模糊副本铺满，观感对齐壁纸详情页；横图这一层隐藏。
    private let coverBackdropView: ExploreGridCoverImageView = {
        let view = ExploreGridCoverImageView()
        view.preferredContentsGravity = .resizeAspectFill
        view.isHidden = true
        return view
    }()

    /// 竖图卡片完整显示原图 + 两侧模糊底。
    ///
    /// 只有**本地封面**（原图 / 本地缩略图，都保比例）才走 fit —— 远程站点 thumb
    /// 是横裁中心图，fit 出来只是更小的一条，还不如维持铺满裁切。
    private func applyPortraitCoverLayout(for model: LibraryWallpaperCellModel) {
        let isPortrait = model.wallpaper.dimensionY > model.wallpaper.dimensionX
        let hasLocalCover: Bool = {
            guard let local = model.localFileURL, local.isFileURL else { return false }
            return LocalImageThumbnailCache.isRasterImageFile(local)
        }()
        let useFittedCover = isPortrait && hasLocalCover

        setCoverContentsGravity(useFittedCover ? .resizeAspect : .resizeAspectFill)
        coverBackdropView.isHidden = !useFittedCover
        coverBackdropView.image = useFittedCover
            ? LibraryCoverImageCache.blurredSnapshot(forKey: model.wallpaper.id)
            : nil
    }

    /// 封面就绪后补上模糊底：48px 长边一次高斯模糊（共享 CIContext，单张 1–3ms），
    /// 结果进进程级缓存，之后每张竖卡都直接命中，滚动不再产生滤镜成本。
    private func updateBackdrop(with image: NSImage, model: LibraryWallpaperCellModel) {
        guard !coverBackdropView.isHidden else { return }
        let key = model.wallpaper.id
        if let cached = LibraryCoverImageCache.blurredSnapshot(forKey: key) {
            coverBackdropView.image = cached
            return
        }
        guard let blurred = LibraryCoverImageCache.makeBlurredSnapshot(from: image) else { return }
        LibraryCoverImageCache.storeBlurredSnapshot(blurred, forKey: key)
        guard currentModel?.wallpaper.id == key else { return }
        coverBackdropView.image = blurred
    }

    /// 封面候选（与旧 WallpaperEditCard.resolvedThumbURL 同源）：
    /// SSD 列表缩略图 > 站点 thumb。两者都存在时本地优先，失败自动回退另一张。
    private func loadCoverImages(model: LibraryWallpaperCellModel) {
        var candidates: [URL] = []
        if let local = model.localFileURL,
           local.isFileURL,
           LocalImageThumbnailCache.isRasterImageFile(local) {
            if let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
                candidates.append(cached)
            } else if local.pathExtension.lowercased() != "gif" {
                // 没有现成缩略图时直接用本地原图（coverImageOptions 已带 512 降采样），
                // 不要为了封面去下载远程缩略图：本机外网慢，整屏并发抓远端会把骨架屏
                // 拖到数秒（实测进库 shimmer 持续 5s，而数据层只有 681ms）。
                // GIF 走静态兜底路径，不在这里直读原图。
                candidates.append(local)
            }
        }
        if let remote = model.wallpaper.thumbURL ?? model.wallpaper.smallThumbURL,
           !candidates.contains(remote) {
            candidates.append(remote)
        }
        loadCoverCandidates(candidates, model: model)
        ensureLocalListThumbnail(model: model)
    }

    private func loadCoverCandidates(_ candidates: [URL], model: LibraryWallpaperCellModel) {
        guard currentModel?.wallpaper.id == model.wallpaper.id else { return }
        let sourceKey = candidates.first?.absoluteString ?? "<empty>"
        guard sourceKey != coverSourceKey else { return }
        if sourceKey != coverRetrySourceKey {
            coverRetryTask?.cancel()
            coverRetryCount = 0
            coverRetrySourceKey = sourceKey
        }

        coverSourceKey = sourceKey
        coverLoadGeneration &+= 1
        let generation = coverLoadGeneration
        coverImageView.kf.cancelDownloadTask()
        loadCoverCandidate(
            at: 0,
            candidates: candidates,
            model: model,
            generation: generation
        )
    }

    /// 依次尝试候选：失败（文件缺失/下载失败）落到下一个；全部失败才留空。
    private func loadCoverCandidate(
        at index: Int,
        candidates: [URL],
        model: LibraryWallpaperCellModel,
        generation: Int
    ) {
        guard index < candidates.count, currentModel?.wallpaper.id == model.wallpaper.id else {
            if index == 0 {
                // 无任何候选：保留现有图，避免详情返回或后台刷新时出现黑闪。
                coverSourceKey = nil
            } else if coverLoadGeneration == generation {
                retryCoverAfterFailure(model: model)
            }
            return
        }
        // 网格重建后的新 cell 封面从 nil 起步：先同步回填快照再走异步加载，
        // 详情返回/整表 reload 时不出现空白闪烁。
        if coverImageView.image == nil {
            coverImageView.image = LibraryCoverImageCache.snapshot(forKey: model.wallpaper.id)
            recordDisplayedCardTransitionImage(coverImageView.image, itemID: model.wallpaper.id)
        }
        coverImageView.kf.setImage(
            with: candidates[index],
            options: Self.coverImageOptions + [.transition(.none)],
            completionHandler: { [weak self] result in
                switch result {
                case .success(let value):
                    LibraryCoverImageCache.storeSnapshot(value.image, forKey: model.wallpaper.id)
                    guard let self, self.coverLoadGeneration == generation,
                          self.currentModel?.wallpaper.id == model.wallpaper.id,
                          self.coverImageView.image === value.image else { return }
                    self.recordDisplayedCardTransitionImage(value.image, itemID: model.wallpaper.id)
                    self.updateBackdrop(with: value.image, model: model)
                    self.coverRetryTask?.cancel()
                    self.coverRetryTask = nil
                case .failure:
                    guard let self,
                          self.coverLoadGeneration == generation,
                          self.currentModel?.wallpaper.id == model.wallpaper.id else { return }
                    self.loadCoverCandidate(
                        at: index + 1,
                        candidates: candidates,
                        model: model,
                        generation: generation
                    )
                }
            }
        )
    }

    private func retryCoverAfterFailure(model: LibraryWallpaperCellModel) {
        guard coverRetryCount < 2 else { return }
        coverRetryCount += 1
        let generation = coverLoadGeneration
        let delay = coverRetryCount == 1 ? 1.0 : 3.0
        coverRetryTask?.cancel()
        coverRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self,
                  self.coverLoadGeneration == generation,
                  self.currentModel?.wallpaper.id == model.wallpaper.id else { return }
            self.coverSourceKey = nil
            self.loadCoverImages(model: model)
        }
    }

    /// 外置原图 → 本机 SSD 512 列表缩略图；有远程 thumb 时列表先显示远程，滚停后再补本地缓存。
    private func ensureLocalListThumbnail(model: LibraryWallpaperCellModel) {
        guard let local = model.localFileURL,
              local.isFileURL,
              LocalImageThumbnailCache.isRasterImageFile(local) else { return }
        guard currentModel?.wallpaper.id == model.wallpaper.id else { return }

        if let token = localThumbIdleToken {
            LibraryScrollHoverGate.shared.cancelIdleWork(token: token)
            localThumbIdleToken = nil
        }

        if LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) != nil {
            return
        }

        // 滚动中不生成：滚停后再写 SSD
        guard !LibraryScrollHoverGate.shared.isScrolling else {
            let token = UUID()
            localThumbIdleToken = token
            LibraryScrollHoverGate.shared.runWhenIdle(token: token) { [weak self] in
                guard let self, self.localThumbIdleToken == token else { return }
                self.localThumbIdleToken = nil
                self.startLocalThumbnailTask(local: local, wallpaperID: model.wallpaper.id)
            }
            return
        }
        startLocalThumbnailTask(local: local, wallpaperID: model.wallpaper.id)
    }

    private func startLocalThumbnailTask(local: URL, wallpaperID: String) {
        localThumbEnsureTask?.cancel()
        localThumbEnsureTask = Task { [weak self] in
            guard !LibraryScrollHoverGate.shared.isScrolling else { return }
            guard let thumb = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: local) else {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self, let model = self.currentModel,
                  model.wallpaper.id == wallpaperID else { return }
            // SSD 小图就绪：替换（失败保持现有封面不动）
            self.loadCoverCandidates([thumb], model: model)
        }
    }

    private func compactNumber(_ number: Int) -> String {
        if number >= 1_000_000 {
            return String(format: "%.1fM", Double(number) / 1_000_000)
        } else if number >= 1_000 {
            return String(format: "%.1fK", Double(number) / 1_000)
        }
        return String(number)
    }
}

/// 信息栏右侧统计项（SF icon + monospaced 数字）
final class LibraryStatLabelView: NSView {
    private let iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }()

    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.7)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(iconView)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var preferredSize: CGSize {
        guard !label.stringValue.isEmpty else { return .zero }
        let textSize = label.fittingSize
        return CGSize(width: ceil(12 + 4 + textSize.width), height: max(14, textSize.height))
    }

    func configure(icon: String, value: String, tint: NSColor) {
        label.stringValue = value
        iconView.image = NSImage(
            systemSymbolName: icon,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        iconView.contentTintColor = tint
        isHidden = value.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0, !isHidden else { return }
        iconView.frame = CGRect(x: 0, y: floor((bounds.height - 11) / 2), width: 12, height: 11)
        let textSize = label.fittingSize
        label.frame = CGRect(
            x: iconView.frame.maxX + 4,
            y: floor((bounds.height - textSize.height) / 2),
            width: max(0, bounds.width - iconView.frame.maxX - 4),
            height: max(textSize.height, 1)
        ).integral
    }
}

// MARK: - 媒体卡 Cell

/// （中间帧起播 + 与静态封面同比例 aspect-fill）。
final class LibraryFolderDropView: NSView {
    var onDrop: (([String]) -> Void)?
    var onTargetChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let acceptsDrop = !LibraryDragPayload.ids(fromPasteboard: sender.draggingPasteboard).isEmpty
        onTargetChanged?(acceptsDrop)
        return acceptsDrop ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !LibraryDragPayload.ids(fromPasteboard: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let ids = LibraryDragPayload.ids(fromPasteboard: sender.draggingPasteboard)
        guard !ids.isEmpty else { return false }
        onDrop?(ids)
        onTargetChanged?(false)
        return true
    }
}

/// 还原 LibraryFolderCard：叠图预览 + 加密锁态 + 中央 drop 区 + 计数信息栏
final class LibraryFolderGridCell: ExploreGridItem {
    static let newReuseIdentifier = NSUserInterfaceItemIdentifier("LibraryFolderGridCell")
    override class var gridReuseIdentifier: NSUserInterfaceItemIdentifier { newReuseIdentifier }

    private enum Layout {
        static let infoBarHeight = LibraryGridCellMetrics.infoBarHeight
        static let cornerRadius = LibraryGridCellMetrics.cornerRadius
        static let horizontalPadding: CGFloat = 14
    }

    private var currentModel: LibraryFolderCellModel?
    private var menuActionTargets: [LibraryMenuActionTarget] = []
    private(set) var isDropTarget = false {
        didSet {
            refreshDropVisual()
        }
    }

    /// 叠图槽位（最多 4 张）
    private let stackPreviewViews: [ExploreGridCoverImageView] = (0..<4).map { _ in
        let view = ExploreGridCoverImageView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        view.layer?.shadowColor = NSColor.black.withAlphaComponent(0.4).cgColor
        view.layer?.shadowRadius = 5
        view.layer?.shadowOffset = CGSize(width: 0, height: -2)
        view.layer?.shadowOpacity = 1
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.minificationFilter = .trilinear
        // 叠图会做轻微旋转；开启图层边缘抗锯齿，避免圆角和斜边出现毛边。
        view.layer?.allowsEdgeAntialiasing = true
        return view
    }

    /// 各叠图槽位当前已加载的 URL key：reload token 变化会高频 reconfigure 可见 cell，
    /// 重复 kf.setImage（即使命中内存缓存也会异步重设图层）是文件夹卡闪动的主因。
    private var previewLoadedKeys: [String?] = [nil, nil, nil, nil]
    private var previewRetryKeys: [String?] = [nil, nil, nil, nil]
    private var previewRetryCounts = [0, 0, 0, 0]
    private var previewRetryTasks: [Task<Void, Never>?] = [nil, nil, nil, nil]
    private var previewTargetSize: CGSize = .zero
    /// 叠图齐显代数：同一批 3-4 张一起淡入，避免逐张蹦出来。
    /// reconfigure / 复用 / retry 会递增，旧批次的 completion 直接丢弃。
    private var stackRevealGeneration = 0
    /// 本批次还在等 Kingfisher 回调的槽位。layout 期间跳过这些槽位的 alpha 赋值，保持 0 直到齐显。
    private var stackLoadingIndices: Set<Int> = []

    /// 当前是否处于「锁定且未解锁」的模糊展示态
    private var isPreviewBlurred = false {
        didSet {
            guard isPreviewBlurred != oldValue else { return }
            applyPreviewBlurFilters()
        }
    }

    /// 加锁未解锁时的叠图滤镜：高斯模糊 18 + 降饱和/压暗
    /// （对齐旧 SwiftUI `.blur(radius: 18).saturation(0.82).brightness(-0.04)`）。
    /// 每次创建独立 CIFilter，避免多个复用 cell 共享可变滤镜对象。
    private static func makeLockedPreviewFilters() -> [CIFilter]? {
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(18, forKey: kCIInputRadiusKey)
        guard let color = CIFilter(name: "CIColorControls") else { return [blur] }
        color.setValue(0.82, forKey: kCIInputSaturationKey)
        color.setValue(-0.04, forKey: kCIInputBrightnessKey)
        return [blur, color]
    }

    /// 空文件夹占位图标
    private let placeholderIconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = NSColor.white.withAlphaComponent(0.1)
        return view
    }()
    /// 对齐旧 SwiftUI 图片区的 `.clipped()`：叠图、模糊和缩放都限制在
    /// 封面区内，不能漏到信息栏或卡片边缘。
    private let previewCanvasView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layerUsesCoreImageFilters = true
        return view
    }()

    /// 加密锁态覆盖（对齐旧 LockedFolderOverlay 结构）：
    /// hudWindow 毛玻璃全幅 + 斜向渐变(screen) + 黑色压暗 + 居中超细材质圆形锁徽章
    private let lockEffectView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }()
    private let lockOverlayView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        return view
    }()
    private let lockGradientLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.colors = [
            NSColor.white.withAlphaComponent(0.18).cgColor,
            NSColor.white.withAlphaComponent(0.06).cgColor,
            NSColor.black.withAlphaComponent(0.18).cgColor
        ]
        layer.startPoint = CGPoint(x: 0, y: 1)
        layer.endPoint = CGPoint(x: 1, y: 0)
        return layer
    }()
    private let lockBadgeView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.allowsEdgeAntialiasing = true
        return view
    }()
    private let lockBadgeShadowView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.35
        view.layer?.shadowRadius = 14
        view.layer?.shadowOffset = CGSize(width: 0, height: -4)
        return view
    }()
    private let lockIconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = NSColor.white.withAlphaComponent(0.82)
        return view
    }()

    /// 解锁后的「重新锁定」小按钮
    private let relockButton: NSButton = {
        let button = NSButton(image: NSImage(
            systemSymbolName: "lock.fill",
            accessibilityDescription: nil
        ) ?? NSImage(), target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        button.layer?.cornerRadius = 14
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        button.layer?.borderWidth = 1
        // 旧 SwiftUI 按钮为 11pt 图标 + 8pt 内边距，禁止 AppKit 将符号放大填满按钮。
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        button.image = button.image?.withSymbolConfiguration(
            .init(pointSize: 11, weight: .semibold)
        )
        button.toolTip = t("folder.relock")
        return button
    }()

    private let dropView = LibraryFolderDropView()

    private let bottomBar: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }()

    private let nameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

    private let countStat = LibraryStatLabelView()

    override var hoverScaleFactor: CGFloat { 1.01 }
    override var shouldAnimateBorderOnHover: Bool { true }

    override func setupContentLayout() {
        containerView.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.withAlphaComponent(0.6).cgColor
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        setCardCornerRadius(Layout.cornerRadius)
        setNormalBorder(width: 1, color: NSColor.white.withAlphaComponent(0.08))

        contentView.addSubview(previewCanvasView)
        for (index, preview) in stackPreviewViews.enumerated() {
            // 数组前面的在顶层（zPosition 递减）
            preview.layer?.zPosition = CGFloat(4 - index)
            previewCanvasView.addSubview(preview)
        }
        previewCanvasView.addSubview(placeholderIconView)
        contentView.addSubview(lockEffectView)
        contentView.addSubview(lockOverlayView)
        lockOverlayView.layer?.addSublayer(lockGradientLayer)
        contentView.addSubview(lockBadgeShadowView)
        lockBadgeShadowView.addSubview(lockBadgeView)
        lockBadgeView.addSubview(lockIconView)
        contentView.addSubview(relockButton)
        contentView.addSubview(dropView)

        contentView.addSubview(bottomBar)
        bottomBar.addSubview(nameLabel)
        bottomBar.addSubview(countStat)

        relockButton.target = self
        relockButton.action = #selector(relockTapped)

        lockIconView.image = NSImage(
            systemSymbolName: "lock.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 28, weight: .bold))
    }

    /// 按当前锁态挂/摘叠图模糊滤镜
    private func applyPreviewBlurFilters() {
        previewCanvasView.layer?.filters = isPreviewBlurred
            ? Self.makeLockedPreviewFilters()
            : nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentModel = nil
        menuActionTargets.removeAll()
        nameLabel.stringValue = ""
        isDropTarget = false
        for preview in stackPreviewViews {
            preview.kf.cancelDownloadTask()
            preview.image = nil
            preview.isHidden = true
            preview.layer?.transform = CATransform3DIdentity
        }
        for index in previewLoadedKeys.indices {
            previewLoadedKeys[index] = nil
            previewRetryKeys[index] = nil
            previewRetryCounts[index] = 0
            previewRetryTasks[index]?.cancel()
            previewRetryTasks[index] = nil
        }
        stackRevealGeneration &+= 1
        stackLoadingIndices.removeAll()
        previewCanvasView.layer?.filters = nil
        previewTargetSize = .zero
        placeholderIconView.isHidden = true
        lockOverlayView.isHidden = true
        lockEffectView.isHidden = true
        lockBadgeShadowView.isHidden = true
        lockBadgeView.isHidden = true
        relockButton.isHidden = true
        isPreviewBlurred = false
        dropView.onDrop = nil
        dropView.onTargetChanged = nil
    }

    override func configure(with item: Any, isFavorite: Bool) {
        guard let model = item as? LibraryFolderCellModel else { return }
        currentModel = model

        nameLabel.stringValue = model.folder.name
        countStat.configure(
            icon: "photo.on.rectangle.angled",
            value: "\(model.itemCount)",
            tint: NSColor.white.withAlphaComponent(0.5)
        )

        let isLockedAndHidden = model.folder.isLocked && !model.isUnlocked
        lockOverlayView.isHidden = !isLockedAndHidden
        lockEffectView.isHidden = !isLockedAndHidden
        lockBadgeShadowView.isHidden = !isLockedAndHidden
        lockBadgeView.isHidden = !isLockedAndHidden
        relockButton.isHidden = !(model.folder.isLocked && model.isUnlocked)
        isPreviewBlurred = isLockedAndHidden

        dropView.onDrop = { [weak self] ids in
            self?.currentModel?.onDrop(ids)
        }
        dropView.onTargetChanged = { [weak self] isTargeted in
            self?.isDropTarget = isTargeted
        }

        if containerView.bounds.width > 0, containerView.bounds.height > 0 {
            layoutContentFrames()
            configureStackPreviews(urls: model.previewURLs)
        } else {
            view.needsLayout = true
            containerView.needsLayout = true
            contentView.needsLayout = true
        }
    }

    /// 叠图布局：与 FolderStackView 相同的偏移/旋转（SwiftUI y 向下，AppKit y 向上，dy 取反；旋转角取反）
    private static let stackConfigs: [(dx: CGFloat, dy: CGFloat, rotationDegrees: CGFloat, opacity: Float)] = [
        (16, 10, 0, 1.0),
        (-18, -14, -4, 0.90),
        (20, -12, 5, 0.75),
        (-14, 16, -3, 0.58)
    ]

    private func configureStackPreviews(urls: [URL]) {
        let activeURLs = Array(urls.prefix(4))
        let targetSize = previewTargetSize.width > 0
            ? previewTargetSize
            : CGSize(width: 320, height: 240)
        placeholderIconView.image = NSImage(
            systemSymbolName: "folder.fill",
            accessibilityDescription: nil
        )
        placeholderIconView.isHidden = !activeURLs.isEmpty
        stackRevealGeneration &+= 1
        let generation = stackRevealGeneration

        // 先算出本批真正要走网络/磁盘的槽位：已在显示的只同步透明度，不参与齐显等待。
        var pending: [Int] = []
        for (index, preview) in stackPreviewViews.enumerated() {
            guard index < activeURLs.count else {
                previewRetryTasks[index]?.cancel()
                previewRetryTasks[index] = nil
                previewRetryKeys[index] = nil
                previewRetryCounts[index] = 0
                preview.isHidden = true
                preview.image = nil
                previewLoadedKeys[index] = nil
                stackLoadingIndices.remove(index)
                continue
            }
            preview.isHidden = false
            // 同 URL 已在显示：只同步可见性/透明度，跳过 setImage（防 reconfigure 闪动）
            let key = "\(activeURLs[index].absoluteString)|\(Int(targetSize.width))x\(Int(targetSize.height))"
            guard previewLoadedKeys[index] != key else {
                stackLoadingIndices.remove(index)
                preview.alphaValue = CGFloat(Self.stackConfigs[index].opacity)
                continue
            }
            pending.append(index)
        }
        stackLoadingIndices = Set(pending)
        guard !pending.isEmpty else { return }

        // 首刷（整叠都要加载）时先露文件夹占位，叠图凑齐再一起淡入，避免空黑卡。
        if pending.count == activeURLs.count {
            placeholderIconView.isHidden = false
        }
        for index in pending {
            stackPreviewViews[index].alphaValue = 0
        }

        for index in pending {
            let preview = stackPreviewViews[index]
            let snapshotKey = "folder|\(activeURLs[index].absoluteString)"
            let key = "\(activeURLs[index].absoluteString)|\(Int(targetSize.width))x\(Int(targetSize.height))"
            if previewRetryKeys[index] != key {
                previewRetryTasks[index]?.cancel()
                previewRetryTasks[index] = nil
                previewRetryCounts[index] = 0
                previewRetryKeys[index] = key
            }
            previewLoadedKeys[index] = key
            // URL 切换时先回填对应快照，不能让复用槽位暂时显示上一张图。
            preview.image = LibraryCoverImageCache.snapshot(forKey: snapshotKey)
            preview.kf.setImage(
                with: activeURLs[index],
                options: [
                    .processor(DownsamplingImageProcessor(size: targetSize)),
                    .targetCache(LibraryCoverImageCache.imageCache),
                    .backgroundDecode,
                    .keepCurrentImageWhileLoading,
                    .retryStrategy(DelayRetryStrategy(maxRetryCount: 1, retryInterval: .seconds(0.5))),
                    .transition(.none)
                ],
                completionHandler: { [weak self] result in
                    switch result {
                    case .success(let value):
                        LibraryCoverImageCache.storeSnapshot(value.image, forKey: snapshotKey)
                    case .failure:
                        self?.retryPreviewAfterFailure(index: index, key: key)
                    }
                    self?.stackPreviewDidSettle(index: index, generation: generation)
                }
            )
        }
    }

    /// 单槽加载结算：本批次全部回齐（成功或失败都算）才一起淡入，避免叠图逐张蹦。
    private func stackPreviewDidSettle(index: Int, generation: Int) {
        guard generation == stackRevealGeneration else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.stackPreviewDidSettle(index: index, generation: generation)
            }
            return
        }
        stackLoadingIndices.remove(index)
        guard stackLoadingIndices.isEmpty else { return }
        if let urls = currentModel?.previewURLs, !urls.isEmpty {
            placeholderIconView.isHidden = true
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            for (i, preview) in stackPreviewViews.enumerated() {
                guard previewLoadedKeys[i] != nil, !preview.isHidden else { continue }
                preview.animator().alphaValue = CGFloat(Self.stackConfigs[i].opacity)
            }
        }
    }

    private func retryPreviewAfterFailure(index: Int, key: String) {
        guard previewLoadedKeys[index] == key,
              previewRetryCounts[index] < 2 else { return }
        previewRetryCounts[index] += 1
        let delay = previewRetryCounts[index] == 1 ? 1.0 : 3.0
        previewRetryTasks[index]?.cancel()
        previewRetryTasks[index] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self,
                  self.previewLoadedKeys[index] == key,
                  let urls = self.currentModel?.previewURLs,
                  urls.indices.contains(index) else { return }
            self.previewLoadedKeys[index] = nil
            self.configureStackPreviews(urls: urls)
        }
    }

    override func layoutContentFrames() {
        let bounds = containerView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // 布局期间关闭隐式动画：frame/transform/alpha 的隐式 CA 动画是闪动来源
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        contentView.frame = bounds
        let imageHeight = max(0, bounds.height - Layout.infoBarHeight)
        coverImageView.frame = CGRect(x: 0, y: Layout.infoBarHeight, width: bounds.width, height: imageHeight)
        coverImageView.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.withAlphaComponent(0.3).cgColor
        coverImageView.layer?.cornerRadius = 0

        let stackWidth = bounds.width * 0.75
        let stackHeight = imageHeight * 0.68
        let nextPreviewTargetSize = CGSize(
            width: max(1, stackWidth * 2),
            height: max(1, stackHeight * 2)
        )
        let targetChanged = abs(nextPreviewTargetSize.width - previewTargetSize.width) > 24
            || abs(nextPreviewTargetSize.height - previewTargetSize.height) > 24
        previewTargetSize = nextPreviewTargetSize
        previewCanvasView.frame = CGRect(
            x: 0,
            y: Layout.infoBarHeight,
            width: bounds.width,
            height: imageHeight
        )
        if targetChanged, let urls = currentModel?.previewURLs {
            configureStackPreviews(urls: urls)
        }
        // 叠图中心 = 图片区几何中心（与旧 FolderStackView 的 ZStack 居中一致）
        // 向下留出顶部呼吸空间，避免后排旋转卡片贴到图片区上沿。
        let stackCenterY = imageHeight / 2 - 9
        let backingScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        for (index, preview) in stackPreviewViews.enumerated() {
            let config = Self.stackConfigs[index]
            preview.frame = CGRect(
                x: (bounds.width - stackWidth) / 2 + config.dx,
                y: stackCenterY - stackHeight / 2 - config.dy,
                width: stackWidth,
                height: stackHeight
            )
            // 齐显等待中的槽位保持 0，凑齐后由 stackPreviewDidSettle 一起淡入。
            if !stackLoadingIndices.contains(index) {
                preview.alphaValue = CGFloat(config.opacity)
            }
            preview.layer?.contentsScale = backingScale
            // 旋转取反（SwiftUI y 向下）；模糊态放大 1.06 补偿高斯模糊的边缘透明
            let radians = -config.rotationDegrees * .pi / 180
            var transform = CATransform3DMakeRotation(radians, 0, 0, 1)
            if isPreviewBlurred {
                transform = CATransform3DScale(transform, 1.06, 1.06, 1)
            }
            preview.layer?.transform = transform
        }

        let iconSide = min(bounds.width, imageHeight) * 0.35
        placeholderIconView.frame = CGRect(
            x: (bounds.width - iconSide) / 2,
            y: (imageHeight - iconSide) / 2,
            width: iconSide,
            height: iconSide
        )

        // 锁态覆盖：毛玻璃 + 渐变 + 压暗铺满图片区，居中圆形锁徽章（对齐旧 LockedFolderOverlay）
        let imageArea = CGRect(x: 0, y: Layout.infoBarHeight, width: bounds.width, height: imageHeight)
        lockEffectView.frame = imageArea
        lockOverlayView.frame = imageArea
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lockGradientLayer.frame = lockOverlayView.bounds
        CATransaction.commit()
        let badgeSide: CGFloat = 28 + 28 * 0.55 * 2
        let lockBadgeFrame = CGRect(
            x: (bounds.width - badgeSide) / 2,
            y: Layout.infoBarHeight + (imageHeight - badgeSide) / 2,
            width: badgeSide,
            height: badgeSide
        )
        lockBadgeShadowView.frame = lockBadgeFrame
        lockBadgeShadowView.layer?.shadowPath = CGPath(
            ellipseIn: lockBadgeShadowView.bounds,
            transform: nil
        )
        lockBadgeView.frame = lockBadgeShadowView.bounds
        lockBadgeView.layer?.cornerRadius = badgeSide / 2
        lockBadgeView.layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        lockBadgeView.layer?.borderWidth = 1
        lockIconView.frame = lockBadgeView.bounds.insetBy(dx: (badgeSide - 28) / 2, dy: (badgeSide - 28) / 2)

        relockButton.frame = CGRect(x: 10, y: Layout.infoBarHeight + 10, width: 28, height: 28)

        dropView.frame = CGRect(
            x: bounds.width * 0.2,
            y: Layout.infoBarHeight + imageHeight * 0.2,
            width: bounds.width * 0.6,
            height: imageHeight * 0.6
        )

        bottomBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Layout.infoBarHeight)
        nameLabel.frame = CGRect(
            x: Layout.horizontalPadding,
            y: floor((Layout.infoBarHeight - 16) / 2),
            width: max(40, bounds.width - Layout.horizontalPadding * 2 - 70),
            height: 16
        ).integral
        let countSize = countStat.preferredSize
        countStat.frame = CGRect(
            x: bounds.width - Layout.horizontalPadding - countSize.width,
            y: floor((Layout.infoBarHeight - countSize.height) / 2),
            width: countSize.width,
            height: countSize.height
        ).integral
    }

    override func cellMenu(for event: NSEvent) -> NSMenu? {
        guard let model = currentModel, !model.menuEntries.isEmpty else { return nil }
        return LibraryWallpaperGridCell.buildMenu(from: model.menuEntries, targets: &menuActionTargets)
    }

    override func effectiveHoverBorderWidth(for hovering: Bool) -> CGFloat {
        isDropTarget ? 2.5 : super.effectiveHoverBorderWidth(for: hovering)
    }

    override func effectiveHoverBorderColor(for hovering: Bool) -> NSColor {
        isDropTarget
            ? NSColor.controlAccentColor.withAlphaComponent(0.8)
            : super.effectiveHoverBorderColor(for: hovering)
    }

    @objc private func relockTapped() {
        currentModel?.onRelock()
    }

    private func refreshDropVisual() {
        if isDropTarget {
            borderLayer.borderWidth = 2.5
            borderLayer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        } else {
            borderLayer.borderWidth = normalBorderWidth
            let alpha = isHovered ? hoverBorderAlpha(for: normalBorderColor) : normalBorderColor.alphaComponent
            borderLayer.borderColor = normalBorderColor.withAlphaComponent(alpha).cgColor
        }
    }
}

// MARK: - 动漫卡 Cell

import SwiftUI
import Kingfisher

// MARK: - Card Metrics

public enum LibraryCardMetrics {
    public static let cardWidth: CGFloat = 260
    public static let thumbnailHeight: CGFloat = 180
}

// MARK: - Scroll Hover Gate

/// 我的库滚动期间抑制 hover（尤其 GIF 叠加层挂载），并门控缩略图生成/预热。
/// 仅在 suppress 边沿发一次通知，避免滚动帧驱动整树重绘。
@MainActor
final class LibraryScrollHoverGate {
    static let shared = LibraryScrollHoverGate()

    private(set) var suppressesAnimatedHover = false
    /// 滚动中（含惯性尾段）为 true；滚停 idleDelay 后变 false。
    private(set) var isScrolling = false
    private var idleWorkItem: DispatchWorkItem?
    /// 只允许最新一次滚动活动结束后解除门控。
    private var idleGeneration = 0
    private var idleCallbacks: [UUID: () -> Void] = [:]
    /// 滚停后稍等再恢复，避免惯性滚动尾段反复开关
    private let idleDelay: TimeInterval = 0.22

    func noteScrollActivity() {
        idleWorkItem?.cancel()
        idleGeneration &+= 1
        let generation = idleGeneration
        isScrolling = true
        if !suppressesAnimatedHover {
            suppressesAnimatedHover = true
            NotificationCenter.default.post(name: .libraryScrollDidSuppressHover, object: nil)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.idleGeneration == generation else { return }
            self.idleWorkItem = nil
            self.isScrolling = false
            self.suppressesAnimatedHover = false
            let callbacks = Array(self.idleCallbacks.values)
            self.idleCallbacks.removeAll()
            for callback in callbacks {
                callback()
            }
            NotificationCenter.default.post(name: .libraryScrollDidBecomeIdle, object: nil)
        }
        idleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleDelay, execute: work)
    }

    /// 滚动中排队，滚停后只执行一次（同 token 会覆盖）。
    @discardableResult
    func runWhenIdle(token: UUID = UUID(), _ work: @escaping () -> Void) -> UUID {
        if !isScrolling {
            work()
            return token
        }
        idleCallbacks[token] = work
        return token
    }

    func cancelIdleWork(token: UUID) {
        idleCallbacks.removeValue(forKey: token)
    }
}

extension Notification.Name {
    static let libraryScrollDidSuppressHover = Notification.Name("libraryScrollDidSuppressHover")
    static let libraryScrollDidBecomeIdle = Notification.Name("libraryScrollDidBecomeIdle")
}

// MARK: - 滚停后命中恢复 hover
//
// macOS 上内容从静止指针下划过时，SwiftUI onHover 往往不会对“新到指针下的卡”重发 enter。
// 滚停后用 AppKit 窗口坐标对卡片 bounds 做一次 hit-test，指针仍在卡上则立刻恢复 isHovered。

private struct LibraryScrollIdleHoverProbe: NSViewRepresentable {
    let onProbe: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onProbe = onProbe
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onProbe = onProbe
    }

    final class ProbeView: NSView {
        var onProbe: ((Bool) -> Void)?
        private var idleObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeIdleObserver()
            guard window != nil else { return }
            idleObserver = NotificationCenter.default.addObserver(
                forName: .libraryScrollDidBecomeIdle,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.probeMouse()
            }
        }

        override func removeFromSuperview() {
            removeIdleObserver()
            super.removeFromSuperview()
        }

        private func removeIdleObserver() {
            if let idleObserver {
                NotificationCenter.default.removeObserver(idleObserver)
                self.idleObserver = nil
            }
        }

        private func probeMouse() {
            guard let window, !isHiddenOrHasHiddenAncestor else { return }
            // 不可见/零尺寸时跳过（Lazy 离屏卡）
            guard bounds.width > 1, bounds.height > 1 else { return }
            let mouseInWindow = window.mouseLocationOutsideOfEventStream
            let local = convert(mouseInWindow, from: nil)
            onProbe?(bounds.contains(local))
        }
    }
}

extension View {
    /// 滚停后若指针仍在本视图上，回调 true（用于恢复 hover，不依赖 onHover 重发）
    func libraryScrollIdleHoverProbe(_ onProbe: @escaping (Bool) -> Void) -> some View {
        background {
            LibraryScrollIdleHoverProbe(onProbe: onProbe)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }
}

public struct WallpaperEditCard: View, @preconcurrency Equatable {
    let wallpaper: Wallpaper
    /// 已下载壁纸的本地文件路径（可选）；列表封面优先 SSD 缩略图，不直接读外置原图
    var localFileURL: URL? = nil
    var accent: Color = LiquidGlassColors.primaryPink
    let isEditing: Bool
    let isSelected: Bool
    var downloadDate: Date? = nil
    var progress: Double? = nil
    var progressTint: Color? = nil
    var progressLabel: String? = nil
    var cardWidth: CGFloat = LibraryCardMetrics.cardWidth
    /// 当前壁纸是否在任意屏幕上使用中。
    /// 作为存储属性由父视图计算后传入，确保 .equatable() 的 == 能正确感知
    /// 壁纸切换（若用计算属性读 @EnvironmentObject，== 比较时新旧值读到的是
    /// 同一份当前环境，恒相等，标记永不刷新）。
    var isCurrentWallpaper: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    /// 指针是否在卡片内（滚动中也更新；滚停时用来恢复 isHovered）
    @State private var isPointerInside = false
    /// SSD 列表缩略图（生成后刷新，避免 KFImage 一直读 TF 上的全尺寸文件）
    @State private var cachedListThumbURL: URL?
    /// 滚动中延后的本地静图缩略图任务。
    @State private var pendingLocalThumbnailIdleToken: UUID?

    public static func == (lhs: WallpaperEditCard, rhs: WallpaperEditCard) -> Bool {
        lhs.wallpaper.id == rhs.wallpaper.id &&
        lhs.isEditing == rhs.isEditing &&
        lhs.isSelected == rhs.isSelected &&
        lhs.cardWidth == rhs.cardWidth &&
        lhs.localFileURL == rhs.localFileURL &&
        // 纳入"当前使用中"状态：壁纸切换后 .equatable() 才会重算 body、刷新标记
        lhs.isCurrentWallpaper == rhs.isCurrentWallpaper
    }

    private var thumbnailHeight: CGFloat {
        LibraryCardMetrics.thumbnailHeight
    }

    private var remoteThumbURL: URL? {
        wallpaper.thumbURL ?? wallpaper.smallThumbURL
    }

    /// 封面 URL：SSD 列表缩略图 > 站点 thumb > 绝不把外置/全尺寸原图喂给 KFImage。
    private var resolvedThumbURL: URL? {
        if let cachedListThumbURL {
            return cachedListThumbURL
        }
        if let local = localFileURL,
           local.isFileURL,
           LocalImageThumbnailCache.isRasterImageFile(local),
           let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
            return cached
        }
        if let remote = remoteThumbURL {
            return remote
        }
        // 无远程 thumb 且 SSD 缓存未就绪：返回 nil → Skeleton 占位，
        // 由 ensureLocalListThumbnail 在滚停后生成并切换。
        return nil
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域
                ZStack {
                    KFImage(resolvedThumbURL)
                        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 512, height: 512)))
                        .cacheMemoryOnly(false)
                        .placeholder { _ in
                            SkeletonCard(
                                width: cardWidth,
                                height: thumbnailHeight,
                                cornerRadius: 0
                            )
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: cardWidth,
                            height: thumbnailHeight
                        )
                        .clipped()

                    if !isEditing {
                        VStack {
                            topMetadataRow
                            Spacer()
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }

                    // 左上角复选框（编辑模式下显示）
                    if isEditing {
                        VStack {
                            HStack {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(isSelected ? accent : .white.opacity(0.8))
                                    .background(
                                        Circle()
                                            .fill(isSelected ? .white : Color.black.opacity(0.4))
                                            .frame(width: 20, height: 20)
                                    )
                                    .padding(12)

                                Spacer()
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }

                    // 选中时的遮罩
                    if isEditing && isSelected {
                        Color.black.opacity(0.3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // 当前使用中的壁纸标记
                    if !isEditing && isCurrentWallpaper {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(t("wallpaper.currentlyActive"))
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(
                            Capsule(style: .continuous).fill(Color.green.opacity(0.78))
                        )
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .transition(.opacity)
                    }
                }

                // 信息区域
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text(wallpaper.uploader?.username ?? wallpaper.categoryDisplayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .layoutPriority(1)

                        Spacer(minLength: 12)

                        trailingMetadataRow
                    }

                    // 未完成时显示进度块
                    if let progress, progress < 1.0 {
                        DownloadCardProgressBlock(
                            progress: progress,
                            label: progressLabel ?? t("status.downloading"),
                            tint: progressTint ?? accent
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(width: cardWidth, alignment: .leading)
            }
            .frame(width: cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(hex: "1A1D24"))
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.18 : 0.08), lineWidth: isHovered ? 1.5 : 1)
            )
            .libraryCardHoverScale(isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .throttledHover(interval: 0.05) { hovering in
            if !isEditing {
                isPointerInside = hovering
                if hovering, LibraryScrollHoverGate.shared.suppressesAnimatedHover {
                    return
                }
                isHovered = hovering
            }
        }
        .libraryScrollIdleHoverProbe { inside in
            guard !isEditing else { return }
            isPointerInside = inside
            if inside {
                isHovered = true
            } else if isHovered {
                isHovered = false
            }
        }
        .onAppear {
            ensureLocalListThumbnail()
        }
        .onChange(of: localFileURL) { _, _ in
            cachedListThumbURL = nil
            ensureLocalListThumbnail()
        }
        .onDisappear {
            if let token = pendingLocalThumbnailIdleToken {
                LibraryScrollHoverGate.shared.cancelIdleWork(token: token)
                pendingLocalThumbnailIdleToken = nil
            }
        }
    }

    /// 外置原图 → 本机 SSD 512 列表缩略图；有远程 thumb 时列表先显示远程，滚停后再补本地缓存。
    @MainActor
    private func ensureLocalListThumbnail() {
        guard let local = localFileURL,
              local.isFileURL,
              LocalImageThumbnailCache.isRasterImageFile(local) else { return }

        if let token = pendingLocalThumbnailIdleToken {
            LibraryScrollHoverGate.shared.cancelIdleWork(token: token)
            pendingLocalThumbnailIdleToken = nil
        }

        if let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
            cachedListThumbURL = cached
            return
        }

        // 滚动中不生成：先靠远程 thumb / skeleton，滚停后再写 SSD
        if LibraryScrollHoverGate.shared.isScrolling {
            let token = UUID()
            pendingLocalThumbnailIdleToken = token
            LibraryScrollHoverGate.shared.runWhenIdle(token: token) {
                guard pendingLocalThumbnailIdleToken == token else { return }
                pendingLocalThumbnailIdleToken = nil
                guard let stillLocal = localFileURL,
                      stillLocal == local,
                      cachedListThumbURL == nil else { return }
                Task { @MainActor in
                    if LibraryScrollHoverGate.shared.isScrolling {
                        ensureLocalListThumbnail()
                        return
                    }
                    if let thumb = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: stillLocal) {
                        cachedListThumbURL = thumb
                    }
                }
            }
            return
        }

        Task { @MainActor in
            guard !LibraryScrollHoverGate.shared.isScrolling else { return }
            if let thumb = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: local) {
                cachedListThumbURL = thumb
            }
        }
    }

    private var topMetadataRow: some View {
        HStack(alignment: .top, spacing: 8) {
            metaTag(text: wallpaper.categoryDisplayName)
            metaTag(text: wallpaper.purityDisplayName)

            Spacer(minLength: 0)

            metaTag(text: wallpaper.resolution)
        }
    }

    private var trailingMetadataRow: some View {
        HStack(spacing: 5) {
            statLabel(
                systemImage: "heart.fill",
                value: compactNumber(wallpaper.favorites),
                tint: Color(hex: "FF5A7D")
            )

            statLabel(
                systemImage: "eye.fill",
                value: compactNumber(wallpaper.views),
                tint: .white.opacity(0.5)
            )

            if !wallpaper.fileSizeLabel.isEmpty {
                statLabel(
                    systemImage: "doc.fill",
                    value: wallpaper.fileSizeLabel,
                    tint: .white.opacity(0.5)
                )
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func metaTag(text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.3))
            )
    }

    private func statLabel(systemImage: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)

            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
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

// MARK: - Download Progress Block

public struct DownloadCardProgressBlock: View {
    let progress: Double
    let label: String
    let tint: Color

    private var clampedProgress: Double {
        max(0, min(progress, 1))
    }

    private var isCompleted: Bool {
        clampedProgress >= 1.0
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if !isCompleted {
                    Text("\(Int((clampedProgress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(tint.opacity(0.96))
                }
            }

            if !isCompleted {
                LiquidGlassLinearProgressBar(
                    progress: clampedProgress,
                    height: 6,
                    tintColor: tint,
                    trackOpacity: 0.15
                )
            }
        }
    }
}

// MARK: - 性能优化：scale + animation 永久挂载以保证平滑过渡
//
// ⚠️ 同 MediaCardView 注释：scaleEffect / animation 不能用 `@ViewBuilder if isHovered`
// 做条件挂载 —— SwiftUI 把结构变化看作 transition，只能做默认 opacity 动画，
// 没法在 1.0 ↔ 1.01 之间插值，hover 体感会变成生硬跳变。
//
// scaleEffect(1.0) 是 identity transform，SwiftUI 会优化掉矩阵运算；
// .animation 仅登记一个 value dependency，无实际变化时几乎零开销。
private extension View {
    func libraryCardHoverScale(isHovered: Bool) -> some View {
        self
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.easeOut(duration: 0.2), value: isHovered)
    }
}

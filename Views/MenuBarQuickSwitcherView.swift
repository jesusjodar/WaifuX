import AppKit
import SwiftUI
import Kingfisher

/// The existing compact glass browser, restricted to downloaded Wallhaven images.
struct MenuBarQuickSwitcherView: View {
    static let panelSize = NSSize(width: 370, height: 385)
    @ObservedObject var viewModel: MenuBarQuickSwitcherViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let heroWidth: CGFloat = 342
    private let heroHeight: CGFloat = 240
    private let heroActionGap: CGFloat = 8
    private let heroActionInset: CGFloat = 10
    private let heroActionButtonSize: CGFloat = 30
    private let thumbnailSize: CGFloat = 56
    private let thumbnailSpacing: CGFloat = 8
    private let thumbnailCorner: CGFloat = 10
    private let footerButtonHeight: CGFloat = 30
    private var heroShape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }
    private var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: 26, style: .continuous) }
    private var selectionSpring: Animation { reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.3, dampingFraction: 0.86) }
    private var crossfadeAnimation: Animation { .easeInOut(duration: reduceMotion ? 0.1 : 0.18) }
    var body: some View {
        ZStack {
            panelShape.fill(.ultraThinMaterial)
                .overlay { panelShape.fill(Color.primary.opacity(0.04)) }
                .overlay { panelShape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
            VStack(spacing: 12) {
                hero
                thumbnailRail
                footer
            }.padding(14)
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .clipShape(panelShape)
        .task(id: viewModel.previewWarmupToken) { await viewModel.warmVisiblePreviews() }
    }

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            if let selected = viewModel.selectedItem {
                // Fixed-size slot. Media is painted as an overlay so scaledToFill
                // cannot expand layout or poke past the rounded clip.
                Color.black.opacity(0.10)
                    .overlay {
                        QuickSwitcherImage(url: selected.thumbnailURL, fallbackSymbol: "photo", isActive: viewModel.isPresented)
                            .id(selected.id + (selected.thumbnailURL?.absoluteString ?? "") + "#\(viewModel.coverRevision(for: selected.id))")
                            .transition(.opacity)
                    }
                    .frame(width: heroWidth, height: heroHeight)
                    .clipped()
                    .clipShape(heroShape)
                    .contentShape(heroShape)
                    .overlay(alignment: .bottomLeading) {
                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.black.opacity(0.54), in: Capsule())
                                .padding(10)
                                .transition(
                                    .opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading))
                                )
                        } else if let status = viewModel.synchronizationStatus {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.white)
                                Text(status)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(2)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.54), in: Capsule())
                            .padding(10)
                            .accessibilityElement(children: .combine)
                            .transition(.opacity)
                        }
                    }
                    .overlay {
                        if viewModel.isBlockingApply {
                            ZStack {
                                Color.black.opacity(0.22)
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(.white)
                            }
                            .clipShape(heroShape)
                            .transition(.opacity)
                        }
                    }

                HStack(spacing: heroActionGap) {
                    heroActionButton(systemName: viewModel.isSelectedItemFavorite ? "heart.fill" : "heart", help: t(viewModel.isSelectedItemFavorite ? "menubar.quick.unfavorite" : "menubar.quick.favorite")) { viewModel.toggleFavorite() }
                    if viewModel.canOpenSelectedDetail {
                        heroActionButton(
                            systemName: "arrow.up.right.square",
                            help: t("statusbar.openCurrentWallpaper")
                        ) {
                            viewModel.openDetail()
                        }
                    }
                }
                .padding(heroActionInset)

                HStack(spacing: 8) {
                    heroActionButton(systemName: "backward.end.fill", help: t("menubar.quick.previous")) { viewModel.previousWallpaperForTargetScreen() }
                        .disabled(!viewModel.canGoPrevious)
                    heroActionButton(systemName: "forward.end.fill", help: t("statusbar.nextWallpaper")) { viewModel.nextWallpaperForTargetScreen() }
                        .disabled(!viewModel.canSwitchWallpaper)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 32, weight: .light))
                    Text(t("menubar.quick.empty"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(width: heroWidth, height: heroHeight)
                .background(Color.primary.opacity(0.06))
                .clipShape(heroShape)
            }
        }
        .frame(width: heroWidth, height: heroHeight)
        .clipShape(heroShape)
        .animation(crossfadeAnimation, value: viewModel.selectedItem?.id)
        .animation(crossfadeAnimation, value: viewModel.applyProgress.stage)
        .animation(crossfadeAnimation, value: viewModel.errorMessage)
    }

    private func heroActionButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: heroActionButtonSize, height: heroActionButtonSize)
                .modifier(HeroGlassCircleSurface())
        }
        .buttonStyle(QuickSwitcherPressButtonStyle())
        .help(help)
        .accessibilityLabel(Text(help))
        .disabled(viewModel.isApplying)
    }

    private var thumbnailRail: some View {
        NativeHorizontalThumbnailRail(
            selectedIndex: viewModel.batchItems.firstIndex {
                $0.id == viewModel.selectedItem?.id
            },
            itemStride: thumbnailSize + thumbnailSpacing,
            itemCount: viewModel.batchItems.count,
            isActive: viewModel.isPresented,
            contentSignature: railContentSignature,
            railMinimumHeight: thumbnailSize + 4
        ) {
            HStack(spacing: thumbnailSpacing) {
                ForEach(viewModel.batchItems) { item in
                    let isSelected = item.id == viewModel.selectedItem?.id
                    thumbnailChip(item: item, isSelected: isSelected)
                }
            }
            .padding(.horizontal, 1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: thumbnailSize + 4)
    }

    /// 轨道内容签名：chip 列表、缩略图、标题、选中项与禁用态。
    /// 弹窗里每次选中/预热回调都会触发 body 求值；无条件 `rootView = content` +
    /// `layoutSubtreeIfNeeded()` 会让「点缩略图切换」一顿一顿的。
    private var railContentSignature: Int {
        var hasher = Hasher()
        for item in viewModel.batchItems {
            hasher.combine(item.id)
            hasher.combine(item.thumbnailURL?.absoluteString)
            hasher.combine(item.title)
            hasher.combine(viewModel.coverRevision(for: item.id))
        }
        hasher.combine(viewModel.selectedItem?.id)
        hasher.combine(viewModel.isPresented)
        hasher.combine(viewModel.isBlockingApply)
        return hasher.finalize()
    }

    private func thumbnailChip(item: MenuBarQuickWallpaperItem, isSelected: Bool) -> some View {
        Button {
            // 不要用 withAnimation 包住 select：那会把整棵弹窗树（hero + 轨道 + footer）
            // 都卷进同一次 spring 事务里逐帧重排。选中态动画由 chip 自己的
            // `.animation(value: isSelected)` 与 hero 的 crossfade 各自负责。
            viewModel.select(item)
        } label: {
            Color.black.opacity(0.08)
                .overlay {
                    QuickSwitcherImage(url: item.thumbnailURL, fallbackSymbol: "photo", isActive: viewModel.isPresented)
                        .id((item.thumbnailURL?.absoluteString ?? "") + "#\(viewModel.coverRevision(for: item.id))")
                }
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: thumbnailCorner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: thumbnailCorner, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.white : Color.primary.opacity(0.08),
                            lineWidth: isSelected ? 2.5 : 0.6
                        )
                }
                .shadow(
                    color: isSelected ? .black.opacity(0.16) : .clear,
                    radius: isSelected ? 5 : 0,
                    y: isSelected ? 2 : 0
                )
                .scaleEffect(isSelected ? 1.0 : 0.97)
                .opacity(isSelected ? 1.0 : 0.92)
                .animation(selectionSpring, value: isSelected)
        }
        .buttonStyle(QuickSwitcherPressButtonStyle())
        .help(item.title)
        .disabled(viewModel.isBlockingApply)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(item.title)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                icon("gearshape", help: t("settings")) { viewModel.openSettings() }
                icon("arrow.clockwise", help: t("menubar.quick.refreshBatch")) { viewModel.refreshBatch() }
                icon("power", help: t("statusbar.quit")) { viewModel.quitApplication() }
            }
            Spacer(minLength: 0)
            Menu {
                Toggle(t("menubar.quick.myLibrary"), isOn: Binding(get: { viewModel.isUsingEntireLibrary }, set: { if $0 { viewModel.selectEntireLibrary() } }))
                Toggle(t("menubar.quick.rootFolder"), isOn: Binding(get: { viewModel.isUsingRootFolder }, set: { if $0 { viewModel.selectRootFolder() } }))
                if !viewModel.availableFolders.isEmpty {
                    Divider()
                    ForEach(viewModel.availableFolders) { folder in
                        Toggle(viewModel.folderOptionLabel(for: folder), isOn: Binding(get: { viewModel.isFolderSelected(folder.id) }, set: { _ in viewModel.toggleFolderSelection(folder.id) }))
                    }
                }
            } label: {
                Label(viewModel.selectedFolderLabel, systemImage: "folder")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .frame(width: 120, height: footerButtonHeight)
                    .background(.regularMaterial, in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .disabled(viewModel.isApplying)
            Button(t("setWallpaper")) { viewModel.applySelectedItem() }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: footerButtonHeight)
                .background(Color.black.opacity(0.92), in: Capsule())
                .buttonStyle(QuickSwitcherPressButtonStyle())
                .disabled(viewModel.selectedItem == nil || viewModel.isApplying)
        }.frame(height: footerButtonHeight)
    }
    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 13)).frame(width: 24, height: 30) }
            .buttonStyle(QuickSwitcherPressButtonStyle()).help(help)
            .disabled(viewModel.isApplying)
    }
}

struct HeroGlassCircleSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    Glass.regular.tint(Color.primary.opacity(0.05)),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                }
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                }
        }
    }
}

private struct QuickSwitcherPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(
                .spring(response: 0.22, dampingFraction: 0.78, blendDuration: 0),
                value: configuration.isPressed
            )
    }
}

@MainActor
private struct NativeHorizontalThumbnailRail<Content: View>: NSViewRepresentable {
    let content: Content
    /// 当前选中项在候选数组里的下标；变化时把它滚进可视区。
    let selectedIndex: Int?
    /// 单个 chip 的横向步进（宽 + 间距），用于按下标算滚动目标。
    let itemStride: CGFloat
    let itemCount: Int
    let isActive: Bool
    /// 轨道显示依赖的签名：相同就不重赋 rootView、不重排（切换选中不再整条重排）。
    let contentSignature: Int
    /// 轨道最小行高：与 SwiftUI 侧 `.frame(height: thumbnailSize + 4)` 对齐，
    /// 内容未加载时 documentView 不得塌成 0 高。
    let railMinimumHeight: CGFloat

    init(
        selectedIndex: Int?,
        itemStride: CGFloat,
        itemCount: Int,
        isActive: Bool,
        contentSignature: Int,
        railMinimumHeight: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.selectedIndex = selectedIndex
        self.itemStride = itemStride
        self.itemCount = itemCount
        self.isActive = isActive
        self.contentSignature = contentSignature
        self.railMinimumHeight = railMinimumHeight
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rootView: content)
    }

    func makeNSView(context: Context) -> VerticalWheelHorizontalScrollView {
        let scrollView = VerticalWheelHorizontalScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = context.coordinator.hostingView
        scrollView.setInteractionActive(isActive)
        return scrollView
    }

    func updateNSView(_ scrollView: VerticalWheelHorizontalScrollView, context: Context) {
        let hostingView = context.coordinator.hostingView
        scrollView.setInteractionActive(isActive)
        let updateStart = Date()
        let signatureChanged = context.coordinator.lastContentSignature != contentSignature
        if signatureChanged {
            context.coordinator.lastContentSignature = contentSignature
            hostingView.rootView = content
        }

        // 打开弹窗时默认选中的是「当前壁纸」，它可能落在轨道可视区之外
        // （例如在所属文件夹内被随机排到中段），这里只在选中项变化时补一次滚动。
        var shouldRevealSelectedItem = false
        if let selectedIndex, context.coordinator.lastRevealedIndex != selectedIndex {
            context.coordinator.lastRevealedIndex = selectedIndex
            shouldRevealSelectedItem = true
        }
        guard signatureChanged || shouldRevealSelectedItem else { return }
        let revealIndex = shouldRevealSelectedItem ? selectedIndex : nil
        let stride = itemStride
        let updateNumber = context.coordinator.updateCount

        DispatchQueue.main.async {
            guard scrollView.documentView === hostingView else { return }
            if signatureChanged {
                // Chips have a fixed size. Never force SwiftUI fitting/layout for image updates.
                let size = NSSize(width: max(CGFloat(itemCount) * itemStride - 6, scrollView.contentSize.width),
                                  height: max(railMinimumHeight, scrollView.contentSize.height))
                if hostingView.frame.size != size { hostingView.setFrameSize(size) }
            }
            if let revealIndex {
                scrollView.revealItem(at: revealIndex, stride: stride)
            }
            // 切换选中/换批时量一次「body 求值 → 轨道布局完成」的主线程耗时。
            AppLogger.debug(.general, "菜单栏轨道更新耗时", metadata: [
                "layoutMS": String(Int(Date().timeIntervalSince(updateStart) * 1000)),
                "changed": signatureChanged ? "1" : "0",
                "count": String(updateNumber),
            ])
        }
        context.coordinator.updateCount += 1
    }

    @MainActor
    final class Coordinator {
        let hostingView: NSHostingView<Content>
        /// 上一次已经滚动到过的选中下标，避免每次 body 更新都强制滚动。
        var lastRevealedIndex: Int?
        var lastContentSignature: Int?
        var updateCount = 0

        init(rootView: Content) {
            hostingView = NSHostingView(rootView: rootView)
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

private final class VerticalWheelHorizontalScrollView: NSScrollView {
    private var dragStartLocation: NSPoint?
    private var dragStartOffset: CGFloat = 0
    private var isDraggingRail = false
    private var dragMonitor: Any?
    private var interactionActive = false

    func setInteractionActive(_ active: Bool) {
        interactionActive = active
        if active { installDragMonitorIfNeeded() }
        else {
            removeDragMonitor()
            dragStartLocation = nil
            isDraggingRail = false
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installDragMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeDragMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        MainActor.assumeIsolated {
            removeDragMonitor()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let documentView else {
            super.scrollWheel(with: event)
            return
        }

        let viewportWidth = contentView.bounds.width
        let maxOffset = max(0, documentView.frame.width - viewportWidth)
        guard maxOffset > 0 else {
            super.scrollWheel(with: event)
            return
        }

        let rawDelta: CGFloat
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            // AppKit deltas already respect the system's natural-scrolling setting.
            // Moving the clip-view origin must use the opposite sign, matching NSScrollView.
            rawDelta = -event.scrollingDeltaX
        } else {
            rawDelta = -event.scrollingDeltaY
        }
        guard abs(rawDelta) > 0.001 else { return }

        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 24
        var origin = contentView.bounds.origin
        origin.x = min(max(origin.x + rawDelta * multiplier, 0), maxOffset)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private func installDragMonitorIfNeeded() {
        guard interactionActive, dragMonitor == nil, window != nil else { return }
        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, self.interactionActive, self.window?.isVisible == true,
                  event.window === self.window else { return event }
            return self.handleDragEvent(event)
        }
    }

    private func removeDragMonitor() {
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
    }

    private func handleDragEvent(_ event: NSEvent) -> NSEvent? {
        let location = convert(event.locationInWindow, from: nil)

        switch event.type {
        case .leftMouseDown:
            guard bounds.contains(location) else { return event }
            dragStartLocation = location
            dragStartOffset = contentView.bounds.origin.x
            isDraggingRail = false
            return event

        case .leftMouseDragged:
            guard let dragStartLocation else { return event }
            let delta = location.x - dragStartLocation.x
            if !isDraggingRail, abs(delta) >= 3 {
                isDraggingRail = true
            }
            guard isDraggingRail else { return event }

            scrollHorizontally(to: dragStartOffset - delta)
            return nil

        case .leftMouseUp:
            guard self.dragStartLocation != nil else { return event }
            let shouldConsume = isDraggingRail
            dragStartLocation = nil
            isDraggingRail = false
            return shouldConsume ? nil : event

        default:
            return event
        }
    }

    private func scrollHorizontally(to requestedOffset: CGFloat) {
        guard let documentView else { return }
        let maxOffset = max(0, documentView.frame.width - contentView.bounds.width)
        var origin = contentView.bounds.origin
        origin.x = min(max(requestedOffset, 0), maxOffset)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    /// 把某个 chip 滚进可视区（左对齐语义）：只有它在可视区外时才滚动，
    /// 且滚到刚好完整露出它的最小偏移——轨道默认从最左开始展示，
    /// 内容不足以滚动时保持原位，不做视觉居中。
    func revealItem(at index: Int, stride: CGFloat) {
        guard let documentView, stride > 0 else { return }
        let viewportWidth = contentView.bounds.width
        let maxOffset = max(0, documentView.frame.width - viewportWidth)
        guard maxOffset > 0 else { return }
        let itemStart = CGFloat(index) * stride
        let itemEnd = itemStart + stride
        let currentOffset = contentView.bounds.origin.x
        // 完整可见（含一格余量）就不动，避免用户手动滚动后被抢回。
        guard itemStart < currentOffset
                || itemEnd > currentOffset + viewportWidth else {
            return
        }
        // 目标：让该 chip 尽量靠视口左侧完整露出。
        let targetOffset = min(max(itemStart, 0), maxOffset)
        contentView.scroll(to: NSPoint(x: targetOffset, y: contentView.bounds.origin.y))
        reflectScrolledClipView(contentView)
    }
}

// MARK: - Image

private struct QuickSwitcherImage: View {
    let url: URL?
    let fallbackSymbol: String
    let isActive: Bool

    var body: some View {
        Group {
            if let url, isActive {
                KFImage(source: url.isFileURL ? .provider(LocalFileImageDataProvider(fileURL: url)) : .network(KF.ImageResource(downloadURL: url)))
                    .fade(duration: 0.16)
                    // chip 56px / hero 342pt@2x=684 —— 768 上限足够，避免把外置盘
                    // 几 MB~几十 MB 的原图全尺寸解码（2026-10-13 弹窗出图慢的
                    // 静图侧主因）。macOS 无 UIScreen；菜单栏面板 Retina 最高 2x，
                    // downsampling 按像素吃 768 已覆盖。
                    .downsampling(size: CGSize(width: 768, height: 768))
                    .backgroundDecode()
                    .cancelOnDisappear(true)
                    .resizable()
                    .placeholder {
                        placeholder
                    }
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        // Fill the parent-proposed size (overlay/frame), then clip overflow.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            Color.black.opacity(0.18)
            Image(systemName: fallbackSymbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white.opacity(0.72))
        }
    }
}

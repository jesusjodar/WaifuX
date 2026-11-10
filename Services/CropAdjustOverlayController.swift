import AppKit
import CoreGraphics

/// 桌面可视区域调节 overlay：每屏一个全屏窗口，拖拽平移、滚轮缩放、ESC 退出。
/// overlay 自带预览渲染，不依赖实际壁纸层；退出时生成并应用静态派生图。
@MainActor
final class CropAdjustOverlayController {
    static let shared = CropAdjustOverlayController()

    private var windowsByScreenID: [String: NSWindow] = [:]
    private weak var statusItem: NSStatusItem?
    private var escapeMonitor: Any?
    /// overlay 已关但同一次 ESC 还在其它 local monitor 里时，仍拦截页面返回。
    private var eatingEscape = false

    private init() {}

    // MARK: - Public

    var isAdjusting: Bool { !windowsByScreenID.isEmpty || eatingEscape }

    func isActive(for screen: NSScreen) -> Bool {
        windowsByScreenID[screen.wallpaperScreenIdentifier] != nil
    }

    /// ESC 只关裁切 overlay，不把事件交给详情页/文件夹返回。
    func dismissIfActive() {
        guard isAdjusting else { return }
        eatingEscape = true
        for screen in NSScreen.screens where windowsByScreenID[screen.wallpaperScreenIdentifier] != nil {
            exit(for: screen)
        }
        DispatchQueue.main.async { [weak self] in
            self?.eatingEscape = false
        }
    }

    func toggle(for screen: NSScreen, statusBarItemRef: NSStatusItem?) {
        self.statusItem = statusBarItemRef
        if isActive(for: screen) {
            exit(for: screen)
        } else {
            enter(for: screen)
        }
    }

    // MARK: - Enter / Exit

    private func enter(for screen: NSScreen) {
        let screenID = screen.wallpaperScreenIdentifier
        guard windowsByScreenID[screenID] == nil else { return }

        DisplayCropSettingsStore.shared.reloadFromPreferences()
        // contentRect + screen treats contentRect as relative to that screen.
        // Passing a global frame would double the external display origin.
        let window = CropAdjustOverlayWindow(
            contentRect: NSRect(origin: .zero, size: screen.frame.size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen)
        window.setFrame(screen.frame, display: true)
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let view = CropAdjustOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen)
        view.onSettingsChanged = { [weak self] in
            // 触发菜单刷新（更新比例打勾等）
            self?.statusItem?.button?.needsDisplay = true
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        windowsByScreenID[screenID] = window
        installEscapeMonitorIfNeeded()
    }

    private func exit(for screen: NSScreen) {
        let screenID = screen.wallpaperScreenIdentifier
        // 退出调节：保存并应用最终静态裁切
        DisplayCropSettingsStore.shared.commitInteractive(for: screen)
        if let window = windowsByScreenID.removeValue(forKey: screenID) {
            window.orderOut(nil)
        }
        removeEscapeMonitorIfNeeded()
    }

    private func installEscapeMonitorIfNeeded() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, CropAdjustOverlayController.shared.isAdjusting else {
                return event
            }
            CropAdjustOverlayController.shared.dismissIfActive()
            return nil
        }
    }

    private func removeEscapeMonitorIfNeeded() {
        guard windowsByScreenID.isEmpty, let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    /// Static crop previews use the verified original image dimensions.
    static func wallpaperSize(for screen: NSScreen) -> CGSize? {
        guard let current = CurrentWallpaperService.shared.activeURL(for: screen.wallpaperScreenIdentifier) else { return nil }
        let original = DesktopWallpaperSyncManager.shared.originalSourceURL(for: current)
        guard let record = WallpaperLibraryService.shared.downloadRecord(forLocalFilePath: original.path) else { return nil }
        return CGSize(width: record.wallpaper.dimensionX, height: record.wallpaper.dimensionY)
    }

}

/// overlay 窗口：ESC 退出。
private final class CropAdjustOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            CropAdjustOverlayController.shared.dismissIfActive()
            return
        }
        super.keyDown(with: event)
    }
}

/// overlay 视图：预览 + 拖拽/滚轮手势。
private final class CropAdjustOverlayView: NSView {
    private let screen: NSScreen
    private var lastDragLocation: NSPoint?
    private var previewImage: CGImage?
    var onSettingsChanged: (() -> Void)?

    init(frame: NSRect, screen: NSScreen) {
        self.screen = screen
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        renderPreview()
        if let current = CurrentWallpaperService.shared.activeURL(for: screen.wallpaperScreenIdentifier) {
            let original = DesktopWallpaperSyncManager.shared.originalSourceURL(for: current)
            if WallpaperLibraryService.shared.downloadRecord(forLocalFilePath: original.path) != nil {
                Task { [weak self] in
                    let result = await Task.detached(priority: .userInitiated) {
                        WallpaperBoundedImageDecoder.decode(url: original)
                    }.value
                    guard let self, case .success(let decoded) = result else { return }
                    previewImage = decoded.image
                    renderPreview()
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 预览渲染

    /// Static preview uses the same crop geometry as the committed derivative.
    private func renderPreview() {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }

        let settings = DisplayCropSettingsStore.shared.settings(for: screen)
        let wallpaperSize = previewImage.map { CGSize(width: $0.width, height: $0.height) }
            ?? CropAdjustOverlayController.wallpaperSize(for: screen) ?? screen.frame.size
        let layout = CropLayoutEngine.compute(
            wallpaperSize: wallpaperSize,
            screenSize: screen.frame.size,
            settings: settings)

        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // 可视框像素矩形
        let vp = CGRect(
            x: layout.viewportRect.x * bounds.width,
            y: (1.0 - layout.viewportRect.y - layout.viewportRect.h) * bounds.height,
            width: layout.viewportRect.w * bounds.width,
            height: layout.viewportRect.h * bounds.height)

        if let image = previewImage {
            layer?.backgroundColor = layout.letterboxColor
            let rect = layout.wallpaperCropRect
            let cropped = image.cropping(to: CGRect(x: rect.x * Double(image.width), y: rect.y * Double(image.height),
                width: rect.w * Double(image.width), height: rect.h * Double(image.height)))
            let photo = CALayer()
            photo.frame = vp
            photo.contents = cropped
            photo.contentsGravity = .resize
            layer?.addSublayer(photo)
        }

        // 框外暗化：全屏半透明填充 + viewport 区域挖空，叠加在真实壁纸上。
        // 使用 CGPath 的 evenOdd 填充规则：outer rect + inner rect = 框外着色。
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        dimPath.addRect(vp)
        let dimLayer = CAShapeLayer()
        dimLayer.path = dimPath
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor(white: 0, alpha: 0.25).cgColor
        layer?.addSublayer(dimLayer)

        // 可视框虚线边框
        let border = CAShapeLayer()
        border.path = CGPath(rect: vp, transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.systemYellow.cgColor
        border.lineWidth = 2
        border.lineDashPattern = [6, 4]
        layer?.addSublayer(border)

        // 提示文字
        let text = CATextLayer()
        text.string = LocalizationService.shared.t("拖动平移 · 滚轮缩放 · ESC 退出")
        text.foregroundColor = NSColor.white.cgColor
        text.fontSize = 16
        text.alignmentMode = .center
        text.frame = CGRect(x: 0, y: bounds.midY - 40, width: bounds.width, height: 24)
        text.contentsScale = window?.screen?.backingScaleFactor ?? 2
        // 文字加阴影以便在亮色壁纸上可见
        text.shadowColor = NSColor.black.cgColor
        text.shadowOpacity = 0.8
        text.shadowOffset = CGSize(width: 0, height: -1)
        text.shadowRadius = 3
        layer?.addSublayer(text)
    }

    // MARK: - 手势
    // pan ∈ [0,1]，0.5=居中（见 DisplayCropSettings.pan 文档）。
    // 拖拽采用「画面跟手」隐喻：拖右 → 壁纸右移 → 看壁纸左侧 → pan.x 减小；
    // 拖上（屏幕坐标 y 向上）→ 壁纸上移 → 看壁纸下方 → pan.y 增大。

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDragLocation else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - last.x
        let dy = current.y - last.y
        lastDragLocation = current

        // 画面跟手：拖右 → 壁纸右移 → 看到壁纸左侧 → pan.x 减小。
        // 拖上（dy>0）→ 壁纸上移 → 看到壁纸下方 → pan.y 增大。
        // 灵敏度：拖动半个屏宽 = pan 从 0 走到 1。
        let sensitivity = max(1, bounds.width / 2)
        // interactive=true：仅更新本地预览
        DisplayCropSettingsStore.shared.update(for: screen, interactive: true) { s in
            s.isEnabled = true
            s.pan.x = max(0, min(1, s.pan.x - dx / sensitivity))
            s.pan.y = max(0, min(1, s.pan.y + dy / sensitivity))
        }
        renderPreview()
        onSettingsChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        lastDragLocation = nil
        scrollCommitWorkItem?.cancel()
        // 拖拽结束：落定一次（保存并应用静态裁切）
        DisplayCropSettingsStore.shared.commitInteractive(for: screen)
    }

    private func commitZoomInteraction() {
        DisplayCropSettingsStore.shared.commitInteractive(for: screen)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.deltaY
        guard delta != 0 else { return }
        // 滚轮也是 interactive，避免每个 tick 重写桌面图
        DisplayCropSettingsStore.shared.update(for: screen, interactive: true) { s in
            s.isEnabled = true
            s.zoom = max(1.0, min(4.0, s.zoom * (1 + delta * 0.03)))
        }
        renderPreview()
        onSettingsChanged?()
        // 滚轮通常无明确"释放"事件，用 phase=.ended 判断；否则用 debounce
        if event.phase == .ended || event.momentumPhase == .ended {
            commitZoomInteraction()
        } else {
            scheduleScrollCommit()
        }
    }

    /// 触摸板双指 pinch。NSEvent.magnification 在 macOS 上是相对变化量，
    /// 连续手势期间只更新内存态，结束时一次性保存并应用。
    override func magnify(with event: NSEvent) {
        let magnification = event.magnification
        guard magnification != 0 else {
            if event.phase == .ended || event.phase == .cancelled {
                commitZoomInteraction()
            }
            return
        }
        DisplayCropSettingsStore.shared.update(for: screen, interactive: true) { s in
            s.isEnabled = true
            let multiplier = max(0.01, 1 + magnification)
            s.zoom = max(1.0, min(4.0, s.zoom * multiplier))
        }
        renderPreview()
        onSettingsChanged?()
        if event.phase == .ended || event.phase == .cancelled {
            commitZoomInteraction()
        } else {
            scheduleMagnifyCommit()
        }
    }

    private var scrollCommitWorkItem: DispatchWorkItem?
    private func scheduleScrollCommit() {
        scrollCommitWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            DisplayCropSettingsStore.shared.commitInteractive(for: self.screen)
        }
        scrollCommitWorkItem = item
        // 滚动停止 250ms 后落定
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func scheduleMagnifyCommit() {
        scheduleScrollCommit()
    }
}

import AppKit
import Combine
import Kingfisher
import QuartzCore
import SwiftUI

@MainActor
final class MenuBarQuickSwitcherController: NSObject {
    private let contentSize = MenuBarQuickSwitcherView.panelSize
    private let viewModel = MenuBarQuickSwitcherViewModel()
    private let panel: MenuBarQuickSwitcherPanel
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var presentationGeneration = 0
    private var prewarmSubscription: AnyCancellable?
    private var prewarmWorkItem: DispatchWorkItem?
    private var isDismissing = false
    private weak var statusAnchorView: NSView?
    private var presentationAnchorX: CGFloat = 0.5
    private let presentationAnimationKey = "quickSwitcher.presentation"

    override init() {
        panel = MenuBarQuickSwitcherPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false

        viewModel.onApplied = { [weak self] in
            self?.dismiss()
        }
    }

    private func mountContentIfNeeded() {
        guard panel.contentViewController == nil else { return }

        let hostingController = NSHostingController(
            rootView: MenuBarQuickSwitcherView(viewModel: viewModel)
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = hostingController
    }

    func toggle(
        relativeTo anchorView: NSView,
        targetScreen: NSScreen?,
        currentWallpaperURL: URL?,
        onOpenSettings: @escaping () -> Void,
        onOpenDetail: @escaping (MainWallpaperDetailRequest) -> Void,
        onQuit: @escaping () -> Void
    ) {
        if dismissForStatusItemClick() { return }

        statusAnchorView = anchorView
        isDismissing = false
        panel.ignoresMouseEvents = false
        presentationGeneration &+= 1
        viewModel.onOpenSettings = { [weak self] in
            self?.dismiss()
            onOpenSettings()
        }
        viewModel.onOpenDetail = { [weak self] request in
            self?.dismiss()
            onOpenDetail(request)
        }
        viewModel.onQuitApplication = onQuit
        let performanceStart = ProcessInfo.processInfo.systemUptime
        let prepareStart = Date()
        viewModel.prepare(
            targetScreen: targetScreen,
            currentWallpaperURL: currentWallpaperURL
        )
        let prepareDone = Date()
        mountContentIfNeeded()
        let mountDone = Date()

        positionPanel(relativeTo: anchorView, on: targetScreen)
        preparePresentationLayer()
        panel.alphaValue = 1
        // A nonactivating panel can become key for input without making WaifuX the
        // foreground application, so background Screen Time does not resume here.
        panel.makeKeyAndOrderFront(nil)
        animatePresentation(visible: true)
        let frontDone = Date()
        installDismissMonitors()
        InteractionPerformanceLog.record(.menuOpen, since: performanceStart, metadata: [
            "phase": "orderFront", "batch": String(viewModel.batchItems.count),
            "indexReady": MenuBarQuickWallpaperRepository.shared.isReady ? "1" : "0"
        ])

        // 「点开菜单栏要等一等」的分段耗时：prepare（数据/当前壁纸定位）、
        // mount（NSHostingController + SwiftUI 树重建）、front（panel 可见）。
        AppLogger.debug(.general, "状态栏左键弹窗打开耗时", metadata: [
            "prepareMS": String(Int(prepareDone.timeIntervalSince(prepareStart) * 1000)),
            "mountMS": String(Int(mountDone.timeIntervalSince(prepareDone) * 1000)),
            "frontMS": String(Int(frontDone.timeIntervalSince(mountDone) * 1000)),
            "dataMS": String(viewModel.lastDataDurationMS),
            "currentMS": String(viewModel.lastCurrentLookupMS),
            "repoHit": viewModel.lastRepositoryCacheHit ? "1" : "0",
            "repoBuildMS": String(viewModel.lastRepositoryBuildMS),
            "batch": String(viewModel.batchItems.count),
        ])
    }

    /// Build the small static hosting tree once, outside the first click.
    func prewarm() {
        guard !panel.isVisible else { return }
        viewModel.prewarmCandidates()
        mountContentIfNeeded()
        panel.contentView?.layoutSubtreeIfNeeded()
        guard prewarmSubscription == nil else { return }
        prewarmSubscription = MenuBarQuickWallpaperRepository.shared.changes.sink { [weak self] in
            guard let self, !self.panel.isVisible else { return }
            self.prewarmWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.panel.isVisible else { return }
                self.viewModel.prewarmCandidates()
                self.panel.contentView?.layoutSubtreeIfNeeded()
            }
            self.prewarmWorkItem = work
            DispatchQueue.main.async(execute: work)
        }
    }



    /// A click on an already-visible menu belongs to its close, including its exit.
    /// Check this before preparing wallpaper/design metadata in the status action.
    @discardableResult
    func dismissForStatusItemClick() -> Bool {
        guard panel.isVisible || isDismissing || viewModel.isPresented else { return false }
        dismiss()
        return true
    }

    func dismiss() {
        guard !isDismissing, panel.isVisible || viewModel.isPresented else { return }
        removeDismissMonitors()
        isDismissing = true
        presentationGeneration &+= 1
        panel.ignoresMouseEvents = true
        // Stop decoding immediately, but keep covers mounted until the exit finishes.
        viewModel.suspendPreviewWork(keepingPresentation: true)
        animatePresentation(visible: false)
    }

    private var collapsedTransform: CATransform3D {
        // Keep the point beneath the status item stationary, even near screen edges.
        // A transform changes no AppKit frames and causes no SwiftUI relayout.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return CATransform3DIdentity }
        let scale: CGFloat = 0.94
        let layer = panel.contentView?.layer
        let anchor = layer?.anchorPoint ?? .zero
        let pivotX = (presentationAnchorX - anchor.x) * contentSize.width
        let isFlipped = panel.contentView?.isFlipped ?? false
        let pivotY = ((isFlipped ? 0 : 1) - anchor.y) * contentSize.height
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation(pivotX * (1 - scale), pivotY * (1 - scale), 0))
    }

    private func preparePresentationLayer() {
        guard let layer = panel.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: presentationAnimationKey)
        layer.transform = collapsedTransform
        layer.opacity = 0
        CATransaction.commit()
    }

    private func animatePresentation(visible: Bool) {
        let generation = presentationGeneration
        guard let layer = panel.contentView?.layer else {
            if !visible { finishDismissal(generation: generation) }
            return
        }
        // A hidden, prewarmed layer can still have an old presentation value.
        // Only an in-flight transition should supply the starting screen value.
        let current = layer.animation(forKey: presentationAnimationKey) != nil
            ? (layer.presentation() ?? layer) : layer
        let fromTransform = current.transform
        let fromOpacity = current.opacity
        let targetTransform = visible ? CATransform3DIdentity : collapsedTransform
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration: TimeInterval = reducedMotion ? 0.08 : (visible ? 0.18 : 0.13)
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: fromTransform)
        transform.toValue = NSValue(caTransform3D: targetTransform)
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = fromOpacity
        opacity.toValue = visible ? Float(1) : Float(0)
        transform.duration = duration
        opacity.duration = duration
        let group = CAAnimationGroup()
        group.animations = [transform, opacity]
        group.duration = duration
        group.timingFunction = visible
            ? CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            : CAMediaTimingFunction(controlPoints: 0.2, 0, 0.6, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !visible {
            CATransaction.setCompletionBlock { [weak self] in
                // Core Animation calls completion after replacement as well as completion.
                // The presentation generation prevents an old close hiding a new open.
                Task { @MainActor [weak self] in
                    self?.finishDismissal(generation: generation)
                }
            }
        }
        layer.transform = targetTransform
        layer.opacity = visible ? 1 : 0
        layer.add(group, forKey: presentationAnimationKey)
        CATransaction.commit()
    }

    private func finishDismissal(generation: Int) {
        guard presentationGeneration == generation, isDismissing else { return }
        panel.orderOut(nil)
        viewModel.finishHidingPresentation()
        isDismissing = false
        panel.ignoresMouseEvents = false
    }

    private func positionPanel(relativeTo anchorView: NSView, on screen: NSScreen?) {
        guard let anchorWindow = anchorView.window else {
            panel.center()
            return
        }

        let anchorRect = anchorView.convert(anchorView.bounds, to: nil)
        let screenRect = anchorWindow.convertToScreen(anchorRect)
        let visibleFrame = (screen ?? anchorWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? .zero

        var origin = NSPoint(
            x: screenRect.midX - (contentSize.width / 2),
            y: screenRect.minY - contentSize.height - 10
        )
        origin.x = min(
            max(origin.x, visibleFrame.minX + 12),
            max(visibleFrame.minX + 12, visibleFrame.maxX - contentSize.width - 12)
        )
        origin.y = max(visibleFrame.minY + 12, origin.y)

        panel.setFrame(NSRect(origin: origin, size: contentSize), display: false)
        presentationAnchorX = min(max((screenRect.midX - origin.x) / contentSize.width, 0), 1)
    }

    private func isStatusItemMouseDown(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown || event.type == .rightMouseDown,
              let anchor = statusAnchorView, let window = anchor.window else { return false }
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        // Status-item input may arrive through a system window/global monitor.
        // A windowless event already carries screen coordinates.
        let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
            ?? event.locationInWindow
        return frame.contains(location)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }

            if event.type == .keyDown, event.keyCode == 53 {
                self.dismiss()
                return nil
            }

            if self.isStatusItemMouseDown(event) {
                // The status item's mouseUp action owns the toggle. Dismissing on
                // mouseDown would turn that same click into a mid-exit reopen.
                return event
            }
            if event.window !== self.panel { self.dismiss() }
            return event
        }

        let generation = presentationGeneration
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // AppKit invokes event monitors on the main thread. Capture the hit now;
            // a later cursor position could belong to a different click.
            let isStatusItemClick = MainActor.assumeIsolated {
                self?.isStatusItemMouseDown(event) ?? false
            }
            guard !isStatusItemClick else { return }
            DispatchQueue.main.async {
                guard let self, self.presentationGeneration == generation else { return }
                self.dismiss()
            }
        }
    }

    private func removeDismissMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }
}

private final class MenuBarQuickSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MenuBarQuickSwitcherViewModel: ObservableObject {
    static let batchSize = 16
    @Published private(set) var batchItems: [MenuBarQuickWallpaperItem] = []
    @Published private(set) var selectedItem: MenuBarQuickWallpaperItem?
    @Published private(set) var selectedFolderIDs: [String]?
    @Published private(set) var applyProgress = WallpaperApplyProgressState()
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPresented = false
    @Published private(set) var previewWarmupToken = UUID()
    var isApplying: Bool { applyProgress.isApplying }
    var isBlockingApply: Bool { applyProgress.isBlocking }
    var isPreviewActive: Bool { isPresented }
    var synchronizationStatus: String? { isApplying ? t("menubar.quick.syncingWallpaper") : nil }
    var onOpenSettings: (() -> Void)?
    var onApplied: (() -> Void)?
    var onOpenDetail: ((MainWallpaperDetailRequest) -> Void)?
    var onQuitApplication: (() -> Void)?
    private var targetScreenID: String?
    private var targetScreenFingerprint: String?
    private var currentURL: URL?
    private var userSelected = false
    private var subscriptions = Set<AnyCancellable>()
    private var identityTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var activation: UInt64 = 0
    private(set) var lastDataDurationMS = 0
    var lastCurrentLookupMS: Int { MenuBarQuickWallpaperRepository.shared.lastCurrentLookupMS }
    var lastRepositoryBuildMS: Int { MenuBarQuickWallpaperRepository.shared.lastBuildDurationMS }
    var lastRepositoryCacheHit: Bool { MenuBarQuickWallpaperRepository.shared.isReady }
    private let repository = MenuBarQuickWallpaperRepository.shared

    init() {
        repository.changes.sink { [weak self] in self?.reconcileBatch() }.store(in: &subscriptions)
        WallpaperLibraryService.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        CurrentWallpaperService.shared.$activeURLByScreenID.receive(on: DispatchQueue.main).sink { [weak self] urls in
            guard let self, isPresented, let screen = resolvedTargetScreen() else { return }
            currentURL = urls[screen.wallpaperScreenIdentifier]
            resolveCurrentSelection()
            objectWillChange.send()
        }.store(in: &subscriptions)
    }
    func prewarmCandidates() {
        repository.start()
        if batchItems.isEmpty { replaceBatch(avoidingPrevious: false) }
    }
    func prepare(targetScreen: NSScreen?, currentWallpaperURL: URL?) {
        activation &+= 1
        isPresented = true
        targetScreenID = targetScreen?.wallpaperScreenIdentifier
        targetScreenFingerprint = targetScreen?.wallpaperScreenFingerprint
        currentURL = currentWallpaperURL
        userSelected = false
        errorMessage = nil
        let scheduler = WallpaperSchedulerService.shared
        let saved = StaticQuickFolderSelectionStore.load(scope: folderScope)
        selectedFolderIDs = saved.found ? saved.ids : targetScreen.map { scheduler.resolvedDisplayConfig(for: $0).folderIDs } ?? nil
        let start = ProcessInfo.processInfo.systemUptime
        replaceBatch(avoidingPrevious: false)
        lastDataDurationMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        resolveCurrentSelection()
    }
    private var folderScope: String {
        WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled ? "global" : "display:\(targetScreenFingerprint ?? "default")"
    }
    private func resolvedTargetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard let fingerprint = targetScreenFingerprint else { return screens.first }
        guard let index = WallpaperScreenIdentity.commandTargetIndex(identifier: targetScreenID, fingerprint: fingerprint,
            screens: screens.map { ($0.wallpaperScreenIdentifier, $0.wallpaperScreenFingerprint) }) else { return nil }
        return screens[index]
    }
    var isSelectedItemFavorite: Bool { selectedItem.map { WallpaperLibraryService.shared.isFavorite($0.wallpaper) } ?? false }
    var canOpenSelectedDetail: Bool { selectedItem != nil }
    var canSwitchWallpaper: Bool { resolvedTargetScreen().map { WallpaperSchedulerService.shared.hasSchedulableItems(for: $0.wallpaperScreenIdentifier) } ?? false }
    var canGoPrevious: Bool { resolvedTargetScreen().map { WallpaperSchedulerService.shared.hasWallpaperHistory(for: $0.wallpaperScreenIdentifier) } ?? false }
    var isUsingEntireLibrary: Bool { selectedFolderIDs == nil }
    var isUsingRootFolder: Bool { selectedFolderIDs?.isEmpty == true }
    var availableFolders: [LibraryFolder] {
        LibraryFolderStore.shared.wallpaperFolders.filter { $0.collection == .downloads && repository.folderIsVisible($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var selectedFolderLabel: String {
        guard let ids = selectedFolderIDs else { return t("menubar.quick.myLibrary") }
        if ids.isEmpty { return t("menubar.quick.rootFolder") }
        let names = ids.compactMap { id in availableFolders.first { $0.id == id }?.name }
        if names.isEmpty { return t("menubar.quick.unavailableFolder") }
        return names.count == 1 ? names[0] : "\(names[0]) +\(names.count - 1)"
    }
    func folderOptionLabel(for folder: LibraryFolder) -> String { folder.name }
    func isFolderSelected(_ id: String) -> Bool { selectedFolderIDs?.contains(id) == true }
    func selectEntireLibrary() { updateFolderSelection(nil) }
    func selectRootFolder() { updateFolderSelection([]) }
    func toggleFolderSelection(_ id: String) {
        var ids = Set(selectedFolderIDs ?? [])
        if !ids.insert(id).inserted { ids.remove(id) }
        updateFolderSelection(ids.isEmpty ? nil : ids.sorted())
    }
    private func updateFolderSelection(_ ids: [String]?) {
        selectedFolderIDs = ids
        StaticQuickFolderSelectionStore.save(ids, scope: folderScope)
        let scheduler = WallpaperSchedulerService.shared
        if scheduler.isGlobalDisplaySyncEnabled { scheduler.updateGlobalDisplayFolderIDs(ids) }
        else if let screen = resolvedTargetScreen() { scheduler.updateDisplayFolderIDs(ids, for: screen.wallpaperScreenIdentifier) }
        userSelected = false
        replaceBatch(avoidingPrevious: false)
        resolveCurrentSelection()
    }
    func coverRevision(for id: String) -> Int { repository.previewRevision(for: id) }
    func select(_ item: MenuBarQuickWallpaperItem) {
        guard !isBlockingApply, repository.contains(item, folderIDs: selectedFolderIDs) else { return }
        selectedItem = item; userSelected = true; errorMessage = nil
    }
    func refreshBatch() { userSelected = false; replaceBatch(avoidingPrevious: true); resolveCurrentSelection() }
    private func replaceBatch(avoidingPrevious: Bool) {
        let old = Set(batchItems.map(\.id))
        batchItems = repository.sample(folderIDs: selectedFolderIDs, excluding: avoidingPrevious ? old : [], limit: Self.batchSize)
        selectedItem = batchItems.first
        previewWarmupToken = UUID()
    }
    private func reconcileBatch() {
        batchItems = batchItems.compactMap { repository.item(id: $0.id) }.filter { repository.contains($0, folderIDs: selectedFolderIDs) }
        if let selectedItem, !batchItems.contains(where: { $0.id == selectedItem.id }) { self.selectedItem = nil }
        if batchItems.isEmpty { replaceBatch(avoidingPrevious: false) }
        else if selectedItem == nil { selectedItem = batchItems.first }
        previewWarmupToken = UUID()
        if isPresented, !userSelected { resolveCurrentSelection() }
        objectWillChange.send()
    }
    private func resolveCurrentSelection() {
        identityTask?.cancel()
        guard let currentURL, !userSelected else { return }
        let generation = activation
        identityTask = Task {
            let original = await PortraitBlurFillWallpaperService.shared.originalSourceURL(forDerivedWallpaperAt: currentURL,
                derivedWallpapersDirectory: DownloadPathManager.shared.derivedWallpapersFolderURL) ?? currentURL
            guard !Task.isCancelled, isPresented, generation == activation, !userSelected,
                  let item = repository.currentItem(matching: original), repository.contains(item, folderIDs: selectedFolderIDs) else { return }
            if !batchItems.contains(where: { $0.id == item.id }) {
                batchItems.insert(item, at: 0)
                if batchItems.count > Self.batchSize { batchItems.removeLast() }
            }
            selectedItem = item
        }
    }
    func warmVisiblePreviews() async {
        let generation = activation
        for item in batchItems {
            guard !Task.isCancelled, isPresented, generation == activation else { return }
            guard let resolved = await repository.resolvePreview(for: item) else { continue }
            guard !Task.isCancelled, isPresented, generation == activation else { return }
            if let index = batchItems.firstIndex(where: { $0.id == resolved.id }) { batchItems[index] = resolved }
            if selectedItem?.id == resolved.id { selectedItem = resolved }
        }
    }
    func suspendPreviewWork(keepingPresentation: Bool = false) {
        activation &+= 1; identityTask?.cancel(); identityTask = nil
        if !keepingPresentation { isPresented = false }
    }
    func finishHidingPresentation() { isPresented = false }
    func toggleFavorite() { if let selectedItem { WallpaperLibraryService.shared.toggleFavorite(selectedItem.wallpaper) } }
    func openDetail() { if let selectedItem { onOpenDetail?(.wallpaper(selectedItem.wallpaper)) } }
    func openSettings() { onOpenSettings?() }
    func quitApplication() { onQuitApplication?() }
    func nextWallpaperForTargetScreen() {
        guard let screen = resolvedTargetScreen() else { return }
        userSelected = false
        WallpaperSchedulerService.shared.triggerNextWallpaperNow(for: screen.wallpaperScreenIdentifier)
    }
    func previousWallpaperForTargetScreen() {
        guard let screen = resolvedTargetScreen() else { return }
        userSelected = false
        WallpaperSchedulerService.shared.triggerPreviousWallpaperNow(for: screen.wallpaperScreenIdentifier)
    }
    func applySelectedItem() {
        guard !isApplying, let selectedItem, let screen = resolvedTargetScreen(), repository.contains(selectedItem, folderIDs: selectedFolderIDs) else { return }
        let requestID = UUID()
        applyProgress.begin(requestID)
        errorMessage = nil
        applyTask = Task {
            var success = false
            defer {
                applyProgress.finish(requestID); applyTask = nil
            }
            do {
                var options = LocalWallpaperApplyService.Options(); options.reason = "menu-bar-selection"
                success = try await LocalWallpaperApplyService.apply(localURL: selectedItem.localURL, targetScreens: [screen], options: options) { [weak self] stage in
                    self?.applyProgress.report(stage, for: requestID)
                }
                guard success else { throw CocoaError(.featureUnsupported) }
                onApplied?()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private enum StaticQuickFolderSelectionStore {
    private struct Selection: Codable { let ids: [String]? }
    private static let key = "menu_bar_wallhaven_folder_selections_v2"
    static func load(scope: String) -> (found: Bool, ids: [String]?) {
        if let data = WaifuXPreferences.shared.data(forKey: key),
           let all = try? JSONDecoder().decode([String: Selection].self, from: data), let value = all[scope] { return (true, value.ids) }
        // The former empty array meant the entire library; retain that meaning.
        if let data = WaifuXPreferences.shared.data(forKey: "menu_bar_quick_switcher_folder_selections_v1"),
           let all = try? JSONDecoder().decode([String: [String]].self, from: data), let ids = all[scope] { return (true, ids.isEmpty ? nil : ids) }
        return (false, nil)
    }
    static func save(_ ids: [String]?, scope: String) {
        var all = WaifuXPreferences.shared.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Selection].self, from: $0) } ?? [:]
        all[scope] = Selection(ids: ids)
        if let data = try? JSONEncoder().encode(all) { WaifuXPreferences.shared.set(data, forKey: key) }
    }
}

@MainActor
final class MenuBarQuickWallpaperRepository {
    static let shared = MenuBarQuickWallpaperRepository()
    let changes = PassthroughSubject<Void, Never>()
    private var subscriptions = Set<AnyCancellable>()
    private var index = MenuBarQuickIndex()
    private var indexingTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var previews: [String: URL] = [:]
    private var revisions: [String: Int] = [:]
    private var unavailableUntil: [String: Date] = [:]
    private var started = false
    private(set) var isReady = false
    private(set) var lastBuildDurationMS = 0
    private(set) var lastCurrentLookupMS = 0
    func start() {
        guard !started, BackgroundRuntimeRole.isHelper, LibraryFolderStore.shared.didRestoreFromDisk else { return }
        started = true
        rebuildIndex()
        for publisher in [WallpaperLibraryService.shared.objectWillChange.eraseToAnyPublisher(), LibraryFolderStore.shared.objectWillChange.eraseToAnyPublisher(), FolderLockService.shared.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuildIndex() }.store(in: &subscriptions)
        }
        Task { await DownloadPathManager.shared.prepareLibraryRootSnapshot(); rebuildIndex() }
    }
    func folderIsVisible(_ folderID: String?) -> Bool {
        var current = folderID
        var seen = Set<String>()
        while let id = current, !id.isEmpty {
            guard seen.insert(id).inserted, let folder = LibraryFolderStore.shared.wallpaperFolders.first(where: { $0.id == id }), folder.collection == .downloads else { return false }
            if folder.isLocked && !FolderLockService.shared.isFolderUnlocked(id) { return false }
            current = folder.parentFolderID
        }
        return true
    }
    private func rebuildIndex() {
        generation &+= 1
        let token = generation
        indexingTask?.cancel()
        let entries = WallpaperLibraryService.shared.downloadRecords.map { record in
            MenuBarQuickIndexEntry(id: "wallpaper.\(record.wallpaper.id)", path: record.localFilePath, folderKey: record.folderID ?? "",
                downloadedAt: record.downloadedAt, visible: record.isActive && folderIsVisible(record.folderID))
        }
        changes.send() // Remove hidden/deleted selections before asynchronous indexing finishes.
        let start = ProcessInfo.processInfo.systemUptime
        indexingTask = Task {
            let result = await Task.detached(priority: .utility) { MenuBarQuickIndex.build(entries) }.value
            guard !Task.isCancelled, generation == token else { return }
            index = result; isReady = true; indexingTask = nil
            lastBuildDurationMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
            changes.send()
        }
    }
    func item(id: String) -> MenuBarQuickWallpaperItem? {
        guard id.hasPrefix("wallpaper."), let record = WallpaperLibraryService.shared.downloadRecord(for: String(id.dropFirst("wallpaper.".count))),
              folderIsVisible(record.folderID), WallhavenContentPolicy.isWallpaperRecord(id: record.wallpaper.id, detailURL: record.wallpaper.url, imagePath: record.wallpaper.path) else { return nil }
        return MenuBarQuickWallpaperItem(id: id, title: record.wallpaper.title ?? record.wallpaper.primaryTagName ?? "Wallhaven \(record.wallpaper.id)",
            localURL: record.localFileURL, thumbnailURL: previews[id] ?? record.wallpaper.thumbURL,
            downloadedAt: record.downloadedAt, wallpaper: record.wallpaper, folderID: record.folderID)
    }
    private func folderScope(_ selection: [String]?) -> [String]? {
        guard let selection else { return nil }
        var ids = Set(selection.isEmpty ? [""] : selection)
        var changed = true
        while changed {
            changed = false
            for folder in LibraryFolderStore.shared.wallpaperFolders where folder.parentFolderID.map(ids.contains) == true {
                if ids.insert(folder.id).inserted { changed = true }
            }
        }
        return Array(ids)
    }
    func sample(folderIDs: [String]?, excluding: Set<String>, limit: Int) -> [MenuBarQuickWallpaperItem] {
        index.sample(folderIDs: folderScope(folderIDs), excluding: excluding, limit: limit).compactMap { item(id: $0) }.filter { contains($0, folderIDs: folderIDs) }
    }
    func contains(_ candidate: MenuBarQuickWallpaperItem, folderIDs: [String]?) -> Bool {
        guard let current = item(id: candidate.id) else { return false }
        return folderScope(folderIDs).map { $0.contains(current.folderID ?? "") } ?? true
    }
    func currentItem(matching url: URL?) -> MenuBarQuickWallpaperItem? {
        let start = ProcessInfo.processInfo.systemUptime
        defer { lastCurrentLookupMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000) }
        guard let url, url.isFileURL, let owner = index.owner(of: url.path) else { return nil }
        return item(id: owner)
    }
    func previewRevision(for id: String) -> Int { revisions[id, default: 0] }
    func resolvePreview(for candidate: MenuBarQuickWallpaperItem) async -> MenuBarQuickWallpaperItem? {
        guard let current = item(id: candidate.id), (unavailableUntil[current.id] ?? .distantPast) <= Date() else { return nil }
        guard await current.localURL.fileExistsAsync() else {
            unavailableUntil[current.id] = Date().addingTimeInterval(5); return nil
        }
        let thumbnail = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: current.localURL)
        guard !Task.isCancelled, let refreshed = item(id: current.id), refreshed.localURL == current.localURL else { return nil }
        if let thumbnail, previews[current.id] != thumbnail {
            previews[current.id] = thumbnail; revisions[current.id, default: 0] += 1
        }
        return refreshed.replacingThumbnail(with: thumbnail ?? refreshed.thumbnailURL)
    }
}

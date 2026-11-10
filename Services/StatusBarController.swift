import AppKit
import Combine

/// Menu-bar controls for static images and their download queue.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
  static let shared = StatusBarController()
  private var statusItem: NSStatusItem?
  private let menu = NSMenu()
  private let quickSwitcher = MenuBarQuickSwitcherController()
  private var subscriptions = Set<AnyCancellable>()
  private var isConfigured = false
  private var showWindowHandler: (() -> Void)?
  private var releaseMemoryHandler: (() -> Void)?
  private var quitHandler: (() -> Void)?
  private var recordsByFingerprint: [String: WallpaperDownloadRecord] = [:]
  private var refreshGeneration: UInt64 = 0
  var backgroundSnapshot: [String: Any] {
    [
      "configured": isConfigured, "visible": statusItem?.isVisible ?? false,
      "hasButton": statusItem?.button != nil,
    ]
  }
  private override init() { super.init() }
  func configure(
    showWindow: @escaping () -> Void, releaseMemory: @escaping () -> Void,
    quit: @escaping () -> Void
  ) {
    guard BackgroundRuntimeRole.isHelper, !BackgroundRuntimeRole.isIsolatedTest, !isConfigured
    else { return }
    isConfigured = true
    showWindowHandler = showWindow
    releaseMemoryHandler = releaseMemory
    quitHandler = quit
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    item.button?.image = NSImage(
      systemSymbolName: "photo.on.rectangle", accessibilityDescription: "WaifuX")
    item.button?.target = self
    item.button?.action = #selector(clicked(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    menu.delegate = self
    menu.autoenablesItems = false
    for publisher in [
      CurrentWallpaperService.shared.objectWillChange.eraseToAnyPublisher(),
      WallpaperLibraryService.shared.objectWillChange.eraseToAnyPublisher(),
    ] {
      publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshRecords() }
        .store(in: &subscriptions)
    }
    NotificationCenter.default.publisher(for: .appLanguageDidChange).receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.rebuildMenu() }.store(in: &subscriptions)
    quickSwitcher.prewarm()
    refreshRecords()
    rebuildMenu()
  }
  private func refreshRecords() {
    refreshGeneration &+= 1
    let generation = refreshGeneration
    Task {
      var records: [String: WallpaperDownloadRecord] = [:]
      for screen in NSScreen.screens {
        guard
          let current = CurrentWallpaperService.shared.activeURL(
            for: screen.wallpaperScreenIdentifier)
        else { continue }
        let original = DesktopWallpaperSyncManager.shared.originalSourceURL(for: current)
        if let record = WallpaperLibraryService.shared.downloadRecord(
          forLocalFilePath: original.path)
        {
          records[screen.wallpaperScreenFingerprint] = record
        }
      }
      guard generation == refreshGeneration else { return }
      recordsByFingerprint = records
    }
  }
  @objc private func clicked(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    if event.type == .rightMouseUp {
      quickSwitcher.dismiss()
      rebuildMenu()
      statusItem?.menu = menu
      sender.performClick(nil)
      statusItem?.menu = nil
    } else {
      let screen =
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        ?? NSScreen.screens.first
      quickSwitcher.toggle(
        relativeTo: sender, targetScreen: screen,
        currentWallpaperURL: screen.flatMap {
          CurrentWallpaperService.shared.activeURL(for: $0.wallpaperScreenIdentifier)
        },
        onOpenSettings: { WaifuXUIActions.perform(.settings) },
        onOpenDetail: { request in
          MainNavigationRequestStore.requestWallpaperDetail(request)
          WaifuXUIActions.perform(.wallpaperDetail)
        },
        onQuit: { [weak self] in self?.quitHandler?() })
    }
  }
  private func item(_ title: String, action: Selector?, payload: String? = nil) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.representedObject = payload
    return item
  }
  private func rebuildMenu() {
    menu.removeAllItems()
    menu.addItem(item(t("statusbar.showWindow"), action: #selector(showWindow)))
    menu.addItem(item(t("statusbar.openMyLibrary"), action: #selector(openLibrary)))
    menu.addItem(.separator())
    let scheduler = WallpaperSchedulerService.shared
    for screen in NSScreen.screensOrderedForDisplay {
      let row = item(screen.localizedName, action: nil)
      let sub = NSMenu()
      sub.autoenablesItems = false
      let fingerprint = screen.wallpaperScreenFingerprint
      let next = item(
        t("statusbar.nextWallpaper"), action: #selector(nextImage(_:)), payload: fingerprint)
      next.isEnabled = scheduler.hasSchedulableItems(for: screen.wallpaperScreenIdentifier)
      sub.addItem(next)
      let detail = item(
        t("statusbar.openCurrentWallpaper"), action: #selector(openDetail(_:)), payload: fingerprint
      )
      detail.isEnabled = recordsByFingerprint[fingerprint] != nil
      sub.addItem(detail)
      let crop = item(t("statusbar.cropAspect"), action: nil)
      let cropMenu = NSMenu()
      cropMenu.autoenablesItems = false
      let adjust = item(CropAdjustOverlayController.shared.isActive(for: screen) ? t("statusbar.cropExit") : t("statusbar.cropAdjust"),
        action: #selector(adjustCrop(_:)), payload: fingerprint)
      adjust.isEnabled = recordsByFingerprint[fingerprint] != nil
      cropMenu.addItem(adjust)
      let settings = DisplayCropSettingsStore.shared.settings(for: screen)
      for preset in AspectPreset.allCases where preset != .custom {
        let title = preset == .autoFill ? t("statusbar.cropAspectAutoFill") : preset.displayName()
        let entry = item(title, action: #selector(cropAspect(_:)), payload: fingerprint)
        entry.tag = AspectPreset.allCases.firstIndex(of: preset) ?? 0
        entry.state = settings.aspectPreset == preset ? .on : .off
        cropMenu.addItem(entry)
      }
      cropMenu.addItem(item(t("statusbar.cropAspectCustom"), action: #selector(customCropAspect(_:)), payload: fingerprint))
      cropMenu.addItem(item(t("statusbar.cropReset"), action: #selector(resetCrop(_:)), payload: fingerprint))
      crop.submenu = cropMenu
      sub.addItem(crop)
      let enabled = item(
        t("autoSwitchEnabled"), action: #selector(toggleRotation(_:)), payload: fingerprint)
      enabled.state = scheduler.resolvedDisplayConfig(for: screen).isEnabled ? .on : .off
      sub.addItem(enabled)
      sub.addItem(
        item(
          t("statusbar.stopWallpaper"), action: #selector(restoreDesktop(_:)), payload: fingerprint)
      )
      row.submenu = sub
      menu.addItem(row)
    }
    let entries = TaskQueueStatusService.shared.entries
    if !entries.isEmpty {
      menu.addItem(.separator())
      let row = item(t("statusbar.taskQueue"), action: nil)
      let sub = NSMenu()
      sub.autoenablesItems = false
      for entry in entries {
        let progress = entry.progress.isFinite ? Int(entry.progress * 100) : 0
        sub.addItem(
          item(
            "\(entry.title) · \(progress)%", action: #selector(cancelDownload(_:)),
            payload: entry.id))
      }
      sub.addItem(
        item(t("statusbar.taskQueue.cancelAllDownloads"), action: #selector(cancelAllDownloads)))
      row.submenu = sub
      menu.addItem(row)
    }
    menu.addItem(.separator())
    menu.addItem(item(t("settings"), action: #selector(openSettings)))
    let icons = item(t("statusbar.hideDesktopIcons"), action: #selector(toggleIcons))
    icons.state = DesktopIconManager.shared.areDesktopIconsHidden ? .on : .off
    menu.addItem(icons)
    menu.addItem(item(t("checkForUpdates"), action: #selector(updates)))
    menu.addItem(item(t("statusbar.releaseMemory"), action: #selector(releaseMemory)))
    let quit = item(t("statusbar.quit"), action: #selector(quit))
    quit.keyEquivalent = "q"
    menu.addItem(quit)
  }
  func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
  private func screen(_ sender: NSMenuItem) -> NSScreen? {
    guard let fingerprint = sender.representedObject as? String else { return nil }
    let matches = NSScreen.screens.filter { $0.wallpaperScreenFingerprint == fingerprint }
    return matches.count == 1 ? matches.first : nil
  }
  @objc private func showWindow() { showWindowHandler?() }
  @objc private func openLibrary() {
    MainNavigationRequestStore.requestLibraryTab()
    WaifuXUIActions.perform(.library)
  }
  @objc private func openSettings() { WaifuXUIActions.perform(.settings) }
  @objc private func updates() { WaifuXUIActions.perform(.updates) }
  @objc private func releaseMemory() {
    quickSwitcher.dismiss()
    releaseMemoryHandler?()
  }
  @objc private func quit() {
    quickSwitcher.dismiss()
    quitHandler?()
  }
  @objc private func toggleIcons() { DesktopIconManager.shared.toggle() }
  @objc private func nextImage(_ sender: NSMenuItem) {
    guard let screen = screen(sender) else { return }
    WallpaperSchedulerService.shared.triggerNextWallpaperNow(for: screen.wallpaperScreenIdentifier)
  }
  @objc private func openDetail(_ sender: NSMenuItem) {
    guard let screen = screen(sender),
      let record = recordsByFingerprint[screen.wallpaperScreenFingerprint]
    else { return }
    MainNavigationRequestStore.requestWallpaperDetail(.wallpaper(record.wallpaper))
    WaifuXUIActions.perform(.wallpaperDetail)
  }
  @objc private func toggleRotation(_ sender: NSMenuItem) {
    guard let screen = screen(sender) else { return }
    let scheduler = WallpaperSchedulerService.shared
    let enabled = scheduler.resolvedDisplayConfig(for: screen).isEnabled
    if scheduler.isGlobalDisplaySyncEnabled {
      scheduler.updateGlobalDisplayEnabled(!enabled)
    } else {
      scheduler.updateDisplayEnabled(!enabled, for: screen.wallpaperScreenIdentifier)
    }
  }
  @objc private func adjustCrop(_ sender: NSMenuItem) {
    guard let screen = screen(sender) else { return }
    CropAdjustOverlayController.shared.toggle(for: screen, statusBarItemRef: statusItem)
  }
  @objc private func resetCrop(_ sender: NSMenuItem) {
    guard let screen = screen(sender) else { return }
    DisplayCropSettingsStore.shared.reset(for: screen)
  }
  @objc private func cropAspect(_ sender: NSMenuItem) {
    guard let screen = screen(sender), AspectPreset.allCases.indices.contains(sender.tag) else { return }
    DisplayCropSettingsStore.shared.update(for: screen) { $0.isEnabled = true; $0.aspectPreset = AspectPreset.allCases[sender.tag] }
  }
  @objc private func customCropAspect(_ sender: NSMenuItem) {
    guard let screen = screen(sender) else { return }
    let alert = NSAlert()
    alert.messageText = t("statusbar.cropAspectCustom")
    let field = NSTextField(string: "16:9")
    field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: t("confirm"))
    alert.addButton(withTitle: t("cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let values = field.stringValue.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard values.count == 2, values[0].isFinite, values[1].isFinite, values[1] > 0,
          (0.1...10).contains(values[0] / values[1]) else { NSSound.beep(); return }
    DisplayCropSettingsStore.shared.update(for: screen) {
      $0.isEnabled = true; $0.aspectPreset = .custom; $0.customAspect = values[0] / values[1]
    }
  }
  @objc private func restoreDesktop(_ sender: NSMenuItem) {
    guard let screen = screen(sender) else { return }
    let scheduler = WallpaperSchedulerService.shared
    if scheduler.isGlobalDisplaySyncEnabled {
      scheduler.updateGlobalDisplayEnabled(false)
    } else {
      scheduler.updateDisplayEnabled(false, for: screen.wallpaperScreenIdentifier)
    }
    _ = StaticWallpaperRequestCoordinator.shared.beginRequest(on: [screen])
    DesktopWallpaperSyncManager.shared.restoreOriginalSystemWallpaper(for: screen)
  }
  @objc private func cancelDownload(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    DownloadTaskService.shared.cancelTask(id: id)
  }
  @objc private func cancelAllDownloads() { DownloadTaskService.shared.cancelAllActiveDownloads() }
}

import SwiftUI
import AppKit
import ApplicationServices
import CoreImage
import CoreImage.CIFilterBuiltins

private let settingsSliderTint = Color(hex: "30D158")

private func snappedSliderBinding(
    _ binding: Binding<Double>,
    in range: ClosedRange<Double>,
    step: Double
) -> Binding<Double> {
    Binding(
        get: { binding.wrappedValue },
        set: { newValue in
            let snappedValue = ((newValue - range.lowerBound) / step).rounded() * step + range.lowerBound
            binding.wrappedValue = min(max(snappedValue, range.lowerBound), range.upperBound)
        }
    )
}

// MARK: - 毛玻璃背景视图
private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView {
        DragHandleView()
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {}
}

private final class DragHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - 设置标签
private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case download
    case wallhaven
    case scheduler
    case sync
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return t("general")
        case .download: return t("download")
        case .wallhaven: return t("wallhaven")
        case .scheduler: return t("scheduler")
        case .sync: return t("cloudSync")
        case .about: return t("about")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .download: return "arrow.down.circle"
        case .wallhaven: return "w.circle"
        case .scheduler: return "clock.arrow.circlepath"
        case .sync: return "icloud"
        case .about: return "info.circle"
        }
    }
}

// MARK: - 侧边栏导航项
private struct SidebarItem: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .frame(width: 20)

                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))

                Spacer()
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.1) : (isHovered ? Color.white.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.12) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering && !isSelected
            }
        }
    }
}

// MARK: - 主视图 - 左侧导航栏 + 右侧内容区
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var localization = LocalizationService.shared
    @State private var selectedTab: SettingsTab = .general

    private let sidebarWidth: CGFloat = 180

    var body: some View {
        HStack(spacing: 0) {
            // === 左侧导航栏 ===
            sidebar

            Divider()
                .background(Color.white.opacity(0.08))

            // === 右侧内容区 ===
            VStack(spacing: 0) {
                // 标题行（标题 + 拖拽区域，原生红绿灯在左侧）
                HStack {
                    Text(selectedTab.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.9))

                    WindowDragHandle()
                        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                }
                .padding(.leading, 20)
                .padding(.trailing, 28)
                .padding(.vertical, 16)

                Divider()
                    .background(Color.white.opacity(0.06))

                // 内容区域
                Group {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsTab(viewModel: viewModel)
                    case .download:
                        DownloadSettingsTab(viewModel: viewModel)
                    case .wallhaven:
                        WallhavenSettingsTab(viewModel: viewModel)
                    case .scheduler:
                        SchedulerSettingsTab(viewModel: viewModel)
                    case .sync:
                        SyncSettingsTab()
                    case .about:
                        AboutSettingsTab(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(hex: "1C1C1E"))
        .id(localization.currentLanguage)
        .environment(\.locale, Locale(identifier: localization.currentLanguage.rawValue))
        .onAppear {
            let key = "settings.openSchedulerOnNextAppearance"
            if WaifuXPreferences.shared.bool(forKey: key) {
                WaifuXPreferences.shared.removeObject(forKey: key)
                selectedTab = .scheduler
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSchedulerSettings)) { _ in
            WaifuXPreferences.shared.removeObject(forKey: "settings.openSchedulerOnNextAppearance")
            selectedTab = .scheduler
        }
    }

    /// tab → 引导锚点（设置总览导览逐步高亮左侧分类）。
    private static func settingsGuideAnchor(for tab: SettingsTab) -> GuideAnchorID {
        switch tab {
        case .general: return .settingsTabGeneral
        case .download: return .settingsTabDownload
        case .wallhaven: return .settingsTabWallhaven
        case .scheduler: return .settingsTabScheduler
        case .sync: return .settingsTabSync
        case .about: return .settingsTabAbout
        }
    }

    // MARK: 左侧导航栏
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases.filter { $0 != .sync }, id: \.self) { tab in
                SidebarItem(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = tab
                        }
                    }
                )
                .guideAnchor(Self.settingsGuideAnchor(for: tab))
            }

            Spacer()

            // 底部「功能导览」：手动重播分类总览（不写完成状态，不受版本节流）
            Button {
                GuideEngine.shared.replay(GuideTours.settingsOverview)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13, weight: .medium))
                    Text(t("guide.settings.replay"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t("guide.settings.replay"))
            .padding(.bottom, 14)
        }
        .padding(.top, 42)
        .padding(.horizontal, 10)
        .frame(width: sidebarWidth)
        .background(
            ZStack {
                Color(hex: "1A1A1A").opacity(0.85)

                VisualEffectView(material: .sidebar)
                    .allowsHitTesting(false)
            }
        )
        .onAppear {
            // 打开设置页首次播放总览导览（WaifuX GuideKit）
            GuideEngine.shared.noteSheetOpened(GuideTours.settingsOverview)
        }
    }
}

// MARK: - 功能模块设置标签

// MARK: - 通用设置标签
private struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var arcSettings = ArcBackgroundSettings.shared

    /// 系统壁纸 store 的选择状态说明（设置页动态锁屏区展示）

    private var languageBinding: Binding<LocalizationService.Language> {
        Binding(
            get: { LocalizationService.shared.currentLanguage },
            set: { LocalizationService.shared.setLanguage($0) }
        )
    }

    var body: some View {
        MacSettingsForm {
            // 语言设置组
            MacSettingsSection(header: t("languageRegion")) {
                VStack(spacing: 0) {
                    // 显示语言
                    HStack(spacing: 12) {
                        Text(t("displayLanguage"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))

                        Spacer()

                        Menu {
                            ForEach(LocalizationService.Language.allCases, id: \.self) { language in
                                Button(language.displayName) {
                                    LocalizationService.shared.setLanguage(language)
                                }
                            }
                        } label: {
                            Text(LocalizationService.shared.currentLanguage.displayName)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        .menuStyle(.borderlessButton)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                    // 语言描述
                    HStack {
                        Text(t("displayLanguageDesc"))
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.4))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            // 外观设置组
            MacSettingsSection(header: t("appearance")) {
                MacSettingsRow(
                    title: t("grainTextureEffect"),
                    subtitle: t("grainTextureEffectDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.grainTextureEnabled)
                }

                if viewModel.grainTextureEnabled {
                    HStack(spacing: 12) {
                        Text(t("grainIntensity"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))

                        Spacer()

                        Slider(
                            value: snappedSliderBinding($viewModel.grainIntensity, in: 0...1, step: 0.05),
                            in: 0...1
                        )
                        .tint(settingsSliderTint)
                        .accessibilityLabel(t("grainIntensity"))
                        .frame(width: 160)

                        Text("\(Int(viewModel.grainIntensity * 100))%")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .frame(width: 36, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                MacSettingsRow(
                    title: t("compactMode"),
                    subtitle: t("compactModeDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $arcSettings.compactMode)
                }

                MacSettingsRow(
                    title: t("portraitBlurFill"),
                    subtitle: t("portraitBlurFillDesc"),
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.portraitBlurFillEnabled)
                }
            }




            // 屏保组（安装/跟随状态，跟随桌面壁纸，与动态锁屏同语义）

            // 代理设置组
            MacSettingsSection(header: t("proxySettings")) {
                MacSettingsRow(
                    title: t("proxyEnabled"),
                    subtitle: t("proxyEnabledDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.proxyEnabled)
                }

                if viewModel.proxyEnabled {
                    MacSettingsRow(
                        title: t("proxyHost"),
                        showDivider: true
                    ) {
                        TextField(t("proxyHostPlaceholder"), text: $viewModel.proxyHost)
                            .font(.system(size: 12, weight: .regular))
                            .textFieldStyle(.plain)
                            .frame(width: 140)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.07))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                    )
                            )
                            .foregroundStyle(Color.white.opacity(0.85))
                    }

                    MacSettingsRow(
                        title: t("proxyPort"),
                        showDivider: false
                    ) {
                        TextField(t("proxyPortPlaceholder"), text: $viewModel.proxyPort)
                            .font(.system(size: 12, weight: .regular))
                            .textFieldStyle(.plain)
                            .frame(width: 80)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.07))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                    )
                            )
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                }
            }

            // 系统设置组
            MacSettingsSection(header: t("system")) {
                MacSettingsRow(
                    title: t("launchAtLogin"),
                    subtitle: nil,
                    showDivider: true
                ) {
                    MacToggle(isOn: Binding(
                        get: { viewModel.launchAtLogin },
                        set: { _ in viewModel.toggleLaunchAtLogin() }
                    ))
                }

                MacSettingsRow(
                    title: t("menuBarClickActions"),
                    subtitle: t("menuBarClickActionsDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.swapMenuBarClickActions)
                }

                MacSettingsRow(title: t("pauseRotationOnBattery"), subtitle: t("pauseRotationOnBatteryDesc"), showDivider: true) {
                    MacToggle(isOn: $viewModel.pauseRotationOnBattery)
                }

                MacSettingsRow(
                    title: t("preventSystemSleep"),
                    subtitle: t("preventSystemSleepDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.preventSystemSleep)
                }

            }
        }

    }

}

// MARK: - 下载设置标签
private struct DownloadSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showMigrationSheet = false
    @State private var isRepairing = false
    @State private var showRepairAlert = false
    @State private var showClearCacheAlert = false
    @State private var repairResultMessage = ""
    @State private var pathRefreshID = UUID()

    var body: some View {
        MacSettingsForm {
            MacSettingsSection(header: t("downloadPreferences")) {

                // 下载目录选择
                MacSettingsRow(
                    title: t("downloadDirectory"),
                    subtitle: currentPathDisplay,
                    showDivider: true
                ) {
                    Button {
                        showMigrationSheet = true
                    } label: {
                        Text(t("change"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }

                // 数据修复按钮
                MacSettingsRow(
                    title: t("repairData"),
                    subtitle: t("repairDataDesc"),
                    showDivider: false
                ) {
                    Button {
                        showRepairAlert = true
                    } label: {
                        HStack(spacing: 4) {
                            if isRepairing {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                            }
                            Text(isRepairing ? t("repairing") : t("repair"))
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.orange.opacity(0.2))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .disabled(isRepairing)
                }
            }

            // 手动「优化视频」始终可走循环分析 + 补帧；此处只控制下载后自动优化与目标帧率。

            // 缓存管理
            MacSettingsSection(header: t("dataManagement")) {
                HStack(spacing: 12) {
                    Text(t("clearCache"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Spacer()

                    Text(viewModel.cacheSize)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.4))

                    Button(t("clear")) {
                        showClearCacheAlert = true
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: "FF453A"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .id(pathRefreshID)
        .sheet(isPresented: $showMigrationSheet) {
            DirectoryMigrationSheet(isPresented: $showMigrationSheet)
        }
        .glassAlert(t("repairData"), isPresented: $showRepairAlert,
                    message: t("repairDataConfirm"),
                    actions: [
                        GlassAlertAction(t("cancel"), role: .cancel),
                        GlassAlertAction(t("repair"), role: .destructive) {
                            startRepair()
                        }
                    ])
        .glassAlert(t("clearCache"), isPresented: $showClearCacheAlert,
                    message: t("clearCacheConfirm"),
                    actions: [
                        GlassAlertAction(t("cancel"), role: .cancel),
                        GlassAlertAction(t("clear"), role: .destructive) {
                            Task { await viewModel.clearCache() }
                        }
                    ])
        .glassAlert(repairResultMessage, isPresented: Binding(
            get: { !repairResultMessage.isEmpty && !isRepairing },
            set: { if !$0 { repairResultMessage = "" } }
        ), actions: [
            GlassAlertAction("OK", role: .cancel) { repairResultMessage = "" }
        ])
        .onReceive(NotificationCenter.default.publisher(for: .downloadPathChanged)) { _ in
            pathRefreshID = UUID()
        }
    }

    private var currentPathDisplay: String {
        let path = DownloadPathManager.shared.currentRootPathDisplay
        if path.count > 60 {
            return "..." + String(path.suffix(57))
        }
        return path
    }

    private func startRepair() {
        isRepairing = true
        Task {
            let result = await DirectoryMigrationService.shared.repairBrokenRecords()
            isRepairing = false
            var messages: [String] = []
            if result.indexedCount == 0
                && result.repairedCount == 0
                && result.removedCount == 0
                && result.migratedCount == 0
                && result.orphanedMembershipCount == 0 {
                messages.append(t("repairNoIssues"))
            } else {
                messages.append(String(
                    format: t("repairResult"),
                    result.indexedCount,
                    result.repairedCount,
                    result.migratedCount,
                    result.removedCount,
                    result.healthyCount
                ))
            }
            if result.orphanedMembershipCount > 0 {
                messages.append(String(format: t("repairOrphanMemberships"), result.orphanedMembershipCount))
            }
            if result.orphanedMembershipAborted {
                messages.append(t("repairOrphanAborted"))
            }
            repairResultMessage = messages.joined(separator: "\n")
            NotificationCenter.default.post(name: .downloadPathChanged, object: nil)
        }
    }
}

// MARK: - 调度器设置标签
private struct SchedulerSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    private var screens: [NSScreen] {
        // 勿直接用 NSScreen.screens：系统枚举顺序会在睡眠/唤醒后打乱，
        // 导致「显示器 2/3」标签对调，看起来像自动切换配置串台。
        NSScreen.screensOrderedForDisplay
    }

    private var isGlobalDisplaySyncEnabled: Bool {
        viewModel.schedulerViewModel.isGlobalDisplaySyncEnabled
    }

    var body: some View {
        MacSettingsForm {
            MacSettingsSection(header: t("globalSchedulerConfig")) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t("syncAllDisplaysWallpaper"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.9))
                            Text(t("syncAllDisplaysWallpaperDesc"))
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.48))
                        }

                        Spacer()

                        MacToggle(isOn: Binding(
                            get: { isGlobalDisplaySyncEnabled },
                            set: { viewModel.schedulerViewModel.updateGlobalDisplaySyncEnabled($0) }
                        ))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if isGlobalDisplaySyncEnabled {
                        let globalConfig = viewModel.schedulerViewModel.globalDisplayConfig

                        dividerLine

                        HStack(spacing: 12) {
                            Text(t("autoSwitchEnabled"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.9))

                            Spacer()

                            MacToggle(isOn: Binding(
                                get: { globalConfig.isEnabled },
                                set: { viewModel.schedulerViewModel.updateGlobalDisplayEnabled($0) }
                            ))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        if globalConfig.isEnabled {
                            globalSchedulerControls(config: globalConfig)
                        }
                    }
                }
            }

            if !isGlobalDisplaySyncEnabled {
                // 每屏配置（独立模式）
                MacSettingsSection(header: t("scheduleConfig")) {
                    ForEach(Array(screens.enumerated()), id: \.element.wallpaperScreenIdentifier) { (index: Int, screen: NSScreen) in
                        // 勿在 body 内调用会写 UserDefaults / 改 @Published 的 migrate；
                        // 读路径 resolvedDisplayConfig 会按 fingerprint 找回旧配置，
                        // 写路径 update* 使用当前 wallpaperScreenIdentifier。
                        let screenID = screen.wallpaperScreenIdentifier
                        let displayConfig = viewModel.schedulerViewModel.displayConfig(for: screen)

                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Text("\(t("display")) \(index + 1) · \(screen.localizedName)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.9))

                                Spacer()

                                MacToggle(isOn: Binding(
                                    get: { displayConfig.isEnabled },
                                    set: { viewModel.schedulerViewModel.updateDisplayEnabled($0, for: screenID) }
                                ))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                            if displayConfig.isEnabled {
                                dividerLine

                                perDisplaySchedulerControls(
                                    config: displayConfig,
                                    screenID: screenID
                                )
                            }
                        }

                        if index < screens.count - 1 {
                            dividerLine
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func globalSchedulerControls(config: DisplaySchedulerConfig) -> some View {
        dividerLine

        HStack(spacing: 12) {
            Text(t("replaceInterval"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))

            Spacer()

            Menu {
                ForEach(SchedulerConfig.intervalOptions, id: \.self) { minutes in
                    Button(intervalLabel(for: minutes)) {
                        viewModel.schedulerViewModel.updateGlobalDisplayInterval(minutes)
                    }
                }
                Divider()

                Button(intervalLabel(for: SchedulerConfig.intervalOnUnlockMinutes)) {
                    viewModel.schedulerViewModel.updateGlobalDisplayInterval(SchedulerConfig.intervalOnUnlockMinutes)
                }
            } label: {
                Text(intervalLabel(for: config.intervalMinutes))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        dividerLine

        HStack(spacing: 12) {
            Text(t("replaceOrder"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))

            Spacer()

            Picker("", selection: Binding(
                get: { config.order },
                set: { viewModel.schedulerViewModel.updateGlobalDisplayOrder($0) }
            )) {
                Text(t("sequential")).tag(ScheduleOrder.sequential)
                Text(t("random")).tag(ScheduleOrder.random)
            }
            .pickerStyle(.segmented)
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        dividerLine

        dividerLine

        GlobalFolderPickerRow(
            folderIDs: config.folderIDs,
            viewModel: viewModel
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func perDisplaySchedulerControls(config: DisplaySchedulerConfig, screenID: String) -> some View {
        // 间隔选择
        HStack(spacing: 12) {
            Text(t("replaceInterval"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))

            Spacer()

            Menu {
                ForEach(SchedulerConfig.intervalOptions, id: \.self) { minutes in
                    Button(intervalLabel(for: minutes)) {
                        viewModel.schedulerViewModel.updateDisplayInterval(minutes, for: screenID)
                    }
                }
                Divider()

                Button(intervalLabel(for: SchedulerConfig.intervalOnUnlockMinutes)) {
                    viewModel.schedulerViewModel.updateDisplayInterval(SchedulerConfig.intervalOnUnlockMinutes, for: screenID)
                }
            } label: {
                Text(intervalLabel(for: config.intervalMinutes))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        // "播完即换"模式下的 Web/Scene 壁纸切换间隔滑块

        dividerLine

        // 顺序选择
        HStack(spacing: 12) {
            Text(t("replaceOrder"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))

            Spacer()

            Picker("", selection: Binding(
                get: { config.order },
                set: { viewModel.schedulerViewModel.updateDisplayOrder($0, for: screenID) }
            )) {
                Text(t("sequential")).tag(ScheduleOrder.sequential)
                Text(t("random")).tag(ScheduleOrder.random)
            }
            .pickerStyle(.segmented)
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        dividerLine

        // 内容类型选择

        dividerLine

        // 文件夹选择
        FolderPickerRow(
            folderIDs: config.folderIDs,
            screenID: screenID,
            viewModel: viewModel
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 文件夹选择组件（支持多选）
    private struct FolderPickerRow: View {
        let folderIDs: [String]?
        let screenID: String
        @ObservedObject var viewModel: SettingsViewModel
        @ObservedObject private var folderStore = LibraryFolderStore.shared

        var body: some View {
            HStack(spacing: 12) {
                Text(t("folders"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))

                Spacer()

                Menu {
                    Button(action: {
                        viewModel.schedulerViewModel.updateDisplayFolderIDs(nil, for: screenID)
                    }) {
                        HStack {
                            Text(t("ruleMarket.all"))
                            if folderIDs == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    if !allFolders.isEmpty {
                        Divider()
                        ForEach(allFolders) { folder in
                            Button(action: {
                                toggleFolder(folder.id)
                            }) {
                                HStack {
                                    Text(folderOptionLabel(for: folder))
                                    if isSelected(folder.id) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Text(folderIDsLabel)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .menuStyle(.borderlessButton)
                .help(folderIDsLabel)
            }
        }

        private var allFolders: [LibraryFolder] {
            var combined: [LibraryFolder] = []
            combined.append(contentsOf: folderStore.folders(for: .wallpaper))
            return combined.sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                if lhs.contentType != rhs.contentType {
                    return lhs.contentType.rawValue < rhs.contentType.rawValue
                }
                return lhs.id < rhs.id
            }
        }

        private var selectedFolderIDSet: Set<String> {
            Set(folderIDs ?? [])
        }

        private func isSelected(_ folderID: String) -> Bool {
            guard folderIDs != nil else { return false }
            return selectedFolderIDSet.contains(folderID)
        }

        /// 多选切换：
        /// - 当前为「全部」(nil) 时点某个文件夹 → 仅选中该文件夹
        /// - 已有选中时点已选项 → 取消；取消后空集合回退为「全部」
        /// - 点未选项 → 加入集合
        private func toggleFolder(_ folderID: String) {
            var next: Set<String>
            if let folderIDs {
                next = Set(folderIDs)
            } else {
                // 从「全部」进入多选：只选中当前点的这一项
                viewModel.schedulerViewModel.updateDisplayFolderIDs([folderID], for: screenID)
                return
            }

            if next.contains(folderID) {
                next.remove(folderID)
            } else {
                next.insert(folderID)
            }

            if next.isEmpty {
                viewModel.schedulerViewModel.updateDisplayFolderIDs(nil, for: screenID)
            } else {
                // 保持稳定顺序：按文件夹名称排序
                let ordered = allFolders
                    .map(\.id)
                    .filter { next.contains($0) }
                // 若有已删除文件夹 id 仍在集合里，追加在末尾以免静默丢配置
                let leftovers = next.subtracting(ordered)
                viewModel.schedulerViewModel.updateDisplayFolderIDs(
                    ordered + leftovers.sorted(),
                    for: screenID
                )
            }
        }

        private var folderIDsLabel: String {
            guard let folderIDs else { return t("ruleMarket.all") }
            if folderIDs.isEmpty { return t("ruleMarket.all") }
            let names = folderIDs.compactMap { id in
                allFolders.first(where: { $0.id == id }).map(folderOptionLabel)
            }
            if names.isEmpty { return t("ruleMarket.all") }
            if names.count == 1 { return names[0] }
            if names.count <= 3 {
                return names.joined(separator: ", ")
            }
            return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
        }

        private func folderOptionLabel(for folder: LibraryFolder) -> String {
            let contentType = t("wallpapers")
            return "\(contentType) · \(folder.name)"
        }
    }

    // MARK: - Global folder picker (multi-select against the shared global policy)
    private struct GlobalFolderPickerRow: View {
        let folderIDs: [String]?
        @ObservedObject var viewModel: SettingsViewModel
        @ObservedObject private var folderStore = LibraryFolderStore.shared

        var body: some View {
            HStack(spacing: 12) {
                Text(t("folders"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))

                Spacer()

                Menu {
                    Button(action: {
                        viewModel.schedulerViewModel.updateGlobalDisplayFolderIDs(nil)
                    }) {
                        HStack {
                            Text(t("all"))
                            if folderIDs == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    if !allFolders.isEmpty {
                        Divider()
                        ForEach(allFolders) { folder in
                            Button(action: {
                                toggleFolder(folder.id)
                            }) {
                                HStack {
                                    Text(folderOptionLabel(for: folder))
                                    if isSelected(folder.id) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Text(folderIDsLabel)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .menuStyle(.borderlessButton)
                .help(folderIDsLabel)
            }
        }

        private var allFolders: [LibraryFolder] {
            var combined: [LibraryFolder] = []
            combined.append(contentsOf: folderStore.folders(for: .wallpaper))
            return combined.sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                if lhs.contentType != rhs.contentType {
                    return lhs.contentType.rawValue < rhs.contentType.rawValue
                }
                return lhs.id < rhs.id
            }
        }

        private var selectedFolderIDSet: Set<String> {
            Set(folderIDs ?? [])
        }

        private func isSelected(_ folderID: String) -> Bool {
            guard folderIDs != nil else { return false }
            return selectedFolderIDSet.contains(folderID)
        }

        private func toggleFolder(_ folderID: String) {
            var next: Set<String>
            if let folderIDs {
                next = Set(folderIDs)
            } else {
                viewModel.schedulerViewModel.updateGlobalDisplayFolderIDs([folderID])
                return
            }

            if next.contains(folderID) {
                next.remove(folderID)
            } else {
                next.insert(folderID)
            }

            if next.isEmpty {
                viewModel.schedulerViewModel.updateGlobalDisplayFolderIDs(nil)
            } else {
                let ordered = allFolders
                    .map(\.id)
                    .filter { next.contains($0) }
                let leftovers = next.subtracting(ordered)
                viewModel.schedulerViewModel.updateGlobalDisplayFolderIDs(
                    ordered + leftovers.sorted()
                )
            }
        }

        private var folderIDsLabel: String {
            guard let folderIDs else { return t("all") }
            if folderIDs.isEmpty { return t("all") }
            let names = folderIDs.compactMap { id in
                allFolders.first(where: { $0.id == id }).map(folderOptionLabel)
            }
            if names.isEmpty { return t("all") }
            if names.count == 1 { return names[0] }
            if names.count <= 3 {
                return names.joined(separator: ", ")
            }
            return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
        }

        private func folderOptionLabel(for folder: LibraryFolder) -> String {
            let contentType = t("wallpapers")
            return "\(contentType) · \(folder.name)"
        }
    }

    private var dividerLine: some View {
        Divider()
            .background(Color.white.opacity(0.06))
            .padding(.leading, 16)
    }

    private func intervalLabel(for minutes: Int) -> String {

        if minutes == SchedulerConfig.intervalOnUnlockMinutes {
            return t("intervalOnUnlock")
        }
        switch minutes {
        case 1: return "1 \(t("minutes"))"
        case 3: return "3 \(t("minutes"))"
        case 5: return "5 \(t("minutes"))"
        case 15: return "15 \(t("minutes"))"
        case 30: return "30 \(t("minutes"))"
        case 60: return "1 \(t("hour"))"
        case 360: return "6 \(t("hours"))"
        case 1440: return "24 \(t("hours"))"
        default: return "\(minutes) \(t("minutes"))"
        }
    }
}

// MARK: - 关于设置标签
private struct AboutSettingsTab: View {
    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    @ObservedObject var viewModel: SettingsViewModel
    @State private var showExportLogConfirm = false
    @State private var showExportResultAlert = false
    @State private var exportedLogURL: URL?
    @State private var exportResultTitle = ""
    @State private var exportResultMessage = ""

    var body: some View {
        ZStack {
            MacSettingsForm {
                // 自动更新区域
                autoUpdateSection

                // 项目信息组
                MacSettingsSection(header: t("projectInfo")) {
                    infoRow(title: t("developer"), value: "jipika", isLast: false)

                    infoRow(title: t("techStack"), value: "SwiftUI + AppKit", isLast: true)
                }

                // 链接组
                MacSettingsSection(header: t("links")) {
                    MacLinkRow(title: t("visitWebsite"), action: {
                        if let url = URL(string: "https://github.com/jesusjodar/WaifuX") {
                            NSWorkspace.shared.open(url)
                        }
                    })

                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                    MacLinkRow(title: t("reportProblem"), action: {
                        if let url = URL(string: "https://github.com/jesusjodar/WaifuX/issues") {
                            NSWorkspace.shared.open(url)
                        }
                    })

                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)


                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                }

                // 日志诊断组
                MacSettingsSection(header: t("settings.diagnostics")) {
                    MacLinkRow(title: t("settings.exportLog"), action: {
                        showExportLogConfirm = true
                    })
                }

                // 重置所有数据

            }
            .glassAlert(t("settings.exportLog"), isPresented: $showExportLogConfirm,
                        message: t("settings.exportLog.confirm"),
                        actions: [
                            GlassAlertAction(t("cancel"), role: .cancel),
                            GlassAlertAction(t("confirm")) {
                                exportLog()
                            }
                        ])
            .glassAlert(exportResultTitle, isPresented: $showExportResultAlert,
                        message: exportResultMessage,
                        actions: exportResultActions)
        }
    }

    /// 导出结果弹窗按钮：成功时附加「在 Finder 中显示」
    private var exportResultActions: [GlassAlertAction] {
        var actions: [GlassAlertAction] = []
        if let url = exportedLogURL {
            actions.append(GlassAlertAction(t("settings.exportLog.reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        }
        actions.append(GlassAlertAction(t("ok"), role: .cancel))
        return actions
    }

    /// 确认导出后执行：复制运行日志到桌面，成功/失败都弹结果框。
    private func exportLog() {
        do {
            if let url = try AppLogger.exportLogToDesktop() {
                exportedLogURL = url
                exportResultTitle = t("settings.exportLog.successTitle")
                exportResultMessage = String(format: t("settings.exportLog.success"), url.lastPathComponent)
            } else {
                exportedLogURL = nil
                exportResultTitle = t("settings.exportLog.failedTitle")
                exportResultMessage = t("settings.exportLog.noLog")
            }
        } catch {
            exportedLogURL = nil
            exportResultTitle = t("settings.exportLog.failedTitle")
            exportResultMessage = error.localizedDescription
            AppLogger.error(.general, "日志导出失败", metadata: ["error": error.localizedDescription])
        }
        showExportResultAlert = true
    }

    @ViewBuilder
    private func infoRow(title: String, value: String, isLast: Bool) -> some View {
        MacInfoRow(title: title, value: value)
        if !isLast {
            Divider()
                .background(Color.white.opacity(0.06))
                .padding(.leading, 16)
        }
    }

    // MARK: - 自动更新区域（Sparkle 驱动）

    @ViewBuilder
    private var autoUpdateSection: some View {
        MacSettingsSection {
            VStack(alignment: .leading, spacing: 16) {
                // 应用信息头部 + 检查更新按钮
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("WaifuX")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.92))

                        Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · \(Self.currentArchitecture)")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }

                    Spacer()

                    // 检查更新按钮（委托 Sparkle 处理）
                    Button {
                        AppDelegate.shared?.checkForUpdates()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                            Text(t("checkForUpdates"))
                                .font(.system(size: 13))
                        }
                        .frame(height: 28)
                    }
                    .buttonStyle(.bordered)
                }

            }
            .padding(14)
        }
    }
}

// MARK: - Workshop 设置标签

// MARK: - 目录迁移 Sheet
private struct DirectoryMigrationSheet: View {
    @Binding var isPresented: Bool
    @State private var isMigrating = false
    @State private var progress: MigrationProgress = MigrationProgress(
        step: .copying,
        currentFileName: "",
        processedCount: 0,
        totalCount: 0,
        fractionCompleted: 0
    )
    @State private var result: MigrationResult?
    @State private var selectedDirectoryPath: String = ""

    private let downloadPathManager = DownloadPathManager.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(t("migrateDownloadDirectory"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)

                Text(t("migrateDownloadDirectoryDesc"))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)

            if let result = result {
                resultView(result: result)
            } else if isMigrating {
                migrationProgressView
            } else {
                directorySelectionView
            }

            Spacer()
        }
        .frame(width: 480, height: 320)
        .background(DarkLiquidGlassBackground(cornerRadius: 16, isHovered: false))
    }

    private var directorySelectionView: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(t("currentPath"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                Text(downloadPathManager.currentRootPathDisplay)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
            .padding(.horizontal, 24)

            if !selectedDirectoryPath.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(selectedDirectoryPath)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 24)
            }

            HStack(spacing: 12) {
                Button {
                    isPresented = false
                } label: {
                    Text(t("cancel"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    pickDirectory()
                } label: {
                    Text(t("selectDirectory"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(hex: "3B82F6"))
                        )
                }
                .buttonStyle(.plain)

                if !selectedDirectoryPath.isEmpty {
                    Button {
                        startMigration()
                    } label: {
                        Text(t("migrate"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(hex: "10B981"))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.top, 16)
    }

    private var migrationProgressView: some View {
        VStack(spacing: 20) {
            Spacer()

            // 阶段描述
            Text(progress.step.description)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)

            // 当前文件名
            Text(progress.currentFileName.isEmpty ? t("preparing") : progress.currentFileName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .frame(maxWidth: 360)

            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "3B82F6"), Color(hex: "60A5FA")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * CGFloat(progress.fractionCompleted)), height: 8)
                    }
                }
                .frame(height: 8)

                HStack {
                    Text("\(progress.processedCount) / \(progress.totalCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))

                    Spacer()

                    Text("\(Int(progress.fractionCompleted * 100))%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: 360)

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func resultView(result: MigrationResult) -> some View {
        VStack(spacing: 20) {
            Spacer()

            switch result {
            case .success(let movedFiles, _):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color(hex: "10B981"))

                Text(t("migrationSuccess"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Text("\(t("migratedFiles")): \(movedFiles)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))

            case .partial(let successCount, let failCount, let errors):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color(hex: "F59E0B"))

                Text(t("migrationPartial"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(t("success")): \(successCount)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "10B981"))
                    Text("\(t("failed")): \(failCount)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "EF4444"))
                }

                if !errors.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(errors.prefix(5).enumerated()), id: \.offset) { _, error in
                                Text(error)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxHeight: 60)
                }

            case .failure(let error):
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color(hex: "EF4444"))

                Text(t("migrationFailed"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button {
                isPresented = false
            } label: {
                Text(t("done"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func pickDirectory() {
        guard let selectedURL = downloadPathManager.showDirectoryPicker() else { return }
        selectedDirectoryPath = selectedURL.path
    }

    private func startMigration() {
        guard !selectedDirectoryPath.isEmpty else { return }

        let oldRoot = downloadPathManager.rootFolderURL
        let selectedURL = URL(fileURLWithPath: selectedDirectoryPath)

        let oldPath = oldRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let newParentPath = selectedURL.resolvingSymlinksInPath().standardizedFileURL.path
        let oldPathSlash = oldPath.hasSuffix("/") ? oldPath : oldPath + "/"
        let newPathSlash = newParentPath.hasSuffix("/") ? newParentPath : newParentPath + "/"
        if oldPath == newParentPath || newPathSlash.hasPrefix(oldPathSlash) || oldPathSlash.hasPrefix(newPathSlash) {
            result = .failure(error: t("invalidDirectorySelection"))
            return
        }

        isMigrating = true

        guard downloadPathManager.setCustomRoot(parentURL: selectedURL) else {
            isMigrating = false
            result = .failure(error: t("failedToSetDirectory"))
            return
        }

        let newRoot = downloadPathManager.rootFolderURL

        Task {
            let migrationResult = await DirectoryMigrationService.shared.migrate(
                from: oldRoot,
                to: newRoot
            ) { progress in
                self.progress = progress
            }

            self.result = migrationResult
            self.isMigrating = false

            NotificationCenter.default.post(name: .downloadPathChanged, object: nil)
        }
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

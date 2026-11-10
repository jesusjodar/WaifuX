import Foundation

// MARK: - WaifuX GuideKit · 导览脚本内容
// 每页一段 GuideTour；文案 key 统一 guide.<tour>.<step>.title|body，
// 四语（es/en/zh/ja）在 Services/LocalizationService.swift 同步维护。

enum GuideTours {

    /// tab → 该页导览。
    static func tour(for tab: MainTab) -> GuideTour? {
        switch tab {
        case .home:
            return home
        case .wallpaperExplore:
            return explore
        case .myMedia:
            return library
        }
    }

    /// 详情页导览：由详情浮层打开时触发（GuideEngine.noteDetailOpened）。
    static let detail = GuideTour(
        id: "detail",
        contentVersion: 2,
        steps: [
            // ① 底部动作栏（收藏/预览/设为壁纸/下载/更多）
            GuideStep(
                anchor: .detailActionRow,
                titleKey: "guide.detail.action.title",
                bodyKey: "guide.detail.action.body"
            ),
            // ② hero 浮层 info / eye 小按钮（Wallpaper 详情页锚点）
            GuideStep(
                anchor: .detailHeroInfo,
                titleKey: "guide.detail.overlay.title",
                bodyKey: "guide.detail.overlay.body"
            ),
            // ③ 信息行的作者胶囊：点开作者面板（Wallpaper 作者按钮共用锚点）
            GuideStep(
                anchor: .detailAuthorLink,
                titleKey: "guide.detail.author.title",
                bodyKey: "guide.detail.author.body"
            ),
            // ④ 键盘快捷键（无锚点居中卡：Space / ↑↓ / Esc 分层关闭）
            GuideStep(
                anchor: nil,
                titleKey: "guide.detail.keyboard.title",
                bodyKey: "guide.detail.keyboard.body"
            )
        ]
    )

    /// 「更多选项」popover：弹出即播（noteSheetOpened，popover 独立 NSWindow，
    /// 引擎会把遮罩抬到 .popUpMenu 之上）。
    static let detailMoreOptions = GuideTour(
        id: "detailMoreOptions",
        contentVersion: 2,
        steps: [
            GuideStep(
                anchor: .detailMorePopover,
                titleKey: "guide.detailMore.title",
                bodyKey: "guide.detailMore.body"
            )
        ]
    )



    /// 设置页总览：打开设置窗首次播（左栏分类逐个高亮）。
    static let settingsOverview = GuideTour(
        id: "settingsOverview",
        contentVersion: 2,
        steps: [
            GuideStep(
                anchor: nil,
                titleKey: "guide.settings.welcome.title",
                bodyKey: "guide.settings.welcome.body"
            ),
            GuideStep(
                anchor: .settingsTabGeneral,
                titleKey: "guide.settings.general.title",
                bodyKey: "guide.settings.general.body"
            ),
            GuideStep(
                anchor: .settingsTabDownload,
                titleKey: "guide.settings.download.title",
                bodyKey: "guide.settings.download.body"
            ),
            GuideStep(
                anchor: .settingsTabWallhaven,
                titleKey: "guide.settings.wallhaven.title",
                bodyKey: "guide.settings.wallhaven.body"
            ),
            GuideStep(
                anchor: .settingsTabScheduler,
                titleKey: "guide.settings.scheduler.title",
                bodyKey: "guide.settings.scheduler.body"
            ),
            GuideStep(
                anchor: .settingsTabAbout,
                titleKey: "guide.settings.about.title",
                bodyKey: "guide.settings.about.body"
            )
        ]
    )

    /// 作者滑出面板：打开即播（noteSheetOpened；主窗口内 overlay）。
    static let authorSheet = GuideTour(
        id: "authorSheet",
        contentVersion: 2,
        steps: [
            GuideStep(
                anchor: .authorSheetHeader,
                titleKey: "guide.author.title",
                bodyKey: "guide.author.body"
            )
        ]
    )

    // MARK: 首页（Phase 1 示范：5 步，含菜单栏步）

    static let home = GuideTour(
        id: "home",
        contentVersion: 2,
        steps: [
            GuideStep(
                anchor: nil,
                titleKey: "guide.home.welcome.title",
                bodyKey: "guide.home.welcome.body"
            ),
            GuideStep(
                anchor: .homeTabBar,
                titleKey: "guide.home.tabs.title",
                bodyKey: "guide.home.tabs.body"
            ),
            GuideStep(
                anchor: .topBarHelp,
                titleKey: "guide.home.help.title",
                bodyKey: "guide.home.help.body"
            ),
            GuideStep(
                anchor: .homeHero,
                titleKey: "guide.home.hero.title",
                bodyKey: "guide.home.hero.body"
            ),
            GuideStep(
                anchor: .homeHeroActions,
                titleKey: "guide.home.heroActions.title",
                bodyKey: "guide.home.heroActions.body"
            ),
            GuideStep(
                anchor: .menubarStatusItem,
                titleKey: "guide.home.menubar.title",
                bodyKey: "guide.home.menubar.body"
            )
        ]
    )

    // MARK: 静态壁纸探索（4 步）

    static let explore = GuideTour(
        id: "wallpaperExplore",
        contentVersion: 2,
        steps: [
            GuideStep(
                anchor: .exploreHeader,
                titleKey: "guide.explore.scroll.title",
                bodyKey: "guide.explore.scroll.body"
            ),
            GuideStep(
                anchor: .exploreRatioMenu,
                titleKey: "guide.explore.ratio.title",
                bodyKey: "guide.explore.ratio.body"
            ),
            // 搜索行三个快捷圆钮（链接导入 / 氛围背景 / 重置筛选）
            GuideStep(
                anchor: .exploreActionCircles,
                titleKey: "guide.circles.title",
                bodyKey: "guide.circles.body"
            ),
            // 仅滚动后出现；未出现时该步自动跳过
            GuideStep(
                anchor: .exploreScrollToTop,
                titleKey: "guide.explore.top.title",
                bodyKey: "guide.explore.top.body"
            )
        ]
    )







    // MARK: 我的库（3 步）

    static let library = GuideTour(
        id: "myMedia",
        contentVersion: 2,
        steps: [
            GuideStep(
                anchor: .libraryEditButton,
                titleKey: "guide.library.edit.title",
                bodyKey: "guide.library.edit.body"
            ),
            // 右键菜单（内容卡与文件夹卡菜单不同）无固定单点目标：居中卡说明
            GuideStep(
                anchor: nil,
                titleKey: "guide.library.menu.title",
                bodyKey: "guide.library.menu.body"
            ),
            // 拖拽（拖入文件夹/编辑态整组拖/排序）
            GuideStep(
                anchor: nil,
                titleKey: "guide.library.drag.title",
                bodyKey: "guide.library.drag.body"
            ),
            GuideStep(
                anchor: .librarySearchControl,
                titleKey: "guide.library.search.title",
                bodyKey: "guide.library.search.body"
            ),
            GuideStep(
                anchor: .libraryMoreMenuButton,
                titleKey: "guide.library.more.title",
                bodyKey: "guide.library.more.body"
            )
        ]
    )
}

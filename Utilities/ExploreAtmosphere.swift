import SwiftUI
import AppKit
import Kingfisher
import Combine

// MARK: - 探索页氛围色（背景光斑 + 液态玻璃主题色）

struct ExploreAtmosphereTint {
    var primary: Color
    var secondary: Color
    var tertiary: Color
    var baseTop: Color
    var baseBottom: Color

    static let wallpaperFallback = ExploreAtmosphereTint(
        primary: Color(hex: "5A7CFF"),
        secondary: Color(hex: "8A5CFF"),
        tertiary: Color(hex: "20C1FF"),
        baseTop: Color(hex: "1D2128"),
        baseBottom: Color(hex: "0E1116")
    )

    static let mediaFallback = ExploreAtmosphereTint(
        primary: Color(hex: "20C1FF"),
        secondary: Color(hex: "6D42FF"),
        tertiary: Color(hex: "2EE6A6"),
        baseTop: Color(hex: "1D2128"),
        baseBottom: Color(hex: "0E1116")
    )

    static func fromWallpaperMetadata(_ wallpaper: Wallpaper) -> ExploreAtmosphereTint {
        let palette = HeroDrivenPalette(wallpaper: wallpaper)
        return ExploreAtmosphereTint(
            primary: palette.primary,
            secondary: palette.secondary,
            tertiary: palette.tertiary,
            baseTop: Color(hex: "1D2128"),
            baseBottom: Color(hex: "0E1116")
        )
    }

    static func fromSampledTriplet(_ a: Color, _ b: Color, _ c: Color) -> ExploreAtmosphereTint {
        ExploreAtmosphereTint(
            primary: a,
            secondary: b,
            tertiary: c,
            baseTop: Color(hex: "1D2128"),
            baseBottom: Color(hex: "0E1116")
        )
    }
}

// MARK: - Environment（子视图同步主题色）

private struct ExplorePageAtmosphereTintKey: EnvironmentKey {
    static let defaultValue = ExploreAtmosphereTint.wallpaperFallback
}

extension EnvironmentValues {
    var explorePageAtmosphereTint: ExploreAtmosphereTint {
        get { self[ExplorePageAtmosphereTintKey.self] }
        set { self[ExplorePageAtmosphereTintKey.self] = newValue }
    }
}

// MARK: - 缩略图三色采样（左/中/右条带平均）

enum ExploreImageColorSampler {
    /// 从图片采样三色
    /// - Parameter image: 要采样的图片
    static func triplet(from image: NSImage) -> (Color, Color, Color)? {
        let pixelWidth: CGFloat = 48
        let pixelHeight: CGFloat = 48
        let size = NSSize(width: pixelWidth, height: pixelHeight)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelWidth),
            pixelsHigh: Int(pixelHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()

        let drawRect = NSRect(origin: .zero, size: size)
        let sourceRect: NSRect = .zero

        image.draw(
            in: drawRect,
            from: sourceRect,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return nil }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let bpp = max(rep.bitsPerPixel / 8, 4)

        func average(in rect: (x: Int, y: Int, width: Int, height: Int)) -> (Double, Double, Double) {
            var r: Double = 0
            var g: Double = 0
            var b: Double = 0
            var n: Double = 0
            let x1 = max(0, rect.x)
            let y1 = max(0, rect.y)
            let x2 = min(w, rect.x + rect.width)
            let y2 = min(h, rect.y + rect.height)
            for y in y1..<y2 {
                for x in x1..<x2 {
                    let o = (y * w + x) * bpp
                    guard o + 2 < rep.bytesPerRow * h else { continue }
                    r += Double(data[o])
                    g += Double(data[o &+ 1])
                    b += Double(data[o &+ 2])
                    n += 1
                }
            }
            guard n > 0 else { return (0.15, 0.15, 0.18) }
            return (r / n / 255, g / n / 255, b / n / 255)
        }

        let colW = max(1, w / 3)
        let a1 = boost(average(in: (0, 0, colW, h)))
        let a2 = boost(average(in: (colW, 0, colW, h)))
        let a3 = boost(average(in: (colW * 2, 0, w - colW * 2, h)))

        return (color(from: a1), color(from: a2), color(from: a3))
    }

    private static func boost(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let mx = max(rgb.0, rgb.1, rgb.2)
        let mn = min(rgb.0, rgb.1, rgb.2)
        let saturation = mx > 0 ? (mx - mn) / mx : 0

        // 基础提亮：让整体更亮更通透
        let brighten: (Double) -> Double = { c in
            // 非线性提亮：暗部提升更多，亮部保持
            let lifted = pow(c, 0.85)
            // 整体提亮 15%
            return min(1.0, lifted * 1.15 + 0.04)
        }

        var r = brighten(rgb.0)
        var g = brighten(rgb.1)
        var b = brighten(rgb.2)

        // 低饱和度颜色（偏灰）：增加一点冷暖倾向，避免死灰
        if saturation < 0.12 {
            if mx == rgb.0 { r = min(1, r + 0.08) }
            else if mx == rgb.2 { b = min(1, b + 0.08) }
            else { g = min(1, g + 0.06); b = min(1, b + 0.04) }
        }

        // 增加饱和度：让颜色更鲜艳
        let avg = (r + g + b) / 3
        let satBoost: Double = saturation < 0.3 ? 1.25 : 1.1
        r = min(1, avg + (r - avg) * satBoost)
        g = min(1, avg + (g - avg) * satBoost)
        b = min(1, avg + (b - avg) * satBoost)

        return (r, g, b)
    }

    private static func color(from rgb: (Double, Double, Double)) -> Color {
        Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

// MARK: - 氛围底图用缩略 NSImage（降低全屏 blur 的像素与内存）

extension NSImage {
    /// 限制最大边长（点），供 `ExploreDynamicAtmosphereBackground` 做大面积模糊用，避免对原图全尺寸 blur。
    func constrainedForAtmosphereBackdrop(maxEdge: CGFloat = 512) -> NSImage {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0, w.isFinite, h.isFinite else { return self }
        let longest = max(w, h)
        guard longest > maxEdge else { return self }
        let scale = maxEdge / longest
        let nw = max(1, floor(w * scale))
        let nh = max(1, floor(h * scale))
        let newSize = NSSize(width: nw, height: nh)
        let img = NSImage(size: newSize)
        img.lockFocus()
        defer { img.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .low
        draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: NSSize(width: w, height: h)),
            operation: .copy,
            fraction: 1
        )
        return img
    }
}

// MARK: - 控制器（首张卡片缩略图 + 采样）

@MainActor
final class ExploreAtmosphereController: ObservableObject {
    @Published private(set) var tint: ExploreAtmosphereTint {
        didSet { headerStyleVersion &+= 1 }
    }
    @Published private(set) var referenceImage: NSImage?
    @Published private(set) var headerStyleVersion: UInt = 0

    private var loadTask: Task<Void, Never>?
    private let wallpaperMode: Bool
    private let atmosphereSampleSize = CGSize(width: 512, height: 512)
    /// 避免列表刷新但首张未变时重复拉缩略图、重复采样
    private var activeFirstItemKey: String?
    private var cancellables = Set<AnyCancellable>()

    init(wallpaperMode: Bool) {
        self.wallpaperMode = wallpaperMode
        self.tint = wallpaperMode ? .wallpaperFallback : .mediaFallback

        // 监听应用隐藏窗口通知，清理大内存占用（异步执行避免卡顿）
        NotificationCenter.default.publisher(for: .appDidHideWindow)
            .sink { [weak self] _ in
                // 使用低优先级队列异步执行
                Task(priority: .background) { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000) // 0.05秒延迟
                    self?.clearMemory()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        loadTask?.cancel()
        // cancellables 会自动释放，无需手动清理
    }

    /// 清理大内存占用，但保留颜色主题
    func clearMemory() {
        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil
        // 不重置 activeFirstItemKey，这样重新打开窗口时不会重复加载同一张图
    }

    func resetToFallback() {
        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil
        activeFirstItemKey = nil
        tint = wallpaperMode ? .wallpaperFallback : .mediaFallback
    }

    /// 切到其他 tab 时暂停后台任务（保留当前颜色，只取消未完成的加载）
    func pause() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func retrieveAtmosphereImage(from url: URL) async -> KFCrossPlatformImage? {
        let processor = DownsamplingImageProcessor(size: atmosphereSampleSize)
        let result = try? await KingfisherManager.shared.retrieveImage(
            with: .network(url),
            options: [
                .processor(processor),
                .backgroundDecode
            ]
        )
        return result?.image
    }

    func updateFirstWallpaper(_ wallpaper: Wallpaper?) {
        guard let wallpaper else {
            resetToFallback()
            return
        }

        let key = "w:\(wallpaper.id)"
        if key == activeFirstItemKey, referenceImage != nil {
            return
        }
        activeFirstItemKey = key

        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil

        tint = ExploreAtmosphereTint.fromWallpaperMetadata(wallpaper)

        guard let url = wallpaper.thumbURL ?? wallpaper.smallThumbURL else { return }

        loadTask = Task {
            guard let image = await retrieveAtmosphereImage(from: url),
                  !Task.isCancelled else { return }

            let processed = await Task.detached(priority: .userInitiated) {
                let small = image.constrainedForAtmosphereBackdrop()
                let sampledColors = ExploreImageColorSampler.triplet(from: small)
                return (small, sampledColors)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.referenceImage = processed.0
                if let (c1, c2, c3) = processed.1 {
                    self.tint = ExploreAtmosphereTint.fromSampledTriplet(c1, c2, c3)
                }
            }
        }
    }

    func updateFromImageURL(_ url: URL?, keyPrefix: String = "rand") {
        guard let url else {
            resetToFallback()
            return
        }
        let key = "\(keyPrefix):\(url.absoluteString)"
        if key == activeFirstItemKey, referenceImage != nil {
            return
        }
        activeFirstItemKey = key
        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil

        loadTask = Task {
            guard let image = await retrieveAtmosphereImage(from: url),
                  !Task.isCancelled else { return }

            let processed = await Task.detached(priority: .userInitiated) {
                let small = image.constrainedForAtmosphereBackdrop()
                let sampledColors = ExploreImageColorSampler.triplet(from: small)
                return (small, sampledColors)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.referenceImage = processed.0
                if let (c1, c2, c3) = processed.1 {
                    self.tint = ExploreAtmosphereTint.fromSampledTriplet(c1, c2, c3)
                }
            }
        }
    }
}

// MARK: - Arc 风格颗粒噪点纹理（更精细、更高对比度）

// MARK: - 全局胶片噪点纹理

/// 胶片颗粒纹理生成器（CIFilter 管线 + 簇化缩放）
///
/// 参考实现：neberej/daily-tools-mac-ios GrainEffect.swift
/// 关键技术：CIRandomGenerator 生成高频噪声 → 缩小 0.25x → 最近邻放大 4x
/// 产生 2~3 像素的颗粒簇（而非单像素数字噪点），模拟真实胶片的有机颗粒感
enum GrainTextureTile {
    /// 用于 SwiftUI `.blendMode(.softLight)` 的单帧颗粒纹理
    static let image: NSImage = generateGrainTile()

    /// 用于 NSView CGContext overlay 混合的单帧颗粒纹理
    static let cgImage: CGImage = generateGrainCGImage()

    // MARK: - 私有生成

    private static func generateGrainTile() -> NSImage {
        let ciImage = makeGrainCIImage()
        let rep = NSCIImageRep(ciImage: ciImage)
        let nsImage = NSImage(size: NSSize(width: rep.size.width, height: rep.size.height))
        nsImage.addRepresentation(rep)
        return nsImage
    }

    private static func generateGrainCGImage() -> CGImage {
        let ciImage = makeGrainCIImage()
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let w = Int(ciImage.extent.width)
        let h = Int(ciImage.extent.height)
        let fallback = CIContext().createCGImage(
            CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)),
            from: CGRect(x: 0, y: 0, width: 256, height: 256)
        )!
        return context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: w, height: h))
            ?? fallback
    }

    private static func makeGrainCIImage() -> CIImage {
        // 1. CIRandomGenerator：生成全白高频噪声
        guard let noiseFilter = CIFilter(name: "CIRandomGenerator") else {
            return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        }
        var noise = noiseFilter.outputImage ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))

        // 2. CIColorControls：去饱和 + 降低亮度 → 单色暗调噪点
        //    saturation=0 去色；brightness=-0.3 整体压暗，模拟胶片颗粒的暗调特征
        if let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setValue(noise, forKey: kCIInputImageKey)
            colorFilter.setValue(0.0, forKey: kCIInputSaturationKey)
            colorFilter.setValue(-0.3, forKey: kCIInputBrightnessKey)
            noise = colorFilter.outputImage ?? noise
        }

        // 3. 簇化缩放（关键技术）：
        //    缩小到 0.25x 丢失细节，再用最近邻放大 4x → 单像素变成 4x4 像素块
        //    产生 2~3 像素的颗粒簇，这是胶片颗粒与数字噪点的核心区别
        let clusterScale: CGFloat = 0.25
        let zoomed = noise
            .transformed(by: CGAffineTransform(scaleX: clusterScale, y: clusterScale))
            .transformed(by: CGAffineTransform(scaleX: 1.0 / clusterScale, y: 1.0 / clusterScale))

        // 4. 裁剪到 256x256 输出区域（放大后中心区域）
        let outputSize = 256.0
        let cropRect = CGRect(
            x: zoomed.extent.midX - outputSize / 2,
            y: zoomed.extent.midY - outputSize / 2,
            width: outputSize,
            height: outputSize
        )
        return zoomed.cropped(to: cropRect)
    }
}

// MARK: - 动态背景：散色模糊底图 + 原有氛围渐变 + 轻磨砂 + 噪点

struct ExploreDynamicAtmosphereBackground: View {
    let tint: ExploreAtmosphereTint
    let referenceImage: NSImage?
    /// 快速滚动时减轻效果，避免卡顿
    var lightweightBackdrop: Bool = false

    // 预计算颜色值（避免 body 中重复创建 Color 结构体）
    private var primaryColor: Color { tint.primary }
    private var secondaryColor: Color { tint.secondary }
    private var tertiaryColor: Color { tint.tertiary }
    private var baseTopColor: Color { tint.baseTop }

    var body: some View {
        ZStack {
            // 基础氛围背景
            LiquidGlassAtmosphereBackground(
                primary: primaryColor,
                secondary: secondaryColor,
                tertiary: tertiaryColor,
                baseTop: baseTopColor,
                baseBottom: tint.baseBottom
            )

            // 参考图片模糊背景（轻量模式时完全禁用）
            if !lightweightBackdrop, let referenceImage {
                // 参考图已在控制器中压到最长边约 256pt，此处用适中 blur 即可铺满视觉，避免对大图做超大半径模糊
                Image(nsImage: referenceImage)
                    .resizable()
                    .interpolation(.low)
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 160, minHeight: 160)
                    .blur(radius: 32)
                    .opacity(0.2)
                    .saturation(1.05)
                    .allowsHitTesting(false)
            }

            // 漫射光晕：分散到四个角落，避免只集中在中间
            RadialGradient(
                colors: [
                    primaryColor.opacity(lightweightBackdrop ? 0.10 : 0.14),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 40,
                endRadius: lightweightBackdrop ? 400 : 600
            )
            .allowsHitTesting(false)

            RadialGradient(
                colors: [
                    secondaryColor.opacity(lightweightBackdrop ? 0.08 : 0.12),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: lightweightBackdrop ? 350 : 550
            )
            .allowsHitTesting(false)

            RadialGradient(
                colors: [
                    tertiaryColor.opacity(lightweightBackdrop ? 0.06 : 0.10),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 30,
                endRadius: lightweightBackdrop ? 300 : 450
            )
            .allowsHitTesting(false)

            // 极淡的中心提亮，平衡四角
            RadialGradient(
                colors: [
                    baseTopColor.opacity(0.04),
                    Color.clear
                ],
                center: .center,
                startRadius: 100,
                endRadius: lightweightBackdrop ? 500 : 700
            )
            .allowsHitTesting(false)

            // 底部极淡过渡（仅轻微压暗，避免底部过暗）
            LinearGradient(
                colors: [
                    Color.clear,
                    tint.baseBottom.opacity(0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

import AppKit
import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Portrait Blur Fill Artifacts

/// 为竖向静态图生成与显示器比例一致的模糊延伸版本。
///
/// 派生文件和原图分开保存，并以源文件指纹 + 目标像素尺寸建立映射，因此不会改写
/// 下载记录、收藏记录或原始图片。映射随派生目录保存，旧原图删除时可精确清理。
actor PortraitBlurFillWallpaperService {
    static let shared = PortraitBlurFillWallpaperService()

    private static let mappingFileName = "mapping.json"
    private static let artifactDirectoryName = "PortraitBlurFill"
    private static let rendererVersion = 1

    private struct MappingDocument: Codable {
        var version: Int
        var artifacts: [String: Artifact]
    }

    private struct Artifact: Codable {
        var sourcePath: String
        var sourceFingerprint: String
        var targetWidth: Int
        var targetHeight: Int
        var outputPath: String
        var createdAt: Date
    }

    private struct RenderRequest: Sendable {
        var sourceURL: URL
        var outputURL: URL
        var targetWidth: Int
        var targetHeight: Int
    }

    private var artifacts: [String: Artifact] = [:]
    private var loadedMappingURL: URL?

    /// 返回给指定显示器使用的派生图；横图或关闭开关时由调用方直接跳过此服务。
    func preparedWallpaperURL(
        for sourceURL: URL,
        targetPixelSize: CGSize,
        derivedWallpapersDirectory: URL
    ) async throws -> URL {
        let targetWidth = max(1, Int(targetPixelSize.width.rounded()))
        let targetHeight = max(1, Int(targetPixelSize.height.rounded()))
        guard targetWidth > 1, targetHeight > 1 else { return sourceURL }

        let sourcePath = sourceURL.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: t("原始壁纸文件不存在")]
            )
        }

        let sourceSize = try Self.pixelSize(of: sourceURL)
        guard sourceSize.height > sourceSize.width else { return sourceURL }

        let artifactDirectory = derivedWallpapersDirectory
            .appendingPathComponent(Self.artifactDirectoryName, isDirectory: true)
        let mappingURL = artifactDirectory.appendingPathComponent(Self.mappingFileName)
        try loadArtifactsIfNeeded(from: mappingURL)

        let sourceFingerprint = try Self.sourceFingerprint(for: sourceURL)
        let key = Self.artifactKey(
            sourceFingerprint: sourceFingerprint,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )

        if let artifact = artifacts[key],
           artifact.sourceFingerprint == sourceFingerprint,
           FileManager.default.fileExists(atPath: artifact.outputPath) {
            return URL(fileURLWithPath: artifact.outputPath)
        }

        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: true
        )

        let outputURL = artifactDirectory.appendingPathComponent("blur-fill-\(key).jpg")
        let request = RenderRequest(
            sourceURL: sourceURL,
            outputURL: outputURL,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        try await Task.detached(priority: .userInitiated) {
            try Self.render(request)
        }.value

        artifacts[key] = Artifact(
            sourcePath: sourcePath,
            sourceFingerprint: sourceFingerprint,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            outputPath: outputURL.path,
            createdAt: .now
        )
        try persistArtifacts(to: mappingURL)
        return outputURL
    }

    /// 将实际显示在桌面上的派生图反查为库记录使用的原图。
    /// 映射读取与已有生成/迁移操作都在 actor 内串行，调用方无需阻塞主线程。
    func originalSourceURL(
        forDerivedWallpaperAt url: URL,
        derivedWallpapersDirectory: URL
    ) -> URL? {
        guard url.isFileURL else { return nil }
        let mappingURL = derivedWallpapersDirectory
            .appendingPathComponent(Self.artifactDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.mappingFileName)
        guard (try? loadArtifactsIfNeeded(from: mappingURL)) != nil else { return nil }
        let path = url.standardizedFileURL.path
        guard let artifact = artifacts.values.first(where: {
            URL(fileURLWithPath: $0.outputPath).standardizedFileURL.path == path
        }) else { return nil }
        return URL(fileURLWithPath: artifact.sourcePath)
    }

    /// 原图被用户删除时移除全部关联派生文件，不影响其他来源的生成结果。
    func removeArtifacts(
        for sourceURL: URL,
        derivedWallpapersDirectory: URL
    ) {
        let artifactDirectory = derivedWallpapersDirectory
            .appendingPathComponent(Self.artifactDirectoryName, isDirectory: true)
        let mappingURL = artifactDirectory.appendingPathComponent(Self.mappingFileName)
        guard (try? loadArtifactsIfNeeded(from: mappingURL)) != nil else { return }

        let sourcePath = sourceURL.standardizedFileURL.path
        let keys = artifacts.compactMap { key, artifact in
            artifact.sourcePath == sourcePath ? key : nil
        }
        guard !keys.isEmpty else { return }

        for key in keys {
            if let outputPath = artifacts[key]?.outputPath {
                try? FileManager.default.removeItem(atPath: outputPath)
            }
            artifacts.removeValue(forKey: key)
        }
        try? persistArtifacts(to: mappingURL)
    }

    /// 下载根目录迁移后，修复 copied mapping.json 中的绝对路径与缓存键。
    func rebaseArtifacts(
        from oldRoot: URL,
        to newRoot: URL,
        derivedWallpapersDirectory: URL
    ) {
        let artifactDirectory = derivedWallpapersDirectory
            .appendingPathComponent(Self.artifactDirectoryName, isDirectory: true)
        let mappingURL = artifactDirectory.appendingPathComponent(Self.mappingFileName)
        guard (try? loadArtifactsIfNeeded(from: mappingURL)) != nil else { return }

        var rebased: [String: Artifact] = [:]
        for artifact in artifacts.values {
            var next = artifact
            next.sourcePath = Self.rebasedPath(
                artifact.sourcePath,
                from: oldRoot.path,
                to: newRoot.path
            )
            next.outputPath = Self.rebasedPath(
                artifact.outputPath,
                from: oldRoot.path,
                to: newRoot.path
            )
            next.sourceFingerprint = Self.rebasedPath(
                artifact.sourceFingerprint,
                from: oldRoot.path,
                to: newRoot.path
            )
            let key = Self.artifactKey(
                sourceFingerprint: next.sourceFingerprint,
                targetWidth: next.targetWidth,
                targetHeight: next.targetHeight
            )
            rebased[key] = next
        }
        artifacts = rebased
        try? persistArtifacts(to: mappingURL)
    }

    private func loadArtifactsIfNeeded(from mappingURL: URL) throws {
        guard loadedMappingURL?.standardizedFileURL != mappingURL.standardizedFileURL else {
            return
        }

        loadedMappingURL = mappingURL
        guard FileManager.default.fileExists(atPath: mappingURL.path) else {
            artifacts = [:]
            return
        }

        let data = try Data(contentsOf: mappingURL)
        let document = try JSONDecoder().decode(MappingDocument.self, from: data)
        artifacts = document.version == Self.rendererVersion ? document.artifacts : [:]
    }

    private func persistArtifacts(to mappingURL: URL) throws {
        try FileManager.default.createDirectory(
            at: mappingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = MappingDocument(
            version: Self.rendererVersion,
            artifacts: artifacts
        )
        let data = try JSONEncoder().encode(document)
        try data.write(to: mappingURL, options: .atomic)
    }

    private nonisolated static func pixelSize(of sourceURL: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: t("无法读取原始壁纸尺寸")]
            )
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let shouldSwapDimensions = (5...8).contains(orientation)
        let width = CGFloat(shouldSwapDimensions ? rawHeight.intValue : rawWidth.intValue)
        let height = CGFloat(shouldSwapDimensions ? rawWidth.intValue : rawHeight.intValue)
        return CGSize(width: width, height: height)
    }

    private nonisolated static func sourceFingerprint(for sourceURL: URL) throws -> String {
        let standardized = sourceURL.standardizedFileURL
        let values = try standardized.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let size = values.fileSize ?? 0
        let modifiedAt = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(standardized.path)|\(size)|\(modifiedAt)"
    }

    private nonisolated static func artifactKey(
        sourceFingerprint: String,
        targetWidth: Int,
        targetHeight: Int
    ) -> String {
        let raw = "\(rendererVersion)|\(sourceFingerprint)|\(targetWidth)x\(targetHeight)"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func rebasedPath(
        _ value: String,
        from oldPrefix: String,
        to newPrefix: String
    ) -> String {
        guard value == oldPrefix || value.hasPrefix(oldPrefix + "/") else {
            return value
        }
        return newPrefix + String(value.dropFirst(oldPrefix.count))
    }

    private nonisolated static func render(_ request: RenderRequest) throws {
        guard let source = CGImageSourceCreateWithURL(request.sourceURL as CFURL, nil) else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: t("无法解码原始壁纸")]
            )
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: t("无法解码原始壁纸图像")]
            )
        }

        let orientation = (
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )?[kCGImagePropertyOrientation] as? NSNumber
        let orientedSourceImage = CIImage(cgImage: sourceImage)
            .oriented(forExifOrientation: Int32(orientation?.intValue ?? 1))
        let sourceExtent = orientedSourceImage.extent.integral
        let sourceImageCI = orientedSourceImage.transformed(by: CGAffineTransform(
            translationX: -sourceExtent.origin.x,
            y: -sourceExtent.origin.y
        ))
        let sourceWidth = sourceExtent.width
        let sourceHeight = sourceExtent.height
        let targetWidth = CGFloat(request.targetWidth)
        let targetHeight = CGFloat(request.targetHeight)
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: t("壁纸图像尺寸无效")]
            )
        }

        let targetRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)

        // 背景使用 aspect-fill 后的同一图片，模糊并略微压暗；前景完整保留原图。
        let backgroundScale = max(targetWidth / sourceWidth, targetHeight / sourceHeight)
        let backgroundWidth = sourceWidth * backgroundScale
        let backgroundHeight = sourceHeight * backgroundScale
        let background = sourceImageCI.transformed(by: CGAffineTransform(
            a: backgroundScale,
            b: 0,
            c: 0,
            d: backgroundScale,
            tx: (targetWidth - backgroundWidth) / 2,
            ty: (targetHeight - backgroundHeight) / 2
        ))
        let blurRadius = min(120, max(42, min(targetWidth, targetHeight) * 0.075))
        let blurredBackground = background
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: targetRect)
        let darkenedBackground = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.18)
        )
        .cropped(to: targetRect)
        .composited(over: blurredBackground)

        let foregroundScale = min(targetWidth / sourceWidth, targetHeight / sourceHeight)
        let foregroundWidth = sourceWidth * foregroundScale
        let foregroundHeight = sourceHeight * foregroundScale
        let foreground = sourceImageCI.transformed(by: CGAffineTransform(
            a: foregroundScale,
            b: 0,
            c: 0,
            d: foregroundScale,
            tx: (targetWidth - foregroundWidth) / 2,
            ty: (targetHeight - foregroundHeight) / 2
        ))
        let finalImage = foreground
            .composited(over: darkenedBackground)
            .cropped(to: targetRect)

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let renderedImage = context.createCGImage(finalImage, from: targetRect) else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: t("无法渲染模糊填充壁纸")]
            )
        }

        let temporaryURL = request.outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: t("无法创建模糊填充壁纸文件")]
            )
        }

        CGImageDestinationAddImage(
            destination,
            renderedImage,
            [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: t("无法写入模糊填充壁纸文件")]
            )
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: request.outputURL.path) {
            try fileManager.removeItem(at: request.outputURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: request.outputURL)
    }
}

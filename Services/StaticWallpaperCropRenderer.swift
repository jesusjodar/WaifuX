import CoreGraphics
import Foundation

/// Renders a screen-sized derivative; the downloaded original is never modified.
enum StaticWallpaperCropRenderer {
    static func render(image: CGImage, targetSize: CGSize, settings: DisplayCropSettings) throws -> CGImage {
        guard let budget = WallpaperSnapshotPixelBudget.layout(width: targetSize.width, height: targetSize.height),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: budget.width, height: budget.height,
                  bitsPerComponent: 8, bytesPerRow: budget.bytesPerRow, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let size = CGSize(width: budget.width, height: budget.height)
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: image.width, height: image.height), screenSize: size, settings: settings)
        context.setFillColor(layout.letterboxColor)
        context.fill(CGRect(origin: .zero, size: size))
        let rect = layout.wallpaperCropRect
        guard let cropped = image.cropping(to: CGRect(
            x: rect.x * Double(image.width), y: rect.y * Double(image.height),
            width: rect.w * Double(image.width), height: rect.h * Double(image.height))) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let viewport = layout.viewportRect
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: viewport.x * size.width,
            y: (1 - viewport.y - viewport.h) * size.height,
            width: viewport.w * size.width, height: viewport.h * size.height))
        guard let output = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return output
    }
}

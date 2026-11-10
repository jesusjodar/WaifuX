import AppKit
import SwiftUI

/// An image-only preview. ImageIO prepares a bounded bitmap off the main thread;
/// the original file stays unchanged, and NSScrollView handles pinch and pan.
struct StaticWallpaperPreview: View {
    let url: URL
    @State private var image: NSImage?
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                GeometryReader { geometry in
                    NativeImagePreview(image: image, viewportSize: geometry.size)
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.white).padding(32)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 12) {
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help(t("wallhaven.preview.fullscreen"))
                Button { PreviewWindowManager.shared.closePreview() } label: {
                    Image(systemName: "xmark")
                }
                .help(t("captcha.close"))
            }
            .font(.system(size: 14, weight: .semibold))
            .buttonStyle(.bordered).tint(.white)
            .padding(20)
        }
        .task(id: url) {
            guard url.isFileURL else { errorMessage = t("error"); return }
            let result = await Task.detached(priority: .userInitiated) {
                WallpaperBoundedImageDecoder.decode(url: url)
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let decoded): image = NSImage(cgImage: decoded.image, size: .zero)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .onKeyPress(.escape) {
            PreviewWindowManager.shared.closePreview()
            return .handled
        }
    }
}

private struct NativeImagePreview: NSViewRepresentable {
    let image: NSImage
    let viewportSize: CGSize
    func makeNSView(context: Context) -> NSScrollView {
        let view = NSScrollView()
        view.drawsBackground = true
        view.backgroundColor = .black
        view.allowsMagnification = true
        view.minMagnification = 1
        view.maxMagnification = 8
        view.hasHorizontalScroller = true
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        view.documentView = imageView
        return view
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let imageView = view.documentView as? NSImageView else { return }
        imageView.image = image
        let size = NSSize(width: max(1, viewportSize.width), height: max(1, viewportSize.height))
        if imageView.frame.size != size { imageView.setFrameSize(size) }
    }
}

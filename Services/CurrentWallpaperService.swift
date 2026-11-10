import AppKit
import Combine

/// The current verified static image on each managed display.
@MainActor
final class CurrentWallpaperService: ObservableObject {
    static let shared = CurrentWallpaperService()
    @Published private(set) var activeFilePaths = Set<String>()
    @Published private(set) var activeURLStrings = Set<String>()
    @Published private(set) var activeURLByScreenID: [String: URL] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var revision: UInt64 = 0

    private init() {
        if BackgroundRuntimeRole.isRemoteUI {
            BackgroundRuntimeBridge.observe { [weak self] snapshot in
                guard let self, let values = snapshot["current"] as? [String: String] else { return }
                self.accept(values.compactMapValues(URL.init(string:)))
            }
            return
        }
        for name in [NSApplication.didChangeScreenParametersNotification, DesktopWallpaperSyncManager.registrationDidChangeNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.rebuildActivePaths() }
                .store(in: &cancellables)
        }
        rebuildActivePaths()
    }

    func isCurrentWallpaper(localFileURL: URL?) -> Bool {
        guard let url = localFileURL else { return false }
        return activeURLStrings.contains(url.absoluteString)
            || (url.isFileURL && activeFilePaths.contains(url.standardizedFileURL.path))
    }
    func activeURL(for screenID: String) -> URL? { activeURLByScreenID[screenID] }

    private func accept(_ values: [String: URL]) {
        revision &+= 1
        let current = revision
        activeURLByScreenID = values
        activeURLStrings = Set(values.values.map(\.absoluteString))
        activeFilePaths = Set(values.values.filter(\.isFileURL).map { $0.standardizedFileURL.path })
        Task { [weak self] in
            let directory = DownloadPathManager.shared.derivedWallpapersFolderURL
            var originals: [URL] = []
            for url in values.values {
                let registered = DesktopWallpaperSyncManager.shared.originalSourceURL(for: url)
                if registered != url { originals.append(registered); continue }
                for service in [DerivedStaticWallpaperService.portrait, .crop] {
                    if let original = await service.originalSourceURL(forDerivedWallpaperAt: url, derivedWallpapersDirectory: directory) {
                        originals.append(original)
                    }
                }
            }
            guard let self, revision == current else { return }
            activeFilePaths.formUnion(originals.map { $0.standardizedFileURL.path })
        }
    }

    private func rebuildActivePaths() {
        let manager = DesktopWallpaperSyncManager.shared
        var values: [String: URL] = [:]
        for screen in NSScreen.screens where manager.hasPersistedWallpaperForFingerprint(screen.wallpaperScreenFingerprint) {
            values[screen.wallpaperScreenIdentifier] = manager.imageURL(for: screen)
        }
        accept(values)
    }
}

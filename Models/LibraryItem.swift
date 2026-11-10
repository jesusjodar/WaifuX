import Foundation

// MARK: - 文件夹内项目（统一类型，用于 UI 展示）

enum LibraryItem: Identifiable, Hashable {
    case folder(LibraryFolder)
    case wallpaper(Wallpaper, downloadDate: Date?)

    var id: String {
        switch self {
        case .folder(let folder): return "folder_\(folder.id)"
        case .wallpaper(let wallpaper, _): return wallpaper.id
        }
    }

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    var folder: LibraryFolder? {
        if case .folder(let f) = self { return f }
        return nil
    }

    var wallpaper: Wallpaper? {
        if case .wallpaper(let w, _) = self { return w }
        return nil
    }

}

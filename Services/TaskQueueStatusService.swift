import Combine
import Foundation

/// A read-only view of the original image download queue.
@MainActor
final class TaskQueueStatusService: ObservableObject {
    enum Category: CaseIterable, Equatable {
        case download
        var localizationKey: String { "statusbar.taskQueue.download" }
    }
    struct Entry: Identifiable, Equatable {
        let id: String
        let category: Category
        let title: String
        let progress: Double
    }
    static let shared = TaskQueueStatusService()
    @Published private(set) var entries: [Entry] = []
    private init(downloadService: DownloadTaskService = .shared) {
        downloadService.$tasks
            .map { tasks in
                tasks.filter(\.isRunning).sorted { $0.createdAt < $1.createdAt }.map {
                    Entry(id: $0.id, category: .download, title: $0.title, progress: max(0, min(1, $0.progress)))
                }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$entries)
    }
    var combinedProgress: Double {
        entries.isEmpty ? 0 : entries.reduce(0) { $0 + $1.progress } / Double(entries.count)
    }
}

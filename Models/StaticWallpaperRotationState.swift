import Foundation

/// The next item is only committed after desktop application succeeds.
/// Persist this state per physical display (or for the global display group).
struct StaticWallpaperRotationState: Codable, Equatable, Sendable {
  var currentID: String?
  var usedIDs: Set<String> = []
  var history: [String] = []
  var lastChangedAt: Date?

  func nextID(in candidates: [String], order: ScheduleOrder) -> String? {
    var seen = Set<String>()
    let ids = candidates.filter { seen.insert($0).inserted }
    guard !ids.isEmpty else { return nil }
    if order == .sequential {
      guard let currentID, let index = ids.firstIndex(of: currentID) else { return ids.first }
      return ids[(index + 1) % ids.count]
    }
    var remaining = ids.filter { !usedIDs.contains($0) }
    if remaining.isEmpty { remaining = ids }
    if remaining.count > 1 { remaining.removeAll { $0 == currentID } }
    return remaining.randomElement()
  }
  mutating func recordSelection(_ id: String, candidates: Set<String>, at date: Date = .now) {
    usedIDs.formIntersection(candidates)
    if usedIDs.isSuperset(of: candidates) { usedIDs.removeAll() }
    usedIDs.insert(id)
    if let currentID, currentID != id { history.append(currentID) }
    if history.count > 100 { history.removeFirst(history.count - 100) }
    currentID = id
    lastChangedAt = date
  }
  func previousID(in candidates: Set<String>) -> String? {
    history.last { candidates.contains($0) && $0 != currentID }
  }
  mutating func recordPrevious(_ id: String, at date: Date = .now) {
    if let index = history.lastIndex(of: id) { history.removeSubrange(index...) }
    currentID = id
    usedIDs.insert(id)
    lastChangedAt = date
  }
}

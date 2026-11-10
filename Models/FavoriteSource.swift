import Foundation

/// 当前仅保留本地收藏来源，占位以兼容旧代码结构。
enum FavoriteSource: String, Codable {
    case local
}

enum SyncOrigin: String, Codable {
    case local
    case cloud
}

enum SyncState: String, Codable {
    case localOnly
    case pendingUpload
    case synced
    case pendingDeletion
}

/// 为后续 CloudKit/苹果云同步预留的稳定本地元数据。
/// `recordID` 可以直接映射到未来的 `CKRecord.ID(recordName:)`。
struct SyncMetadata: Codable, Hashable {
    let recordID: String
    let entityType: String
    var createdAt: Date
    var updatedAt: Date
    var lastSyncedAt: Date?
    var changeTag: String?
    var origin: SyncOrigin
    var syncState: SyncState
    var isDeleted: Bool

    init(
        recordID: String,
        entityType: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastSyncedAt: Date? = nil,
        changeTag: String? = nil,
        origin: SyncOrigin = .local,
        syncState: SyncState = .localOnly,
        isDeleted: Bool = false
    ) {
        self.recordID = recordID
        self.entityType = entityType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
        self.changeTag = changeTag
        self.origin = origin
        self.syncState = syncState
        self.isDeleted = isDeleted
    }

    mutating func markLocalMutation(deleted: Bool? = nil, at date: Date = .now) {
        updatedAt = date
        origin = .local

        if let deleted {
            isDeleted = deleted
        }

        syncState = isDeleted ? .pendingDeletion : .pendingUpload
    }

    mutating func markSynced(changeTag: String? = nil, at date: Date = .now) {
        updatedAt = date
        lastSyncedAt = date
        self.changeTag = changeTag
        syncState = .synced
    }
}

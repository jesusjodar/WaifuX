import Foundation
import CryptoKit

/// 文件同步引擎：负责本地文件扫描、hash 计算、objects 读写、manifest 维护
final actor CloudSyncFileEngine {
    static let shared = CloudSyncFileEngine()

    private let fileManager = FileManager.default

    // MARK: - 公共 API

    /// 计算文件的 SHA-256 hash
    func computeFileHash(at url: URL) throws -> String {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            throw CloudSyncError.fileHashFailed(path: url.path)
        }
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1MB buffer
        while autoreleasepool(invoking: {
            let data = fileHandle.readData(ofLength: bufferSize)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Hash only the explicitly authorized originals; never enumerate the user's library.
    func scanLocalFiles(_ files: [String: URL], root: URL) throws -> [String: CloudSyncManifest.CloudSyncManifestEntry] {
        var entries: [String: CloudSyncManifest.CloudSyncManifestEntry] = [:]
        for (relativePath, url) in files {
            guard let destination = WallhavenLibraryFilePolicy.destination(relativePath: relativePath, root: root),
                  destination.path == url.standardizedFileURL.path else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  let size = values?.fileSize, let date = values?.contentModificationDate else { continue }
            entries[relativePath] = .init(hash: try computeFileHash(at: url), size: Int64(size), mtime: date)
        }
        return entries
    }

    /// 同步文件：将本地文件拷贝到 objects 目录（如果 hash 相同则跳过）
    func uploadFile(
        localURL: URL,
        hash: String,
        objectsDir: URL
    ) throws {
        guard WallhavenLibraryFilePolicy.isObjectHash(hash) else { throw CloudSyncError.fileHashFailed(path: hash) }
        guard try computeFileHash(at: localURL) == hash else { throw CloudSyncError.fileHashFailed(path: localURL.path) }
        let objectPath = CloudSyncDirectoryLayout.objectSubpath(hash: hash)
        let objectURL = objectsDir.appendingPathComponent(objectPath)

        // 如果 object 已存在且 hash 正确，跳过
        if fileManager.fileExists(atPath: objectURL.path) {
            let existingHash = try? computeFileHash(at: objectURL)
            if existingHash == hash { return }
        }

        // 确保子目录存在
        try fileManager.createDirectory(
            at: objectURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 拷贝文件
        do {
            try fileManager.copyItem(at: localURL, to: objectURL)
        } catch {
            throw CloudSyncError.fileCopyFailed(source: localURL.path, destination: objectURL.path)
        }
    }

    /// 从 objects 恢复文件到本地
    func downloadFile(
        hash: String,
        objectsDir: URL,
        destinationURL: URL
    ) throws {
        guard WallhavenLibraryFilePolicy.isObjectHash(hash) else { throw CloudSyncError.fileHashFailed(path: hash) }
        let objectPath = CloudSyncDirectoryLayout.objectSubpath(hash: hash)
        let currentURL = objectsDir.appendingPathComponent(objectPath)
        // Older builds accidentally wrote objects/objects/<prefix>/<hash>.
        // Read that layout when the new canonical location is absent.
        let legacyURL = objectsDir.appendingPathComponent("objects").appendingPathComponent(objectPath)
        let objectURL = fileManager.fileExists(atPath: currentURL.path) ? currentURL : legacyURL
        guard fileManager.fileExists(atPath: objectURL.path) else {
            throw CloudSyncError.fileReadFailed(path: objectURL.path)
        }

        // 验证 hash
        let actualHash = try computeFileHash(at: objectURL)
        guard actualHash == hash else {
            throw CloudSyncError.fileHashFailed(path: objectURL.path)
        }

        // 确保目标目录存在
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: destinationURL.path),
           try computeFileHash(at: destinationURL) == hash { return }
        let temporary = destinationURL.deletingLastPathComponent().appendingPathComponent(".wallhaven-sync-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: objectURL, to: temporary)
        guard try computeFileHash(at: temporary) == hash else { throw CloudSyncError.fileHashFailed(path: temporary.path) }
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destinationURL)
        }
    }

    /// 读取云端 manifest
    func readManifest(from url: URL) throws -> CloudSyncManifest {
        let selected = fileManager.fileExists(atPath: url.path) ? url
            : url.deletingLastPathComponent().appendingPathComponent(CloudSyncDirectoryLayout.legacyManifestFileName)
        guard fileManager.fileExists(atPath: selected.path) else {
            return CloudSyncManifest(files: [:], updatedAt: Date())
        }
        let data = try Data(contentsOf: selected)
        do {
            let manifest = try JSONDecoder().decode(CloudSyncManifest.self, from: data)
            return manifest
        } catch {
            throw CloudSyncError.manifestCorrupted
        }
    }

    /// 写入云端 manifest
    func writeManifest(_ manifest: CloudSyncManifest, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)

        try data.write(to: url, options: .atomic)
    }

    // The content-addressed object directory is shared with older builds.
    // Never garbage-collect it: legacy snapshots may reference any of its objects.

    /// 确保同步目录结构存在
    func ensureSyncDirectory(at versionRootURL: URL) throws {
        let objectsDir = versionRootURL.appendingPathComponent(CloudSyncDirectoryLayout.objectsDirName)

        try fileManager.createDirectory(
            at: objectsDir,
            withIntermediateDirectories: true
        )
    }
}

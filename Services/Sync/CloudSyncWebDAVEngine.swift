import Foundation
import CryptoKit

/// WebDAV 远程同步引擎：与 CloudSyncFileEngine 接口对标，操作远程 WebDAV 服务器
final actor CloudSyncWebDAVEngine {
    static let shared = CloudSyncWebDAVEngine()

    private let client = CloudSyncWebDAVClient.shared
    private let localFileManager = FileManager.default

    private init() {}

    // MARK: - Hash

    /// 计算远程文件的 SHA-256（下载到临时文件后计算）
    func computeRemoteFileHash(
        url: URL,
        credentials: WebDAVCredentials
    ) async throws -> String {
        let data = try await client.get(url: url, credentials: credentials)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 计算本地文件的 SHA-256（与 FileEngine 相同）
    func computeLocalFileHash(at url: URL) throws -> String {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            throw CloudSyncError.fileHashFailed(path: url.path)
        }
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024
        while autoreleasepool(invoking: {
            let data = fileHandle.readData(ofLength: bufferSize)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 上传/下载

    /// 上传本地文件到 WebDAV objects 目录
    func uploadFile(
        localURL: URL,
        hash: String,
        objectsBaseURL: URL,
        credentials: WebDAVCredentials
    ) async throws {
        guard WallhavenLibraryFilePolicy.isObjectHash(hash) else { throw CloudSyncError.fileHashFailed(path: hash) }
        let objectPath = CloudSyncDirectoryLayout.objectSubpath(hash: hash)
        let objectURL = objectsBaseURL.appendingPathComponent(objectPath)

        // 检查远程是否已存在相同 hash 的文件
        do {
            let remoteHash = try await computeRemoteFileHash(url: objectURL, credentials: credentials)
            if remoteHash == hash { return }
        } catch let error as CloudSyncError {
            if case .webDAVNotFound = error { /* 继续上传 */ }
            else { throw error }
        }

        // 确保子目录存在
        let dirURL = objectURL.deletingLastPathComponent()
        try await client.mkcol(url: dirURL, credentials: credentials)

        // 读取本地文件并上传
        guard localFileManager.fileExists(atPath: localURL.path) else {
            throw CloudSyncError.fileReadFailed(path: localURL.path)
        }
        let fileData = try Data(contentsOf: localURL)
        let digest = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
        guard digest == hash else { throw CloudSyncError.fileHashFailed(path: localURL.path) }

        try await client.put(
            url: objectURL,
            data: fileData,
            credentials: credentials
        )
    }

    /// 从 WebDAV objects 下载文件到本地
    func downloadFile(
        hash: String,
        objectsBaseURL: URL,
        destinationURL: URL,
        credentials: WebDAVCredentials
    ) async throws {
        guard WallhavenLibraryFilePolicy.isObjectHash(hash) else { throw CloudSyncError.fileHashFailed(path: hash) }
        let objectPath = CloudSyncDirectoryLayout.objectSubpath(hash: hash)
        let objectURL = objectsBaseURL.appendingPathComponent(objectPath)

        // 下载远程文件
        let data: Data
        do {
            data = try await client.get(url: objectURL, credentials: credentials)
        } catch CloudSyncError.webDAVNotFound {
            let legacyURL = objectsBaseURL.appendingPathComponent("objects").appendingPathComponent(objectPath)
            data = try await client.get(url: legacyURL, credentials: credentials)
        }

        // 验证 hash
        let digest = SHA256.hash(data: data)
        let actualHash = digest.map { String(format: "%02x", $0) }.joined()
        guard actualHash == hash else {
            throw CloudSyncError.fileHashFailed(path: objectURL.path)
        }

        // 如果本地已存在且 hash 相同，跳过
        if localFileManager.fileExists(atPath: destinationURL.path) {
            let existingHash = try? computeLocalFileHash(at: destinationURL)
            if existingHash == hash { return }
        }

        // 确保目标目录存在
        try localFileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try data.write(to: destinationURL, options: .atomic)
    }

    // MARK: - Manifest

    /// 读取远程 manifest
    func readManifest(
        baseURL: URL,
        credentials: WebDAVCredentials
    ) async throws -> CloudSyncManifest {
        for name in [CloudSyncDirectoryLayout.manifestFileName, CloudSyncDirectoryLayout.legacyManifestFileName] {
            do {
                let data = try await client.get(url: baseURL.appendingPathComponent(name), credentials: credentials)
                return try JSONDecoder().decode(CloudSyncManifest.self, from: data)
            } catch let error as CloudSyncError {
                guard case .webDAVNotFound = error else { throw error }
            }
        }
        return CloudSyncManifest(files: [:], updatedAt: Date())
    }

    /// 写入远程 manifest
    func writeManifest(
        _ manifest: CloudSyncManifest,
        baseURL: URL,
        credentials: WebDAVCredentials
    ) async throws {
        let manifestURL = baseURL.appendingPathComponent(CloudSyncDirectoryLayout.manifestFileName)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)

        try await client.put(
            url: manifestURL,
            data: data,
            contentType: "application/json",
            credentials: credentials
        )
    }

    // Shared legacy cloud objects are deliberately never garbage-collected.

    // MARK: - 确保目录结构

    /// 创建远程同步目录结构
    func ensureSyncDirectory(
        baseURL: URL,
        credentials: WebDAVCredentials
    ) async throws {
        // 递归创建 WaifuXSync/v1/objects
        let rootDir = baseURL.appendingPathComponent(CloudSyncDirectoryLayout.rootName)
        let versionDir = rootDir.appendingPathComponent(CloudSyncDirectoryLayout.versionDir)
        let objectsDir = versionDir.appendingPathComponent(CloudSyncDirectoryLayout.objectsDirName)

        try await client.mkcol(url: rootDir, credentials: credentials)
        try await client.mkcol(url: versionDir, credentials: credentials)
        try await client.mkcol(url: objectsDir, credentials: credentials)
    }

}

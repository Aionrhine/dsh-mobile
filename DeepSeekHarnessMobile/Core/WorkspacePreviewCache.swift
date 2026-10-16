import Foundation
import CryptoKit
import DeepSeekHarnessShared

struct WorkspacePreviewCacheEntry: Sendable {
    let sessionID: String
    let path: String
    let name: String
    let size: Int64
    let modifiedAt: Double
    let sha256: String?

    init(sessionID: String, path: String, name: String, size: Int64, modifiedAt: Double, sha256: String?) {
        self.sessionID = sessionID
        self.path = path
        self.name = name
        self.size = size
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
    }

    init(_ lookup: SharedWorkspaceFileCacheLookup) {
        sessionID = lookup.sessionId; path = lookup.path; name = lookup.name
        size = lookup.size; modifiedAt = lookup.modifiedAt; sha256 = nil
    }

    init?(_ completion: SharedWorkspaceFileCompletion) {
        guard completion.purpose == "preview", let version = completion.modifiedAt?.doubleValue else { return nil }
        sessionID = completion.sessionId; path = completion.path; name = completion.name
        size = completion.size; modifiedAt = version; sha256 = completion.sha256
    }
}

/// 可由系统回收的持久缓存，按网关、会话、规范路径和远端版本隔离。
struct WorkspacePreviewCache: Sendable {
    let root: URL
    let gatewayID: String

    init(gatewayID: String, root: URL? = nil) {
        self.gatewayID = gatewayID
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkspacePreviews", isDirectory: true)
    }

    func find(_ version: WorkspacePreviewCacheEntry) -> URL? {
        let directory = directory(sessionID: version.sessionID, path: version.path,
                                  size: version.size, modifiedAt: version.modifiedAt)
        let file = directory.appendingPathComponent(safeName(version.name))
        do {
            let expected = try String(contentsOf: directory.appendingPathComponent("sha256"), encoding: .utf8)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == version.size,
                  try digest(file) == expected else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
            return file
        } catch { return nil }
    }

    func store(_ source: URL, entry: WorkspacePreviewCacheEntry) -> URL? {
        guard let sha256 = entry.sha256 else { return nil }
        let directory = directory(sessionID: entry.sessionID, path: entry.path,
                                  size: entry.size, modifiedAt: entry.modifiedAt)
        let staging = root.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let file = staging.appendingPathComponent(safeName(entry.name))
            try FileManager.default.copyItem(at: source, to: file)
            try sha256.write(to: staging.appendingPathComponent("sha256"), atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.moveItem(at: staging, to: directory)
            prune(keeping: directory)
            return directory.appendingPathComponent(file.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return nil // 磁盘缓存失败时，继续预览本次已校验的临时文件。
        }
    }

    private func directory(sessionID: String, path: String, size: Int64, modifiedAt: Double) -> URL {
        let identity = [gatewayID, sessionID, path, String(size), String(modifiedAt)]
            .map { "\($0.utf8.count):\($0)" }.joined()
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key, isDirectory: true)
    }

    private func safeName(_ name: String) -> String {
        let value = URL(fileURLWithPath: name).lastPathComponent
        return ["", ".", "..", "sha256"].contains(value) ? "file" : value
    }

    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func prune(keeping current: URL) {
        let manager = FileManager.default
        let directories = (try? manager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let sorted = directories.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var bytes: Int64 = 0
        for directory in sorted {
            let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            bytes += files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            if directory != current, bytes > 512 * 1024 * 1024 { try? manager.removeItem(at: directory) }
        }
    }
}

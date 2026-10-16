import XCTest
@testable import DeepSeekHarnessMobile

final class WorkspacePreviewCacheTests: XCTestCase {
    private let fileDigest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    func testPersistsAcrossInstancesAndSeparatesVersionsGatewaysSessionsAndPaths() throws {
        try withDirectory { directory in
            let root = directory.appendingPathComponent("cache")
            let source = directory.appendingPathComponent("source.txt")
            try Data("hello".utf8).write(to: source)
            let entry = entry()
            XCTAssertNotNil(WorkspacePreviewCache(gatewayID: "g1", root: root).store(source, entry: entry))
            let cache = WorkspacePreviewCache(gatewayID: "g1", root: root)
            let file = try XCTUnwrap(cache.find(entry))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
            XCTAssertNil(WorkspacePreviewCache(gatewayID: "g2", root: root).find(entry))
            XCTAssertNil(cache.find(self.entry(sessionID: "s2")))
            XCTAssertNil(cache.find(self.entry(path: "other/a.txt")))
            XCTAssertNil(cache.find(self.entry(size: 6)))
            XCTAssertNil(cache.find(self.entry(modifiedAt: 11)))
        }
    }

    func testCorruptOrDeletedCacheIsNeverReturned() throws {
        try withDirectory { directory in
            let source = directory.appendingPathComponent("source.txt")
            try Data("hello".utf8).write(to: source)
            let cache = WorkspacePreviewCache(gatewayID: "g1", root: directory.appendingPathComponent("cache"))
            let entry = entry()
            let file = try XCTUnwrap(cache.store(source, entry: entry))
            try Data("other".utf8).write(to: file)
            XCTAssertNil(cache.find(entry))
            let replacement = try XCTUnwrap(cache.store(source, entry: entry))
            try FileManager.default.removeItem(at: replacement)
            XCTAssertNil(cache.find(entry))
        }
    }

    func testCacheWriteFailurePreservesDownloadedFile() throws {
        try withDirectory { directory in
            let source = directory.appendingPathComponent("source.txt")
            let root = directory.appendingPathComponent("not-a-directory")
            try Data("hello".utf8).write(to: source)
            try Data().write(to: root)
            let cache = WorkspacePreviewCache(gatewayID: "g1", root: root)
            XCTAssertNil(cache.store(source, entry: entry()))
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "hello")
        }
    }

    private func entry(sessionID: String = "s1", path: String = "build/a.txt",
                       size: Int64 = 5, modifiedAt: Double = 10.5) -> WorkspacePreviewCacheEntry {
        WorkspacePreviewCacheEntry(sessionID: sessionID, path: path, name: "a.txt",
                                   size: size, modifiedAt: modifiedAt, sha256: fileDigest)
    }

    private func withDirectory(_ block: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try block(directory)
    }
}

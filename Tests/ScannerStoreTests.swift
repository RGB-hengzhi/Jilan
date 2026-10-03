import Foundation
import Darwin

/// Pause at the final progress notification, before the new root is committed.
/// The partial first index must survive shutdown; a reload must not silently
/// replace it with an empty snapshot just because calibration was cancelled.
enum ScannerStoreTests {
    static func run() throws -> [String: Any] {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("QuickFindScannerStore-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("文件"), data = fixture.appendingPathComponent("缓存")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        for number in 0..<40 {
            try Data("owned partial-index fixture".utf8).write(to: root.appendingPathComponent("暂停缓存文件\(number).txt"))
        }
        guard let physical = realpath(root.path, nil) else { throw EngineTestError.failed("暂停缓存fixture物理路径读取失败") }
        let physicalRoot = String(cString: physical); free(physical)
        let expected = Set((0..<40).map { physicalRoot + "/暂停缓存文件\($0).txt" })
        let record = IndexStore.makeRoot(path: root.path)
        guard record.path == physicalRoot else { throw EngineTestError.failed("索引根须与独立POSIX物理路径一致") }
        let store = IndexStore(dataDirectory: data, initialRoots: [record], watchesFilesystem: false)
        var shutDown = false
        defer { store.onUpdate = nil; if !shutDown { store.shutdown() } }
        let paused = CancellationFlag()
        store.onUpdate = { snapshot in
            if snapshot.isScanning && snapshot.scannedCount >= 5 && !paused.isCancelled {
                paused.cancel(); store.cancelScan()
            }
        }
        store.start()
        try wait("首次扫描暂停") { paused.isCancelled && !store.snapshot().isScanning }
        let beforeExit = Set(store.search(SearchRequest(query: "暂停缓存文件"), limit: 100).hits.map(\.path))
        guard !beforeExit.isEmpty, beforeExit.isSubset(of: expected), store.snapshot().roots.first?.lastUpdated == nil else {
            throw EngineTestError.failed("首次暂停必须有有效部分索引且不得宣称完成校准：hits=\(beforeExit.count), subset=\(beforeExit.isSubset(of: expected)), rootCount=\(store.snapshot().roots.first?.count ?? -1), lastUpdated=\(store.snapshot().roots.first?.lastUpdated != nil), state=\(store.snapshot().roots.first?.state ?? "")")
        }
        store.onUpdate = nil; store.shutdown(); shutDown = true
        let saved = try EngineIndex.load(from: data.appendingPathComponent(record.id + ".qfi"))
        let savedPaths = Set(saved.query(SearchRequest(query: "暂停缓存文件"), rootID: record.id, limit: 100).hits.map(\.path))
        guard savedPaths == beforeExit else { throw EngineTestError.failed("退出未保存首次暂停的索引") }

        let reload = IndexStore(dataDirectory: data, initialRoots: [record], watchesFilesystem: false)
        let cacheObserved = CancellationFlag()
        reload.onUpdate = { snapshot in
            if snapshot.roots.first?.count == saved.count && !snapshot.isScanning {
                cacheObserved.cancel(); reload.cancelScan()
            }
        }
        defer { reload.onUpdate = nil; reload.shutdown() }
        reload.start()
        try wait("重新读取暂停缓存") { cacheObserved.isCancelled }
        let loadedPaths = Set(reload.search(SearchRequest(query: "暂停缓存文件"), limit: 100).hits.map(\.path))
        guard loadedPaths == beforeExit, reload.snapshot().roots.first?.lastUpdated == nil else {
            throw EngineTestError.failed("重新启动必须保留已保存部分索引并保留校准未完成状态")
        }
        return ["status": "passed", "firstScanPauseRetainsNames": true,
                "shutdownPersistsPartialIndex": true, "reloadKeepsExactPaths": true,
                "partialDoesNotClaimCompletedCalibration": true, "retainedFileCount": beforeExit.count]
    }

    private static func wait(_ label: String, _ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        throw EngineTestError.failed("扫描缓存回归超时：" + label)
    }
}

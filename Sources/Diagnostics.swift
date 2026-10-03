import Foundation
import AppKit

enum Diagnostic {
    static func run(arguments: [String]) -> Int32 {
        do {
            var report: [String: Any] = ["application": Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "疾览 · Jilan", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.2.1", "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "testedAt": ISO8601DateFormatter().string(from: Date()),
                "architecture": "arm64", "os": ProcessInfo.processInfo.operatingSystemVersionString]
            if arguments.contains("--self-test") || arguments.contains("--benchmark") {
                report["engine"] = try EngineTests.run()
            }
            if arguments.contains("--self-test") {
                report["pathCoverage"] = try PathCoverageTests.run()
                report["advancedSearch"] = try AdvancedSearchTests.run()
                report["filterUpgrade"] = try FilterUpgradeTests.run()
                report["operationIndexRefresh"] = try OperationIndexRefreshTests.run()
                report["scannerSafety"] = try ScannerSafetyTests.run()
                report["scanWorker"] = try ScanWorkerTests.run()
                report["scannerStore"] = try ScannerStoreTests.run()
                report["fileManagement"] = try WorkspaceFilesystemTests.run()
                report["searchPreferences"] = try SearchPreferencesTests.run()
                report["workspaceSession"] = try WorkspaceSessionTests.run()
                report["idleSearch"] = try MainActor.assumeIsolated { try IdleSearchTests.run() }
                try FilesystemTests.run()
                report["filesystem"] = "passed: real APFS and configured external volume"
                report["integration"] = try integrationTest()
            }
            if arguments.contains("--scan-diagnostic") {
                guard let position = arguments.firstIndex(of: "--path"), arguments.count > position + 1 else {
                    throw EngineTestError.failed("扫描诊断需要 --path 指定真实目录")
                }
                let path = arguments[position + 1]
                let index = EngineIndex()
                let scan = FileScanner.scan(path: path, excludedPrefixes: [], cancelled: { false },
                    onEntry: { index.add(path: $0, isDirectory: $1) }, onProgress: { _, _ in })
                let term = arguments.firstIndex(of: "--query").flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil } ?? ""
                let start = DispatchTime.now().uptimeNanoseconds
                let query = index.query(SearchRequest(query: term), rootID: "diagnostic", limit: 20)
                report["realDirectoryScan"] = ["path": path, "indexedCount": index.count,
                    "scanMilliseconds": scan.elapsedMilliseconds, "completed": scan.completed,
                    "permissionOrScanIssues": scan.totalIssueCount, "query": term,
                    "matches": query.totalMatches,
                    "queryMilliseconds": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
                    "examples": query.hits.map(\.path),
                    "issues": scan.issues.prefix(20).map { ["path": $0.path, "message": $0.message] }]
            }
            if arguments.contains("--cache-diagnostic") {
                let directory = arguments.firstIndex(of: "--index-data").flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuickFind").path
                let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "qfi" }
                var entries = 0
                var measurements: [[String: Any]] = []
                let engines = try urls.map { try EngineIndex.load(from: $0) }
                entries = engines.reduce(0) { $0 + $1.count }
                for query in ["应用", "合同 *.pdf !草稿", "*.docx | *.pdf", "QuickFindV2验收"] {
                    let start = DispatchTime.now().uptimeNanoseconds
                    var count = 0
                    for (index, engine) in engines.enumerated() {
                        count += engine.query(SearchRequest(query: query), rootID: String(index), limit: 20).totalMatches
                    }
                    measurements.append(["query": query, "matches": count,
                        "milliseconds": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000])
                }
                report["existingIndexQueries"] = ["indexCount": engines.count, "entries": entries,
                    "measurements": measurements, "mode": "read-only cache; does not prove current filesystem coverage"]
            }
            report["result"] = "passed"
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            if let position = arguments.firstIndex(of: "--output"), arguments.count > position + 1 {
                try data.write(to: URL(fileURLWithPath: arguments[position + 1]), options: .atomic)
            }
            print(String(decoding: data, as: UTF8.self))
            return 0
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            return 1
        }
    }

    private static func integrationTest() throws -> [String: Any] {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("QuickFindIntegration-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("真实文件")
        let data = fixture.appendingPathComponent("索引数据")
        let nested = root.appendingPathComponent("项目文件夹")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("这是测试文件".utf8).write(to: root.appendingPathComponent("季度报告.pdf"))
        try Data().write(to: root.appendingPathComponent(".隐藏资料.txt"))
        try Data().write(to: nested.appendingPathComponent("目录移动验证.txt"))
        let record = IndexStore.makeRoot(path: root.path)
        // Exercise duplicate records from an existing config, without using
        // default whole-disk discovery or scanning any location outside fixtures.
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try JSONEncoder().encode([record, record]).write(to: data.appendingPathComponent("roots.json"))
        let store = IndexStore(dataDirectory: data)
        store.start()
        var shutdown = false
        defer { if !shutdown { store.shutdown() } }

        func wait(_ label: String, _ predicate: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if predicate() { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            let state = store.snapshot()
            throw EngineTestError.failed("集成测试超时：\(label)，状态：\(state.message)，索引位置数量：\(state.roots.count)")
        }
        func search(_ text: String) -> SearchBatch { store.search(SearchRequest(query: text), limit: 100) }
        try wait("首次实际扫描及配置重复根去重") {
            let roots = store.snapshot().roots
            return roots.count == 1 && roots.first?.state == "就绪" && search("季度报告").totalMatches == 1
        }
        guard search("隐藏资料").totalMatches == 1 else { throw EngineTestError.failed("实际隐藏文件漏检") }
        let childRecord = IndexStore.makeRoot(path: nested.path)
        let alias = fixture.appendingPathComponent("子目录别名")
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: nested.path)
        let aliasRecord = IndexStore.makeRoot(path: alias.path)
        guard aliasRecord.id == childRecord.id else { throw EngineTestError.failed("符号链接根规范化不一致") }
        store.addRoots([childRecord, aliasRecord, childRecord, record])
        try wait("同批重复及重叠根去重") {
            let roots = store.snapshot().roots
            return roots.count == 2 && Set(roots.map(\.id)).count == 2 && roots.allSatisfy { $0.state == "就绪" }
        }
        guard search("目录移动验证").totalMatches == 1 else {
            throw EngineTestError.failed("重复根或父子根搜索发生重复/漏检")
        }
        store.removeRoot(id: childRecord.id)
        try wait("移除测试子根") { store.snapshot().roots.count == 1 }
        let created = root.appendingPathComponent("新建测试.txt")
        try Data().write(to: created)
        try wait("新建文件实时更新") { search("新建测试").totalMatches == 1 }
        let renamed = root.appendingPathComponent("改名测试.txt")
        try fm.moveItem(at: created, to: renamed)
        try wait("改名与旧路径清除") { search("改名测试").totalMatches == 1 && search("新建测试").totalMatches == 0 }
        let newFolder = root.appendingPathComponent("改名后的项目")
        try fm.moveItem(at: nested, to: newFolder)
        let canonicalNewFolder = IndexStore.makeRoot(path: newFolder.path).path
        try wait("目录改名后更新全部子路径") {
            let hits = search("目录移动验证").hits
            return hits.count == 1 && hits[0].parentPath == canonicalNewFolder
        }
        try fm.removeItem(at: renamed)
        try wait("删除测试文件后清除索引") { search("改名测试").totalMatches == 0 }
        store.shutdown(); shutdown = true
        let persisted = try EngineIndex.load(from: data.appendingPathComponent(record.id + ".qfi"))
        guard persisted.query(SearchRequest(query: "改名测试"), rootID: record.id, limit: 10).totalMatches == 0,
              persisted.query(SearchRequest(query: "目录移动验证"), rootID: record.id, limit: 10).hits.first?.parentPath == canonicalNewFolder else {
            throw EngineTestError.failed("退出持久化未保存最新状态")
        }
        // Simulate a removable location going offline without unmounting any user disk.
        let offline = fixture.appendingPathComponent("暂时断开")
        try fm.moveItem(at: root, to: offline)
        let second = IndexStore(dataDirectory: data, initialRoots: [record, record])
        second.start()
        defer { second.shutdown() }
        let deadline = Date().addingTimeInterval(5)
        while second.snapshot().roots.isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard second.snapshot().roots.count == 1 else { throw EngineTestError.failed("initialRoots 重复根未去重") }
        let offlineResult = second.search(SearchRequest(query: "季度报告"))
        guard offlineResult.totalMatches == 1, offlineResult.hits.first?.isOnline == false else {
            throw EngineTestError.failed("离线缓存搜索或离线状态错误")
        }
        return ["status": "passed", "createdRenamedMovedDeleted": true,
            "duplicateRootConfiguration": true, "duplicateRootBatch": true,
            "overlapSearchDeduplicates": true,
            "shutdownPersistsChanges": true, "offlineCache": true,
            "physicalUnplugTest": "not performed; offline state simulated with owned fixture"]
    }
}

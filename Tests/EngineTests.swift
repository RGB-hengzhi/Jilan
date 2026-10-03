// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

enum EngineTestError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let text) = self { return text }; return "索引测试失败" }
}

enum EngineTests {
    /// Runs real behavioral checks and a 1,000,000-entry synthetic benchmark.
    /// Synthetic entries never create files or trigger disk enumeration.
    static func run() throws -> [String: Any] {
        func check(_ predicate: @autoclosure () throws -> Bool, _ message: String) throws {
            if try predicate() == false { throw EngineTestError.failed(message) }
        }
        let index = EngineIndex()
        let fixtures: [(String, Bool)] = [
            ("/测试/报告/季度报告.PDF", false),
            ("/测试/报告/季度预算.docx", false),
            ("/测试/报告/季度 报告 最终.docx", false),
            ("/测试/报告/abc___def.txt", false),
            ("/测试/报告/abcdef.txt", false),
            ("/测试/报告/报告文件夹.pdf", true),
            ("/测试/报告/\u{00E9}cole.txt", false),
            ("/测试/报告/e\u{0301}cole2.TXT", false),
            ("/测试/报告/长后缀.abcdefgh1", false),
            ("/测试/报告/长后缀.abcdefgh2", false),
            ("/测试/报告-old/保留.pdf", false),
            ("/测试/其他/unique_file.txt", false)
        ]
        for fixture in fixtures { index.add(path: fixture.0, isDirectory: fixture.1) }
        index.add(path: fixtures[0].0, isDirectory: false)
        try check(index.count == fixtures.count, "重复路径应去重")
        func query(_ text: String, kind: SearchKind = .all, ext: String = "", path: Bool = false,
                   limit: Int = 100) -> EngineQueryResult {
            index.query(SearchRequest(query: text, kind: kind, extensionFilter: ext, matchPath: path), rootID: "test", limit: limit)
        }
        try check(query("季度").totalMatches == 3, "中文连续片段搜索")
        try check(query("季度    报告").totalMatches == 2, "多词应同时满足且忽略重复空白")
        try check(query("abc def", ext: "txt").totalMatches == 2, "多词可分别出现在名称不同位置")
        try check(query("abcde", ext: "txt").totalMatches == 1, "默认应为连续片段，不能模糊匹配跨越分隔符")
        try check(query("报告").totalMatches == 3, "默认名称搜索不能把目录名称当作子文件匹配")
        try check(query("报告", path: true).totalMatches == 11, "路径开关应包含目录名称")
        try check(query("ÉCOLE").totalMatches == 2, "大小写及组合/分解 Unicode 文件名应等价匹配")
        try check(query("e\u{0301}cole").totalMatches == 2, "NFD 查询应匹配 NFC 和 NFD 名称")
        try check(query("", kind: .folders).totalMatches == 1, "文件夹过滤")
        try check(query("报告", kind: .files, limit: 1).totalMatches == 2, "截断前类型过滤且应有准确总数")
        try check(query("报告", kind: .files, limit: 1).hits.count == 1, "limit 仅控制返回首屏")
        try check(query("", ext: ".PDF | .DOCX").totalMatches == 4, "扩展名组合及大小写过滤；目录不计文件后缀")
        try check(query("", ext: "pdf, docx").totalMatches == 4, "逗号及空格扩展名过滤")
        try check(query("", ext: "*.pdf").totalMatches == 2, "通配扩展名简写")
        try check(query("", ext: "abcdefgh1").totalMatches == 1, "长扩展名不能使用截短哈希发生碰撞")
        try check(query("", ext: "missingext").totalMatches == 0, "不存在的扩展名")
        try check(query("", limit: 0).hits.isEmpty && query("", limit: 0).totalMatches == fixtures.count, "零条显示仍计总数")
        let otherRoot = index.query(SearchRequest(query: "", rootID: "other"), rootID: "test", limit: 100)
        try check(otherRoot.totalMatches == 0, "索引应尊重根目录筛选")

        let ancestor = EngineIndex(), descendant = EngineIndex()
        for number in 0..<1000 { ancestor.add(path: "/共享/子/entry_\(number).txt", isDirectory: false) }
        for number in 0..<500 { descendant.add(path: "/共享/子/entry_\(number).txt", isDirectory: false) }
        let deduplicated = ancestor.query(SearchRequest(query: "entry"), rootID: "ancestor", limit: 100,
                                          excludeHit: { descendant.hasPath($0) })
        try check(deduplicated.totalMatches == 500 && deduplicated.hits.count == 100,
                  "跨根去重必须先于计数及首屏截断；父根补充子根尚未收录条目")
        try check(deduplicated.hits.allSatisfy { !descendant.hasPath($0.path) }, "首屏不能含跨根重复路径")
        var streamed = 0
        var streamIsValid = true
        descendant.forEachPath { path, isDir in
            streamed += 1
            if !ancestor.hasPath(path) || isDir { streamIsValid = false }
        }
        try check(streamed == 500 && streamIsValid, "流式枚举不能漏掉或损坏 live paths")
        ancestor.add(path: "/共享/子/类型变化.bin", isDirectory: false)
        descendant.add(path: "/共享/子/类型变化.bin", isDirectory: true)
        try check(ancestor.query(SearchRequest(query: "类型变化", kind: .files), rootID: "ancestor", limit: 10,
                                 excludeHit: { descendant.hasPath($0) }).totalMatches == 0,
                  "较深根应权威覆盖同路径类型，父缓存旧文件类型不能漏出")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("QuickFindEngineTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let savedURL = temporary.appendingPathComponent("roundtrip.qfi")
        try index.save(to: savedURL)
        let restored = try EngineIndex.load(from: savedURL)
        try check(restored.count == index.count, "持久化往返数量")
        let restoredResults = restored.query(SearchRequest(query: "ÉCOLE"), rootID: "test", limit: 100)
        try check(restoredResults.totalMatches == 2 && Set(restoredResults.hits.map(\.path)) == Set(query("ÉCOLE").hits.map(\.path)), "持久化应保留实际路径及 Unicode 查询")
        restored.removeSubtree(path: "/测试/报告/")
        try check(restored.count == 2, "删除子树应删除根下条目并保留相似前缀的兄弟目录")
        restored.add(path: "/测试/报告/新建.txt", isDirectory: false)
        try check(restored.count == 3, "删除后的空槽复用")
        restored.add(path: "/测试/报告/新建.txt", isDirectory: true)
        try check(restored.query(SearchRequest(query: "新建", kind: .folders), rootID: "test", limit: 10).totalMatches == 1, "已有路径的文件类型变化")
        try restored.save(to: savedURL)
        try check(try EngineIndex.load(from: savedURL).count == 3, "删除后持久化不应恢复已删除条目")

        // Simulate repeated FSEvents replacements. This crosses the byte-waste
        // compaction threshold without creating files, then checks persistence.
        let churn = EngineIndex()
        let changedPath = "/测试/反复更新/" + String(repeating: "a", count: 128) + ".txt"
        churn.add(path: changedPath, isDirectory: false)
        for _ in 0..<20_000 {
            churn.removeSubtree(path: changedPath)
            churn.add(path: changedPath, isDirectory: false)
        }
        try check(churn.count == 1, "长期重复文件更新不能累积条目")
        try churn.save(to: savedURL)
        try check(try EngineIndex.load(from: savedURL).query(SearchRequest(query: "aaa"), rootID: "test", limit: 10).totalMatches == 1,
                  "反复更新后的索引压缩及持久化")

        let empty = EngineIndex()
        try empty.save(to: savedURL)
        try check(try EngineIndex.load(from: savedURL).count == 0, "空索引往返")
        try index.save(to: savedURL)
        let good = try Data(contentsOf: savedURL)
        let damagedURL = temporary.appendingPathComponent("damaged.qfi")
        var corruptions: [Data] = [Data(), good.prefix(1), good.prefix(good.count - 1)]
        var flipped = good
        flipped[40] ^= 0x80
        corruptions.append(flipped)
        // Even a deliberately recomputed checksum must not allow hostile header
        // integers to trap during conversion or unchecked pointer reads.
        var hostile = good.dropLast(32)
        for i in 8..<16 { hostile[i] = 0xFF }
        hostile.append(contentsOf: SHA256.hash(data: hostile))
        corruptions.append(hostile)
        var badOffset = good.dropLast(32)
        let offsetArrayStart = 32 + fixtures.count * 16
        for i in offsetArrayStart..<(offsetArrayStart + 8) { badOffset[i] = 0xFF }
        badOffset.append(contentsOf: SHA256.hash(data: badOffset))
        corruptions.append(badOffset)
        for (number, data) in corruptions.enumerated() {
            try data.write(to: damagedURL)
            do {
                _ = try EngineIndex.load(from: damagedURL)
                throw EngineTestError.failed("损坏索引 \(number) 被接受")
            } catch is IndexPersistenceError { }
        }

        let concurrent = EngineIndex()
        DispatchQueue.concurrentPerform(iterations: 1_000) { number in
            let path = "/并发/entry_\(number).txt"
            concurrent.add(path: path, isDirectory: false)
            _ = concurrent.query(SearchRequest(query: "entry"), rootID: "test", limit: 10)
            if number % 2 == 0 { concurrent.removeSubtree(path: path) }
        }
        try check(concurrent.count == 500 && concurrent.query(SearchRequest(query: "entry"), rootID: "test", limit: 10).totalMatches == 500,
                  "并发查询及增删应保持条目一致")

        // Simulate a slow protected-subtree merge without relying on its scale:
        // while the callback is suspended, queries and writes must finish, and
        // later callbacks must still observe the original path/type snapshot.
        final class SnapshotProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var visited: [String: Bool] = [:]
            func record(_ path: String, isDir: Bool) { lock.withLock { visited[path] = isDir } }
            var values: [String: Bool] { lock.withLock { visited } }
        }
        let snapshotIndex = EngineIndex()
        let snapshotPaths: [String: Bool] = ["/快照/gate.txt": false, "/快照/removed": true,
                                            "/快照/retained.txt": false]
        // A known first entry lets the test pause before the entries we mutate.
        for path in ["/快照/gate.txt", "/快照/removed", "/快照/retained.txt"] {
            snapshotIndex.add(path: path, isDirectory: snapshotPaths[path]!)
        }
        let probe = SnapshotProbe()
        let callbackEntered = DispatchSemaphore(value: 0), resumeCallback = DispatchSemaphore(value: 0)
        let queryCompleted = DispatchSemaphore(value: 0), mutationCompleted = DispatchSemaphore(value: 0)
        let snapshotGroup = DispatchGroup()
        snapshotGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            snapshotIndex.forEachPath { path, isDir in
                if path == "/快照/gate.txt" {
                    callbackEntered.signal()
                    _ = resumeCallback.wait(timeout: .now() + 5)
                }
                probe.record(path, isDir: isDir)
            }
            snapshotGroup.leave()
        }
        let entered = callbackEntered.wait(timeout: .now() + 2) == .success
        snapshotGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = snapshotIndex.query(SearchRequest(query: ""), rootID: "snapshot", limit: 10)
            queryCompleted.signal()
            snapshotGroup.leave()
        }
        let queryWasUnlocked = queryCompleted.wait(timeout: .now() + 1) == .success
        snapshotGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            snapshotIndex.removeSubtree(path: "/快照/removed")
            snapshotIndex.add(path: "/快照/retained.txt", isDirectory: true)
            snapshotIndex.add(path: "/快照/new.txt", isDirectory: false)
            mutationCompleted.signal()
            snapshotGroup.leave()
        }
        let mutationWasUnlocked = mutationCompleted.wait(timeout: .now() + 1) == .success
        resumeCallback.signal()
        let finished = snapshotGroup.wait(timeout: .now() + 2) == .success
        try check(entered && queryWasUnlocked && mutationWasUnlocked && finished,
                  "慢速枚举回调暂停期间，查询及增删仍须完成，不能持有引擎锁")
        try check(probe.values == snapshotPaths, "并发增删及类型变化不能改变已捕获的枚举快照")
        try check(!snapshotIndex.hasPath("/快照/removed") && snapshotIndex.hasPath("/快照/new.txt") &&
                  snapshotIndex.query(SearchRequest(query: "retained", kind: .folders), rootID: "snapshot", limit: 10).totalMatches == 1,
                  "快照枚举期间的变更必须对后续查询可见")
        var stoppedVisits = 0
        let stoppedEarly = !snapshotIndex.forEachPathWhile { _, _ in
            stoppedVisits += 1
            // Engine re-entry from an unlocked callback must also be safe.
            _ = snapshotIndex.query(SearchRequest(query: "retained"), rootID: "snapshot", limit: 1)
            return false
        }
        try check(stoppedEarly && stoppedVisits == 1, "枚举回调应允许重入查询并在 false 时立即停止")
        var completeVisits = 0
        let enumeratedAll = snapshotIndex.forEachPathWhile { _, _ in completeVisits += 1; return true }
        try check(enumeratedAll && completeVisits == snapshotIndex.count, "完整枚举须返回 true")

        // Keep removed slots below the live engine's compaction threshold,
        // reuse one out of order, and ensure snapshot persistence still writes
        // compact normalized bytes without changing the engine's live paths.
        let sparse = EngineIndex()
        for number in 0..<20 { sparse.add(path: "/稀疏/entry_\(number).txt", isDirectory: number == 7) }
        for number in [1, 4, 9] { sparse.removeSubtree(path: "/稀疏/entry_\(number).txt") }
        sparse.add(path: "/稀疏/新增é.txt", isDirectory: false)
        let sparsePaths = sparse.query(SearchRequest(query: ""), rootID: "sparse", limit: 100).hits
        try sparse.save(to: savedURL)
        let sparseLoaded = try EngineIndex.load(from: savedURL)
        try check(Set(sparseLoaded.query(SearchRequest(query: ""), rootID: "sparse", limit: 100).hits.map(\.path)) == Set(sparsePaths.map(\.path)) &&
                  sparseLoaded.query(SearchRequest(query: "", kind: .folders), rootID: "sparse", limit: 100).totalMatches == 1 &&
                  sparseLoaded.query(SearchRequest(query: "新增É"), rootID: "sparse", limit: 100).totalMatches == 1,
                  "带空槽及乱序复用的索引保存须保持路径、类型、Unicode并正确重算紧凑字节偏移")

        let benchmark = SearchEngine()
        let numberOfEntries = 1_000_000
        benchmark.reserveCapacity(numberOfEntries)
        let indexingStart = Date()
        for i in 0..<numberOfEntries {
            let name = i % 100 == 0 ? "财务报告_\(i).pdf" : "document_\(i).txt"
            benchmark.addPath("/benchmark/group\(i % 1000)/" + name, isDir: i % 5000 == 1)
        }
        let indexingMilliseconds = Date().timeIntervalSince(indexingStart) * 1000
        try check(benchmark.count == numberOfEntries, "百万条合成索引数量")
        var searches: [[String: Any]] = []
        for term in ["财务报告", "document_987654", "document", "zzzz_nonexistent"] {
            let start = Date()
            let results = benchmark.literalQuery(SearchRequest(query: term), rootID: "benchmark", limit: 200)
            let milliseconds = Date().timeIntervalSince(start) * 1000
            let expected = term == "财务报告" ? 10_000 : term == "document_987654" ? 1 : term == "document" ? 990_000 : 0
            try check(results.totalMatches == expected, "百万索引查询 \(term) 应准确计数")
            try check(results.hits.count == min(expected, 200), "百万索引首屏不应影响总匹配数量")
            searches.append(["query": term, "matches": results.totalMatches, "milliseconds": milliseconds])
        }
        let largeIndexURL = temporary.appendingPathComponent("million.qfi")
        let saveStart = Date()
        try benchmark.saveBinaryIndex(to: largeIndexURL)
        let saveMilliseconds = Date().timeIntervalSince(saveStart) * 1000
        let largeFileSize = try FileManager.default.attributesOfItem(atPath: largeIndexURL.path)[.size] as? UInt64 ?? 0
        let loadStart = Date()
        let loadedBenchmark = try SearchEngine.loadBinaryIndex(from: largeIndexURL)
        let loadMilliseconds = Date().timeIntervalSince(loadStart) * 1000
        try check(loadedBenchmark.count == numberOfEntries && loadedBenchmark.literalQuery(SearchRequest(query: "财务报告"), rootID: "benchmark", limit: 200).totalMatches == 10_000,
                  "百万条索引二进制往返应保持数据及查询")
        return ["functionalChecks": "passed", "corruptFilesRejected": corruptions.count,
                "snapshotEnumerationConcurrency": "passed",
                "syntheticEntries": numberOfEntries, "indexBuildMilliseconds": indexingMilliseconds,
                "binaryFileBytes": largeFileSize, "binarySaveMilliseconds": saveMilliseconds,
                "binaryLoadMilliseconds": loadMilliseconds,
                "searches": searches,
                "note": "合成索引基准，不代表全盘首次扫描或真实用户验收。"]
    }
}

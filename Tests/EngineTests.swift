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


        // Index acceptance replaces ScanWorker's second full-path dictionary.
        let acceptance = EngineIndex()
        try check(acceptance.add(path: "/接收/é.txt", isDirectory: false), "新路径应报告新增")
        try check(!acceptance.add(path: "/接收/e\u{0301}.txt", isDirectory: false) && acceptance.count == 1,
                  "Unicode等价路径的重复接收不能增加数量")
        try check(acceptance.add(path: "/接收/e\u{0301}.txt", isDirectory: true) && acceptance.count == 1 &&
                  acceptance.pathIsDirectory("/接收/é.txt") == true && acceptance.pathIsDirectory("/接收/missing") == nil,
                  "类型变化应报告改变但不能增加数量")

        // Deliberately force all original paths into one hash bucket. Matching,
        // deletion of head/middle/tail, slot reuse, compaction and snapshots must
        // verify original paths rather than trust the hash value.
        let colliding = SearchEngine(pathHashBits: 0)
        for number in 0..<24 { colliding.addPath("/碰撞/组\(number % 3)/文件\(number).txt", isDir: number == 7) }
        colliding.addPath("/碰撞/é.txt", isDir: false)
        colliding.addPath("/碰撞/e\u{0301}.txt", isDir: false)
        try check(colliding.count == 25 && colliding.hasPath("/碰撞/e\u{0301}.txt") && !colliding.hasPath("/碰撞/missing.txt"),
                  "强制哈希碰撞仍需按Unicode等价原路径验证")
        let collisionCursor = colliding.makeQueryCursor(SearchRequest(query: ""), rootID: "collision")
        for number in [0, 12, 23] { colliding.removeSubtree("/碰撞/组\(number % 3)/文件\(number).txt") }
        colliding.removeSubtree("/碰撞/组1")
        colliding.addPath("/碰撞/复用.txt", isDir: false)
        try check(colliding.count == 15 && colliding.hasPath("/碰撞/复用.txt") && !colliding.hasPath("/碰撞/组0/文件0.txt") &&
                  colliding.literalQuery(SearchRequest(query: ""), rootID: "collision", limit: 0).totalMatches == 15,
                  "碰撞链删除、空槽复用及压缩不能丢失其他路径")
        try check(collisionCursor.hasPath("/碰撞/组0/文件0.txt") && !collisionCursor.hasPath("/碰撞/复用.txt") &&
                  collisionCursor.countCandidates() == 25, "碰撞成员查询必须使用游标的原始快照")

        let boundary = EngineIndex()
        for item in ["/父目录/e\u{0301}cole/报告é.txt", "/父目录/e\u{0301}cole/other.txt", "/兄弟/école报告é.txt", "/"] {
            boundary.add(path: item, isDirectory: item == "/")
        }
        try check(boundary.query(SearchRequest(query: "cole/报告É", matchPath: true), rootID: "boundary", limit: 10).totalMatches == 1,
                  "路径字节搜索必须跨共享parent和basename边界且保持Unicode等价")
        try check(boundary.query(SearchRequest(query: "cole/报告É"), rootID: "boundary", limit: 10).totalMatches == 0,
                  "名称搜索不能意外包含共享父目录")
        try check(boundary.query(SearchRequest(query: "*cole/报告?.txt", matchPath: true), rootID: "boundary", limit: 10).totalMatches == 1 &&
                  boundary.query(SearchRequest(query: "/", kind: .folders), rootID: "boundary", limit: 10).totalMatches == 1,
                  "跨parent字符通配和根目录名称语义必须保持")

        let graphemes = EngineIndex()
        let graphemeNames = ["q\u{0301}资料.txt", "🇨🇳.txt", "👩‍💻.txt", "\u{0600}.pdf", "中文.pdf", "plain.pdf"]
        for name in graphemeNames { graphemes.add(path: "/字素/" + name, isDirectory: false) }
        for pattern in ["q*", "*q*", "🇨*", "*🇨*", "👩*", "*💻*", "*.pdf", "?资料.txt", "*资料*", "*"] {
            let expected = Set(graphemeNames.filter { AdvancedSearchPlan.wildcardMatches(AdvancedSearchPlan.normalize(pattern), text: AdvancedSearchPlan.normalize($0)) })
            let actual = graphemes.query(SearchRequest(query: pattern), rootID: "grapheme", limit: 100)
            try check(Set(actual.hits.map(\.name)) == expected && actual.totalMatches == expected.count,
                      "通配字节快路必须遵守combining/regional/ZWJ/Prepend字素边界：" + pattern)
        }
        try check(graphemes.query(SearchRequest(query: "q"), rootID: "grapheme", limit: 100).totalMatches == 1,
                  "非通配连续片段保留原字节检索语义")

        let chunked = EngineIndex()
        for number in 0..<4_137 { chunked.add(path: "/分块/父/报告_\(number).pdf", isDirectory: number % 71 == 0) }
        var scoped = SearchFilters(); scoped.includedPaths = ["/分块/父"]
        let cursorRequests = [SearchRequest(query: "报告"), SearchRequest(query: "报告", kind: .files),
                              SearchRequest(query: "*.pdf | 不存在 !报告"), SearchRequest(query: "(报告 | 缺失) !不存在"),
                              SearchRequest(query: "父/报", matchPath: true), SearchRequest(query: "", filters: scoped)]
        for request in cursorRequests {
            let expected = chunked.query(request, rootID: "chunk", limit: 10_000)
            let cursor = chunked.makeQueryCursor(request, rootID: "chunk")
            try check(cursor.countCandidates() == expected.totalMatches && cursor.scannedEntries == 0,
                      "候选计数不能推进游标或改变同快照命中总数")
            var actual: [FileHit] = [], batches = 0
            while !cursor.isComplete {
                let values = cursor.next(maximum: 50_000)
                try check(values.count <= 2000, "游标必须硬性限制每批命中数")
                actual.append(contentsOf: values); batches += 1
                try check(batches < 8, "游标必须持续推进直至完成")
            }
            try check(actual == expected.hits && cursor.countCandidates() == expected.totalMatches && cursor.next().isEmpty,
                      "全部游标块必须与一次query顺序、类型、路径及数量完全相同")
        }
        let versioned = chunked.makeQueryCursor(SearchRequest(query: ""), rootID: "chunk", excludeHit: { path in
            // Exclusions may safely re-enter the same engine, without locks.
            _ = chunked.pathIsDirectory(path)
            return path.hasSuffix("_3.pdf")
        })
        let versionedCount = versioned.countCandidates()
        chunked.removeSubtree(path: "/分块/父/报告_3.pdf")
        chunked.add(path: "/分块/父/新加.pdf", isDirectory: false)
        var versionedHits: [FileHit] = []
        while !versioned.isComplete { versionedHits.append(contentsOf: versioned.next(maximum: 137)) }
        try check(versionedCount == 4_136 && versionedHits.count == 4_136 &&
                  versioned.hasPath("/分块/父/报告_3.pdf") && !versioned.hasPath("/分块/父/新加.pdf"),
                  "分块读取及成员判断不能混入创建游标之后的增删")
        let cursorCancellation = CancellationFlag()
        let cancelledCursor = chunked.makeQueryCursor(SearchRequest(query: "", cancellation: cursorCancellation), rootID: "chunk")
        try check(cancelledCursor.next(maximum: 17).count == 17, "游标应按请求的小批量上限返回")
        cursorCancellation.cancel()
        try check(cancelledCursor.isComplete && cancelledCursor.next().isEmpty && cancelledCursor.countCandidates() == 0,
                  "取消后游标不能再产生条目或继续候选计数")

        // Resolving scopes happens once per query version. Changing an owned
        // alias after capture must not make countCandidates reparse a new scope.
        let scopeA = temporary.appendingPathComponent("scope-a", isDirectory: true)
        let scopeB = temporary.appendingPathComponent("scope-b", isDirectory: true)
        let scopeAlias = temporary.appendingPathComponent("scope-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: scopeA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scopeB, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scopeAlias, withDestinationURL: scopeA)
        let scopedIndex = EngineIndex()
        scopedIndex.add(path: SearchFilters.canonicalScopePath(scopeA.path) + "/first.txt", isDirectory: false)
        scopedIndex.add(path: SearchFilters.canonicalScopePath(scopeB.path) + "/second.txt", isDirectory: false)
        var aliasFilters = SearchFilters(); aliasFilters.includedPaths = [scopeAlias.path]
        let scopedCursor = scopedIndex.makeQueryCursor(SearchRequest(query: "", filters: aliasFilters), rootID: "alias")
        try FileManager.default.removeItem(at: scopeAlias)
        try FileManager.default.createSymbolicLink(at: scopeAlias, withDestinationURL: scopeB)
        try check(scopedCursor.countCandidates() == 1 && scopedCursor.next().map(\.name) == ["first.txt"],
                  "游标计数必须保持创建时解析的目录范围，不能重新解析已改变的别名")

        // A valid checksum cannot make overlapping/gapped normalized offsets
        // acceptable. v1 strict validation is kept for rollback compatibility.
        try index.save(to: savedURL)
        var overlap = try Data(contentsOf: savedURL).dropLast(32)
        for byte in 0..<8 { overlap[offsetArrayStart + 8 + byte] = 0 }
        overlap.append(contentsOf: SHA256.hash(data: overlap))
        try overlap.write(to: damagedURL)
        do { _ = try EngineIndex.load(from: damagedURL); throw EngineTestError.failed("有效校验和的重叠字节索引被接受") }
        catch is IndexPersistenceError { }

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
                "compactHashCollisionAndUnicode": "passed", "boundedQueryCursor": "passed",
                "sharedPrefixBoundary": "passed", "graphemeWildcardEquivalence": "passed",
                "syntheticEntries": numberOfEntries, "indexBuildMilliseconds": indexingMilliseconds,
                "binaryFileBytes": largeFileSize, "binarySaveMilliseconds": saveMilliseconds,
                "binaryLoadMilliseconds": loadMilliseconds,
                "searches": searches,
                "note": "合成索引基准，不代表全盘首次扫描或真实用户验收。"]
    }
}

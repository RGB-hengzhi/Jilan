// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum MetadataStreamingTests {
    static func run() throws -> [String: Any] {
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw EngineTestError.failed("分批属性检查：" + message) }
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("JilanMetadataChunks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let big = fixture.appendingPathComponent("大文件.txt"), small = fixture.appendingPathComponent("小文件.txt")
        try Data(repeating: 1, count: 2048).write(to: big)
        try Data(repeating: 1, count: 7).write(to: small)
        let metadata = MetadataQuery(cacheCapacity: 8)
        let plan = AdvancedSearchPlan.parse(SearchRequest(query: "size:>1kib"))
        // Real APFS attributes, split at boundaries unrelated to the accepted
        // pattern. Only three fixture paths are used; no user files are read.
        let session = metadata.makeSession(totalCandidates: 6503, plan: plan, matchPath: false,
                                          limit: 13, cancellation: CancellationFlag())
        var expected = 0
        for start in stride(from: 0, to: 6503, by: 257) {
            let chunk = (start..<min(6503, start + 257)).map { i -> FileHit in
                if i % 11 == 0 { return FileHit(path: big.path, isDirectory: false, rootID: "offline", isOnline: false) }
                if i % 3 == 0 { expected += 1; return FileHit(path: big.path, isDirectory: false, rootID: "fixture") }
                return FileHit(path: small.path, isDirectory: false, rootID: "fixture")
            }
            try check(session.consume(chunk), "未取消的分块不应中止")
            try check(session.progress.hits.count <= 13, "会话不得保存全部匹配候选")
        }
        let complete = session.progress
        try check(complete.inspected == 6503 && complete.totalCandidates == 6503 && !complete.hasMore,
                  "分块完成后候选总量或已检查数量错误")
        try check(complete.totalMatches == expected && complete.hits.count == 13,
                  "跨块累计匹配数量及显示上限错误")
        try check(complete.hits.allSatisfy { $0.path == big.path && $0.size == 2048 }, "真实文件属性未保留")
        try check(complete.offline == 592 && complete.unavailable == 0, "离线候选统计错误")

        let flag = CancellationFlag()
        var reads = 0
        let cancelSession = metadata.makeSession(totalCandidates: 100, plan: plan, matchPath: false,
            limit: 5, cancellation: flag, readProperties: { _ in
                reads += 1
                if reads == 7 { flag.cancel() }
                return MetadataQuery.Properties(size: 2048, modified: nil)
            })
        let one = FileHit(path: big.path, isDirectory: false, rootID: "fixture")
        try check(cancelSession.consume(Array(repeating: one, count: 3)), "第一块应完成")
        try check(cancelSession.consume(Array(repeating: one, count: 3)), "第二块应完成")
        try check(!cancelSession.consume(Array(repeating: one, count: 20)), "后续块必须立即响应取消")
        try check(reads == 7 && cancelSession.progress.inspected == 7 && cancelSession.progress.cancelled,
                  "取消后继续读取或丢失跨块统计")
        try check(cancelSession.progress.hasMore && cancelSession.progress.hits.count == 5,
                  "取消后应保留已确认显示行与未检查状态")

        let partial = metadata.makeSession(totalCandidates: 100, plan: plan, matchPath: false,
                                           limit: 1, cancellation: CancellationFlag())
        partial.consume([one])
        try check(partial.progress.inspected == 1 && partial.progress.uninspected == 99,
                  "首轮预算结束不能假称全量检查完成")
        return ["result": "passed", "actualAttributeCandidates": 6503, "maximumInputChunk": 257,
                "retainedRows": 13, "cancelledAfterReads": reads,
                "note": "真实自有APFS属性，候选重复用于分块压力；不代表全盘元数据性能。"]
    }
}

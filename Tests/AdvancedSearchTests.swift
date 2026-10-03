// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum AdvancedSearchTests {
    static func run() throws -> [String: Any] {
        func check(_ predicate: @autoclosure () throws -> Bool, _ message: String) throws {
            if try predicate() == false { throw EngineTestError.failed("高级搜索：" + message) }
        }
        let index = EngineIndex()
        let entries: [(String, Bool)] = [
            ("/高级搜索/季度 报告 最终.PDF", false), ("/高级搜索/季度预算.docx", false),
            ("/高级搜索/旧季度报告.pdf", false), ("/高级搜索/报告文件夹.pdf", true),
            ("/高级搜索/文档甲.txt", false), ("/高级搜索/文档甲乙.txt", false),
            ("/高级搜索/e\u{0301}cole.txt", false), ("/高级搜索/colon:name.txt", false)
        ]
        for (path, directory) in entries { index.add(path: path, isDirectory: directory) }
        func names(_ text: String, kind: SearchKind = .all, ext: String = "", path: Bool = false) -> Set<String> {
            Set(index.query(SearchRequest(query: text, kind: kind, extensionFilter: ext, matchPath: path),
                            rootID: "syntax", limit: 100).hits.map(\.name))
        }
        try check(names("季度 报告").count == 2, "空格 AND 必须保留")
        try check(names("\"季度 报告\"").count == 1, "引号应把带空格的片段作为一项连续条件")
        try check(names("季度 !旧").count == 2, "排除词")
        try check(names("预算 | 旧").count == 2, "OR 并集")
        try check(names("预算 | 旧 !报告").count == 1, "AND 优先于 OR")
        try check(names("ext:pdf").count == 2, "大小写扩展名与目录排除")
        try check(names("ext:pdf,docx").count == 3, "扩展名列表")
        try check(names("!ext:pdf").count == 6, "负扩展名包含目录")
        try check(names("file:报告").count == 2 && names("folder:报告").count == 1, "类型与名称组合")
        try check(names("folder:").count == 1 && names("!folder:").count == 7, "空类型条件及排除类型")
        try check(names("*.PDF").count == 3, "通配符以整个名称匹配，仍保留类型筛选选项")
        try check(names("*.pdf", kind: .files).count == 2, "通配与文件类型控件组合")
        try check(names("文档?.txt").count == 1, "? 应消费一个中文字符")
        try check(names("*ÉCOLE*").count == 1, "通配符与 NFC/NFD、大小写规范化")
        try check(names("*预算", path: true).isEmpty, "通配符必须匹配整个路径而非隐式子串")
        try check(names("colon:name").count == 1, "未识别前缀仍是普通文件名")
        try check(names("季度", ext: "pdf").count == 2, "UI 控件与输入条件取交集")
        // Common wildcard byte fast paths must remain equivalent to generic
        // Character matching, including folders, hidden dotfiles and negation.
        let edgeIndex = EngineIndex()
        let edgeEntries: [(String, Bool)] = [("/通配/.pdf", false), ("/通配/文件夹.pdf", true),
            ("/通配/合同.pdf", false), ("/通配/合同草稿.pdf", false), ("/通配/文档.docx", false),
            ("/通配/归档.tar.gz", false), ("/通配/前缀é尾巴.txt", false), ("/通配/无后缀", false)]
        for (path, directory) in edgeEntries { edgeIndex.add(path: path, isDirectory: directory) }
        let edgeQueries = ["*.pdf | *.docx", "合同 *.pdf !草稿", "!*.pdf", "file:*.pdf", "folder:*.pdf",
                           "*.tar.gz", "前缀*txt", "*é*", "ext:pdf | ext:docx", "!ext:pdf", "*", "文档* | *.pdf !合同"]
        for query in edgeQueries {
            let plan = AdvancedSearchPlan.parse(SearchRequest(query: query))
            let expected = Set(edgeEntries.filter { path, directory in
                let name = (path as NSString).lastPathComponent
                return plan.matchesName(normalizedText: AdvancedSearchPlan.normalize(name), isDirectory: directory,
                                        extensionValue: AdvancedSearchPlan.normalize((name as NSString).pathExtension))
            }.map { $0.0 })
            let actual = Set(edgeIndex.query(SearchRequest(query: query), rootID: "edge", limit: 100).hits.map(\.path))
            try check(actual == expected, "字节快路与通用匹配语义必须一致：\(query)")
        }
        for invalid in ["季度 |", "| 报告", "\"季度", "!", "size:wat", "dm:2026-02-30", "ext:"] {
            try check(AdvancedSearchPlan.parse(SearchRequest(query: invalid)).error != nil, "应明确拒绝无效条件 \(invalid)")
            try check(names(invalid).isEmpty, "无效条件不能返回无条件列表")
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("QuickFindAdvancedTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let old = calendar.date(byAdding: .day, value: -10, to: today)!
        let files: [(String, Int, Date)] = [("today.pdf", 2000, now), ("yesterday.txt", 500, yesterday), ("old.pdf", 3000, old)]
        var candidates: [FileHit] = []
        for (name, size, date) in files {
            let url = temporary.appendingPathComponent(name)
            try Data(repeating: 0x61, count: size).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            candidates.append(FileHit(path: url.path, isDirectory: false, rootID: "fixture"))
        }
        let folder = temporary.appendingPathComponent("文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: folder.path)
        candidates.append(FileHit(path: folder.path, isDirectory: true, rootID: "fixture"))
        candidates.append(FileHit(path: temporary.appendingPathComponent("离线.txt").path, isDirectory: false, rootID: "offline", isOnline: false))
        candidates.append(FileHit(path: temporary.appendingPathComponent("不存在.txt").path, isDirectory: false, rootID: "fixture"))
        let metadata = MetadataQuery()
        func propertySearch(_ text: String, size: String = "", modified: String = "", limit: Int = 100) -> MetadataQuery.Progress {
            let request = SearchRequest(query: text, sizeFilter: size, modifiedFilter: modified)
            let plan = AdvancedSearchPlan.parse(request, now: now, calendar: calendar)
            return metadata.filter(candidates, totalCandidates: candidates.count, plan: plan, matchPath: false,
                                   limit: limit, cancellation: CancellationFlag())
        }
        let large = propertySearch("size:>1kib")
        try check(large.totalMatches == 2 && large.offline == 1 && large.unavailable == 2,
                  "实际大小、文件夹体积未知、离线及不存在文件应区分")
        try check(Set(large.hits.map { $0.size ?? -1 }) == [2000, 3000], "属性查询应附带实际文件字节数")
        try check(propertySearch("size:500b..2kb").totalMatches == 2, "大小范围两端包含，KB 使用十进制")
        try check(propertySearch("", size: ">=1kib", modified: "7days").totalMatches == 1, "两个属性控件相交")
        try check(propertySearch("dm:today").totalMatches == 2, "today 包含当日文件与目录")
        try check(propertySearch("dm:yesterday").totalMatches == 1, "yesterday 按本地日界而非过去24小时")
        try check(propertySearch("dm:2026-10-02..2026-10-03").totalMatches == 3, "日期范围完整包含结束日")
        try check(propertySearch("dm:>2026-10-02").totalMatches == 2, "日期 > 排除整个指定日")
        try check(propertySearch("size:>2kb | ext:txt").totalMatches == 4,
                  "属性和名字 OR 的完整布尔关系；可独立确认名字分支的离线结果")
        try check(propertySearch("!size:>1kb").totalMatches == 1, "未知属性不能因否定条件被错误纳入")
        try check(propertySearch("dm:today", limit: 1).totalMatches == 2 && propertySearch("dm:today", limit: 1).hits.count == 1,
                  "属性命中总数不得被首屏截断")
        let partial = metadata.filter(Array(candidates.prefix(1)), totalCandidates: candidates.count,
                    plan: AdvancedSearchPlan.parse(SearchRequest(query: "size:>1kb")), matchPath: false,
                    limit: 100, cancellation: CancellationFlag())
        try check(partial.hasMore && partial.uninspected == 5 && partial.totalMatches == 1,
                  "未检查候选必须明确报告，不能冒充已排除")

        // Cache invalidation must expose an updated file rather than continuing
        // to serve properties from before a copy/move/rename task completion.
        let changedURL = temporary.appendingPathComponent("today.pdf")
        try Data(repeating: 0x62, count: 4000).write(to: changedURL)
        metadata.invalidate()
        try check(metadata.properties(for: changedURL.path)?.size == 4000, "显式属性缓存失效")

        let cancellation = CancellationFlag()
        var reads = 0
        let cancellable = metadata.filter(Array(repeating: candidates[0], count: 100_000), totalCandidates: 100_000,
            plan: AdvancedSearchPlan.parse(SearchRequest(query: "size:>1kb")), matchPath: false, limit: 100,
            cancellation: cancellation, readProperties: { _ in
                reads += 1
                // Re-entering the index here proves metadata callbacks are not
                // inside SearchEngine's lock.
                _ = index.query(SearchRequest(query: "季度"), rootID: "syntax", limit: 1)
                if reads == 7 { cancellation.cancel() }
                return MetadataQuery.Properties(size: 4000, modified: now)
            })
        try check(cancellable.cancelled && reads == 7 && cancellable.inspected == 7,
                  "属性查询应逐项响应取消，属性回调允许重入名称索引")
        let cancelledIndexQuery = CancellationFlag(); cancelledIndexQuery.cancel()
        try check(index.query(SearchRequest(query: "季度", cancellation: cancelledIndexQuery), rootID: "syntax", limit: 100).hits.isEmpty,
                  "取消后的名称查询不得继续执行")
        return ["syntaxChecks": "passed", "actualFilePropertyChecks": "passed", "cancellationChecks": "passed",
                "wildcardByteFastPathEquivalence": "passed",
                "metadataCacheInvalidation": "passed", "fixtureFiles": files.count,
                "note": "仅操作自建临时文件；大小/日期属性筛选是后台读取，速度不等同于纯名称索引。"]
    }
}

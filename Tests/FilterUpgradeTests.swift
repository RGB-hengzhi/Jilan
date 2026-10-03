// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Expected path sets are specified independently of the production matcher.
/// Metadata, online/offline state and Finder flags use only owned UUID fixtures.
enum FilterUpgradeTests {
    static func run() throws -> [String: Any] {
        try indexedFilters()
        let canonicalScopeCases = try canonicalPathScopes()
        try booleanSyntax()
        try metadataConditions()
        try finderHiddenFlags()
        try connectionFilters()
        return ["status": "passed", "nameCategoryAndPathFilters": true,
            "independentExpectedPathSets": true, "filterBeforeFirstPageAndCount": true,
            "nestedAndOrNegatedConditions": true, "parenthesizedQueryPrecedence": true,
            "quotedReservedPrefixes": true,
            "invalidSyntaxRejected": true, "threeValuedMetadata": true,
            "canonicalAndSymlinkScopeCases": canonicalScopeCases, "upperOnlyInvalidRanges": 3,
            "realCreationDate": true, "metadataCancellation": true,
            "dotAndFinderHiddenAncestors": true, "onlineOfflineOwnedCache": true,
            "unknownMetadata": "injected unavailable property read; actual permission denial not claimed",
            "offlineState": "owned directory moved; physical disk unplug not performed"]
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw EngineTestError.failed("筛选升级：" + message) }
    }
    private static func rule(_ field: SearchConditionField, _ comparison: SearchComparison,
                             _ value: String, upper: String = "") -> SearchConditionRule {
        var result = SearchConditionRule()
        result.field = field; result.comparison = comparison; result.value = value; result.upperValue = upper
        return result
    }
    private static func group(_ mode: SearchConditionMode, _ rules: [SearchConditionRule] = [],
                              groups: [SearchConditionGroup] = []) -> SearchConditionGroup {
        var result = SearchConditionGroup(); result.mode = mode; result.rules = rules; result.groups = groups
        return result
    }
    private static func indexedFilters() throws {
        let index = EngineIndex()
        let report = "/筛选/项目/报告甲.PDF", draft = "/筛选/项目/草稿报告.docx"
        let contract = "/筛选/项目/合同.xlsx", nested = "/筛选/项目/子目录/资料.txt"
        let outside = "/筛选/项目旧/报告乙.pdf", unicode = "/筛选/其他/e\u{0301}cole.TXT"
        let image = "/筛选/其他/封面.JPG", video = "/筛选/其他/视频.MP4"
        let audio = "/筛选/其他/音乐.FLAC", archive = "/筛选/其他/备份.ZIP", code = "/筛选/其他/脚本.SWIFT"
        let hiddenParent = "/筛选/项目/.隐私/公开.pdf", hiddenName = "/筛选/项目/.隐藏.txt"
        let hiddenImage = "/筛选/.cache/缓存.png", casePath = "/筛选/CaseArea/文件.bin"
        let unicodePath = "/筛选/e\u{0301}cole目录/资料.bin", unicodeOutside = "/筛选/école目录旧/资料.bin"
        let folders = ["/筛选/项目", "/筛选/项目/子目录", "/筛选/其他/图片.jpg"]
        let files = [report, draft, contract, nested, outside, unicode, image, video, audio, archive, code,
                     hiddenParent, hiddenName, hiddenImage, casePath, unicodePath, unicodeOutside]
        for path in files { index.add(path: path, isDirectory: false) }
        for path in folders { index.add(path: path, isDirectory: true) }
        func result(_ filters: SearchFilters, kind: SearchKind = .files, ext: String = "", limit: Int = 100) -> EngineQueryResult {
            index.query(SearchRequest(query: "", kind: kind, extensionFilter: ext, filters: filters), rootID: "owned-synthetic", limit: limit)
        }
        func expect(_ filters: SearchFilters, _ expected: Set<String>, _ label: String) throws {
            let actual = result(filters)
            try check(Set(actual.hits.map(\.path)) == expected && actual.totalMatches == expected.count, label)
        }
        var filters = SearchFilters()
        try expect(filters, Set(files), "空查询仍列全部文件")
        let categories: [(SearchFilterCategory, Set<String>)] = [
            (.documents, [report, draft, contract, nested, outside, unicode, hiddenParent, hiddenName]),
            (.images, [image, hiddenImage]), (.videos, [video]), (.audio, [audio]),
            (.archives, [archive]), (.code, [code])]
        for (category, expected) in categories {
            filters = SearchFilters(); filters.category = category
            try expect(filters, expected, "常用分类 \(category.rawValue)")
            try check(result(filters, kind: .all).totalMatches == expected.count, "分类不得纳入同后缀目录")
        }
        filters = SearchFilters(); filters.category = .images
        let firstPage = result(filters, limit: 1)
        try check(firstPage.totalMatches == 2 && firstPage.hits.count == 1
                    && [image, hiddenImage].contains(firstPage.hits[0].path), "分类必须在首屏截断和计数前执行")
        try check(result(filters, limit: 0).hits.isEmpty && result(filters, limit: 0).totalMatches == 2,
                  "零条首屏仍保留筛选后的总命中数")
        filters = SearchFilters(); filters.nameValue = "报告"
        try expect(filters, [report, draft, outside], "名称包含")
        filters.nameMode = .prefix
        try expect(filters, [report, outside], "名称开头")
        filters.nameMode = .suffix; filters.nameValue = ".pdf"
        try expect(filters, [report, outside, hiddenParent], "名称结尾不区分大小写")
        filters.nameMode = .exact; filters.nameValue = "ÉCOLE.txt"
        try expect(filters, [unicode], "完整名称的 NFC/NFD 与大小写等价")
        filters = SearchFilters(); filters.includedPaths = ["/筛选/项目/"]
        try expect(filters, [report, draft, contract, nested, hiddenParent, hiddenName], "目录边界和末尾斜杠")
        filters.includedPaths.append("/筛选/其他")
        try expect(filters, [report, draft, contract, nested, hiddenParent, hiddenName, unicode, image, video, audio, archive, code],
                   "多个目录范围取并集")
        filters.excludedPaths = ["/筛选/项目/子目录", "/筛选/项目/.隐私"]
        try expect(filters, [report, draft, contract, hiddenName, unicode, image, video, audio, archive, code], "排除目录优先")
        filters.includeSubfolders = false; filters.excludedPaths = []
        try expect(filters, [report, draft, contract, hiddenName, unicode, image, video, audio, archive, code], "不含子目录仅直接子文件")
        filters.excludedPaths = ["/筛选/项目"]
        try expect(filters, [unicode, image, video, audio, archive, code], "包含和排除同目录时排除优先")
        filters = SearchFilters(); filters.includedPaths = ["/筛选/casearea"]
        try expect(filters, [], "目录路径保留大小写以适配区分大小写磁盘")
        filters.includedPaths = ["/筛选/école目录"]
        try expect(filters, [unicodePath], "目录范围 Unicode 等价且不越界")
        filters.includedPaths = ["/筛选/École目录"]
        try expect(filters, [], "目录范围 É 与 é 大小写不同不得等同")
        filters = SearchFilters(); filters.hidden = .visible
        try expect(filters, Set(files).subtracting([hiddenParent, hiddenName, hiddenImage]), "可见候选排除 dot 名和 dot 祖先")
        filters.hidden = .hidden
        let hiddenCandidates = result(filters)
        try check(hiddenCandidates.totalMatches == files.count, "隐藏候选不得先排除等待 Finder flag 检查的普通名称")
        filters = SearchFilters()
        filters.conditionGroup = group(.all, [rule(.name, .notContains, "草稿")], groups:
            [group(.any, [rule(.extensionName, .equal, "PDF"), rule(.extensionName, .equal, "xlsx")])])
        try expect(filters, [report, outside, hiddenParent, contract], "嵌套 AND/OR 与名称否定")
        try check(result(filters, limit: 1).totalMatches == 4 && result(filters, limit: 1).hits.count == 1,
                  "分组条件必须在首屏和总数之前执行")
        filters.conditionGroup = group(.all, [rule(.path, .prefix, "/筛选/项目/"), rule(.extensionName, .notEqual, "pdf")])
        try expect(filters, [draft, contract, nested, hiddenName], "路径规则与扩展名否定")
        filters.conditionGroup = group(.any, [rule(.name, .equal, "音乐.FLAC"), rule(.name, .equal, "脚本.SWIFT")])
        try expect(filters, [audio, code], "互不共享字符的 OR 分支不得被 SIMD 预筛漏掉")
        filters.category = .audio
        try expect(filters, [audio], "外部分类控件与分组条件取交集")
    }

    private static func booleanSyntax() throws {
        let index = EngineIndex()
        let report = "/布尔/报告.pdf", draft = "/布尔/草稿报告.pdf", contract = "/布尔/合同.docx"
        let budget = "/布尔/预算.xlsx", final = "/布尔/合同(终版).pdf", literal = "/布尔/OR.txt", bang = "/布尔/!注意.txt"
        for path in [report, draft, contract, budget, final, literal, bang] { index.add(path: path, isDirectory: false) }
        let cases: [(String, Set<String>)] = [
            ("(报告 | 合同) !草稿", [report, contract, final]),
            ("报告 | 合同 !草稿", [report, draft, contract, final]),
            ("!(报告 | 合同)", [budget, literal, bang]), ("NOT (报告 OR 合同)", [budget, literal, bang]),
            ("(报告 OR 合同) AND NOT 草稿", [report, contract, final]),
            ("报告 | (合同 !终版)", [report, draft, contract]),
            ("\"合同(终版).pdf\"", [final]), ("\"OR\"", [literal]), ("\"!注意.txt\"", [bang]),
            ("!\"草稿报告\"", [report, contract, budget, final, literal, bang]), ("((报告))", [report, draft])]
        for (query, expected) in cases {
            let response = index.query(SearchRequest(query: query), rootID: "boolean", limit: 100)
            try check(Set(response.hits.map(\.path)) == expected && response.totalMatches == expected.count,
                      "括号、否定和运算优先级：\(query)")
        }
        // Quoting the field separator makes it filename text. Quoting only a
        // function's value must preserve normal ext:/file:/size: behavior.
        let reservedPrefixIndex = EngineIndex()
        let reservedPaths: Set<String> = ["/引号/ext:pdf", "/引号/size:wat.txt", "/引号/dc:today",
            "/引号/dm:2026-02-30", "/引号/file:报告", "/引号/folder:报告", "/引号/普通.pdf", "/引号/报告 最终.txt"]
        for path in reservedPaths { reservedPrefixIndex.add(path: path, isDirectory: false) }
        let reservedCases: [(String, Set<String>)] = [
            ("\"ext:pdf\"", ["/引号/ext:pdf"]), ("ext:\"pdf\"", ["/引号/普通.pdf"]),
            ("\"size:wat.txt\"", ["/引号/size:wat.txt"]), ("\"dc:today\"", ["/引号/dc:today"]),
            ("\"dm:2026-02-30\"", ["/引号/dm:2026-02-30"]), ("\"file:报告\"", ["/引号/file:报告"]),
            ("\"folder:报告\"", ["/引号/folder:报告"]), ("file:\"报告 最终\"", ["/引号/报告 最终.txt"]),
            ("!\"ext:pdf\"", reservedPaths.subtracting(["/引号/ext:pdf"])),
            ("NOT \"size:wat.txt\"", reservedPaths.subtracting(["/引号/size:wat.txt"])),
            ("\"ext:pdf\" | ext:\"pdf\"", ["/引号/ext:pdf", "/引号/普通.pdf"])]
        for (query, expected) in reservedCases {
            let request = SearchRequest(query: query)
            let plan = AdvancedSearchPlan.parse(request)
            let response = reservedPrefixIndex.query(request, rootID: "reserved-prefix", limit: 100)
            try check(plan.error == nil && !plan.usesMetadata && response.totalMatches == expected.count
                        && Set(response.hits.map(\.path)) == expected, "引号保留字段前缀为文字：\(query)")
        }
        try check(AdvancedSearchPlan.parse(SearchRequest(query: "size:\"1kb\"")).usesMetadata
                    && AdvancedSearchPlan.parse(SearchRequest(query: "size:\"1kb\"")).error == nil,
                  "仅值在引号内仍保留属性函数语义")
        for query in ["()", "(报告", "报告)", "报告 || 合同", "(报告 |)", "报告 AND", "NOT", "dc:2026-02-30"] {
            try check(AdvancedSearchPlan.parse(SearchRequest(query: query)).error != nil, "无效语法必须有错误：\(query)")
            try check(index.query(SearchRequest(query: query), rootID: "boolean", limit: 100).totalMatches == 0,
                      "无效语法不得变成无条件查询：\(query)")
        }
        var invalid = SearchFilters(); invalid.conditionGroup.rules = [rule(.size, .greater, "bad-bytes")]
        try check(AdvancedSearchPlan.parse(SearchRequest(query: "", filters: invalid)).error != nil, "无效分组大小条件必须报错")
        invalid = SearchFilters(); invalid.createdFilter = "2026-10-03..2026-10-01"
        try check(AdvancedSearchPlan.parse(SearchRequest(query: "", filters: invalid)).error != nil, "反向创建日期范围必须报错")
        for (field, upper) in [(SearchConditionField.size, "2kb"), (.modified, "2026-10-03"), (.created, "2026-10-03")] {
            let incomplete = rule(field, .range, "", upper: upper)
            try check(!incomplete.isEmpty, "仅填写范围上限的条件不能视为空占位行")
            var upperOnly = SearchFilters(); upperOnly.conditionGroup.rules = [incomplete]
            let request = SearchRequest(query: "", filters: upperOnly)
            try check(AdvancedSearchPlan.parse(request).error != nil, "\(field.rawValue)仅上限 range 必须明确报错")
            try check(index.query(request, rootID: "boolean", limit: 100).totalMatches == 0,
                      "\(field.rawValue)仅上限 range 不得被忽略后返回全量")
        }
    }

    private static func canonicalPathScopes() throws -> Int {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("QuickFindCanonicalScopes-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("真实目录"), outside = fixture.appendingPathComponent("真实目录旧")
        let nested = root.appendingPathComponent("子目录"), alias = fixture.appendingPathComponent("目录别名")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: fixture) }
        try Data().write(to: root.appendingPathComponent("直接文件.txt"))
        try Data().write(to: nested.appendingPathComponent("子文件.txt"))
        try Data().write(to: outside.appendingPathComponent("边界外文件.txt"))
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: root.path)
        let physicalRoot = IndexStore.makeRoot(path: root.path).path
        let physicalOutside = IndexStore.makeRoot(path: outside.path).path
        let logicalRoot = physicalRoot.hasPrefix("/private/var/") ? String(physicalRoot.dropFirst("/private".count)) : root.path
        try check(logicalRoot.hasPrefix("/var/") && physicalRoot.hasPrefix("/private/var/")
                    && fm.fileExists(atPath: logicalRoot), "实际 /var 和 /private/var 别名 fixture 不可用")
        let direct = physicalRoot + "/直接文件.txt", child = physicalRoot + "/子目录/子文件.txt"
        let beyond = physicalOutside + "/边界外文件.txt"
        let index = EngineIndex()
        for path in [direct, child, beyond] { index.add(path: path, isDirectory: false) }
        let cases: [([String], [String], Bool, Set<String>, String)] = [
            ([logicalRoot], [], true, [direct, child], "/var 逻辑范围匹配物理索引且不越过目录边界"),
            ([physicalRoot], [], true, [direct, child], "/private/var 物理范围"),
            ([alias.path], [], true, [direct, child], "符号链接包含范围"),
            ([alias.path], [], false, [direct], "符号链接范围的直接子项"),
            ([alias.path], [alias.path + "/子目录"], true, [direct], "符号链接子目录排除"),
            ([logicalRoot, physicalOutside], [alias.path + "/子目录"], true, [direct, beyond], "别名范围并集和子目录排除"),
            ([alias.path, physicalOutside], [logicalRoot], true, [beyond], "逻辑别名排除优先于符号链接包含"),
            ([logicalRoot], [alias.path], true, [], "符号链接排除优先于逻辑别名包含")]
        for (included, excluded, descendants, expected, label) in cases {
            var filters = SearchFilters(); filters.includedPaths = included; filters.excludedPaths = excluded
            filters.includeSubfolders = descendants
            let request = SearchRequest(query: "", kind: .files, filters: filters)
            let all = index.query(request, rootID: "canonical", limit: 100)
            try check(all.totalMatches == expected.count && Set(all.hits.map(\.path)) == expected, label)
            let firstPage = index.query(request, rootID: "canonical", limit: 1)
            try check(firstPage.totalMatches == expected.count && firstPage.hits.count == min(1, expected.count)
                        && firstPage.hits.allSatisfy { expected.contains($0.path) }, label + "的首屏和总数")
        }
        // An unavailable saved scope has no realpath; retain its lexical scope
        // so cached paths remain searchable instead of erasing the condition.
        let missingRoot = "/QuickFindUnavailable-" + UUID().uuidString
        let cached = missingRoot + "/离线缓存.txt"; index.add(path: cached, isDirectory: false)
        var offline = SearchFilters(); offline.includedPaths = [missingRoot]
        let fallback = index.query(SearchRequest(query: "", kind: .files, filters: offline), rootID: "canonical", limit: 100)
        try check(fallback.totalMatches == 1 && fallback.hits.map(\.path) == [cached]
                    && offline.includedPaths == [missingRoot], "不存在范围须保留 lexical 缓存匹配与原配置")
        return cases.count + 1
    }

    private static func metadataConditions() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("QuickFindFilterMetadata-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        // Whole seconds are representable on both APFS and ExFAT fixtures.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let old = calendar.date(byAdding: .day, value: -10, to: now)!
        let metadata = MetadataQuery()
        var candidates: [FileHit] = []
        for (name, size, modified) in [("当天.pdf", 2048, now), ("旧小文件.txt", 512, old), ("旧大图片.jpg", 4096, old)] {
            let url = fixture.appendingPathComponent(name)
            try Data(repeating: 0x61, count: size).write(to: url)
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            // APFS can move birth time backwards when mtime is set earlier.
            // Establish birth separately, then verify the intended real data.
            try fm.setAttributes([.creationDate: now], ofItemAtPath: url.path)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            try check(attributes[.creationDate] as? Date == now
                        && attributes[.modificationDate] as? Date == modified
                        && (attributes[.size] as? NSNumber)?.int64Value == Int64(size),
                      "创建日期 fixture 未独立保持指定 birth、mtime 或字节数：\(name)")
            candidates.append(FileHit(path: url.path, isDirectory: false, rootID: "metadata"))
        }
        let folder = fixture.appendingPathComponent("普通目录")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        candidates.append(FileHit(path: folder.path, isDirectory: true, rootID: "metadata"))
        candidates.append(FileHit(path: fixture.appendingPathComponent("离线.txt").path, isDirectory: false, rootID: "offline", isOnline: false))
        candidates.append(FileHit(path: fixture.appendingPathComponent("缺失.pdf").path, isDirectory: false, rootID: "metadata"))
        func propertySearch(_ filters: SearchFilters, query: String = "", limit: Int = 100) -> MetadataQuery.Progress {
            let plan = AdvancedSearchPlan.parse(SearchRequest(query: query, filters: filters), now: now, calendar: calendar)
            return metadata.filter(candidates, totalCandidates: candidates.count, plan: plan, matchPath: false,
                                   limit: limit, cancellation: CancellationFlag())
        }
        var filters = SearchFilters(); filters.createdFilter = "today"
        let created = propertySearch(filters)
        try check(created.totalMatches == 4 && created.hits.allSatisfy { $0.createdDate != nil }, "真实创建日期及目录日期")
        let creationAttributes = try fm.attributesOfItem(atPath: candidates[0].path)[.creationDate] as? Date
        try check(creationAttributes != nil && created.hits.first(where: { $0.path == candidates[0].path })?.createdDate == creationAttributes,
                  "命中携带真实文件 creationDate")
        try check(propertySearch(SearchFilters(), query: "dc:today").totalMatches == 4,
                  "创建日期 query 前缀与筛选控件一致")
        filters = SearchFilters()
        filters.conditionGroup = group(.all, [rule(.size, .greater, "1kib")], groups:
            [group(.any, [rule(.extensionName, .equal, "pdf"), rule(.extensionName, .equal, "jpg")])])
        let sized = propertySearch(filters, limit: 1)
        try check(sized.totalMatches == 2 && sized.hits.count == 1, "混合属性分组确认总数后才截首屏")
        filters.conditionGroup = group(.any, [rule(.extensionName, .equal, "txt")], groups:
            [group(.all, [rule(.size, .greater, "1kib"), rule(.modified, .equal, "today")])])
        try check(Set(propertySearch(filters).hits.map(\.name)) == ["当天.pdf", "旧小文件.txt", "离线.txt"],
                  "名字 OR 属性分组可以确认离线名称分支，且不得误纳入未知分支")
        let unknown = FileHit(path: "/owned/unavailable.bin", isDirectory: false, rootID: "unknown")
        func truth(_ condition: SearchConditionGroup) -> Bool? {
            var value = SearchFilters(); value.conditionGroup = condition
            return AdvancedSearchPlan.parse(SearchRequest(query: "", filters: value)).matches(unknown, matchPath: false, size: nil, modified: nil)
        }
        let sizeUnknown = rule(.size, .notEqual, "1kb")
        try check(truth(group(.all, [sizeUnknown])) == nil, "未知大小否定仍是 unknown")
        try check(truth(group(.all, [sizeUnknown, rule(.name, .equal, "else.bin")])) == false, "AND 的 false 覆盖 unknown")
        try check(truth(group(.any, [sizeUnknown, rule(.name, .equal, "unavailable.bin")])) == true, "OR 的 true 覆盖 unknown")
        try check(truth(group(.any, [sizeUnknown, rule(.name, .equal, "else.bin")])) == nil, "OR 的 false 不能掩盖 unknown")
        var unknownFilters = SearchFilters(); unknownFilters.conditionGroup.rules = [rule(.created, .notEqual, "today")]
        let unknownPlan = AdvancedSearchPlan.parse(SearchRequest(query: "", filters: unknownFilters), now: now, calendar: calendar)
        let unavailable = metadata.filter([unknown], totalCandidates: 1, plan: unknownPlan, matchPath: false,
            limit: 10, cancellation: CancellationFlag(), readProperties: { _ in nil })
        try check(unavailable.totalMatches == 0 && unavailable.unavailable == 1, "无属性读取结果不能因创建日期否定纳入")
        let cancellation = CancellationFlag(); var reads = 0
        let cancelled = metadata.filter(Array(repeating: candidates[0], count: 20), totalCandidates: 20,
            plan: AdvancedSearchPlan.parse(SearchRequest(query: "dc:today"), now: now, calendar: calendar),
            matchPath: false, limit: 5, cancellation: cancellation, readProperties: { path in
                reads += 1; if reads == 3 { cancellation.cancel() }; return metadata.properties(for: path)
            })
        try check(cancelled.cancelled && cancelled.inspected == 3 && reads == 3 && cancelled.hasMore,
                  "创建日期属性检查须响应取消并保留未检查数量")
    }

    private static func finderHiddenFlags() throws {
        let fm = FileManager.default
        let fixture = fm.homeDirectoryForCurrentUser.appendingPathComponent("QuickFindFilterHiddenTests-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: fixture) }
        let visible = fixture.appendingPathComponent("可见.txt"), flagged = fixture.appendingPathComponent("标记隐藏.txt")
        let dotParent = fixture.appendingPathComponent(".点目录"), flaggedParent = fixture.appendingPathComponent("标记目录")
        try Data().write(to: visible); try Data().write(to: flagged)
        try fm.createDirectory(at: dotParent, withIntermediateDirectories: false)
        try fm.createDirectory(at: flaggedParent, withIntermediateDirectories: false)
        let dotChild = dotParent.appendingPathComponent("子文件.txt"), flaggedChild = flaggedParent.appendingPathComponent("子文件.txt")
        try Data().write(to: dotChild); try Data().write(to: flaggedChild)
        var values = URLResourceValues(); values.isHidden = true
        var flaggedURL = flagged, parentURL = flaggedParent
        try flaggedURL.setResourceValues(values); try parentURL.setResourceValues(values)
        try check((try? flagged.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true
                    && (try? flaggedParent.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true,
                  "自有 fixture 的 Finder hidden flag 设置失败")
        let candidates = [visible, flagged, dotChild, flaggedChild].map { FileHit(path: $0.path, isDirectory: false, rootID: "hidden") }
        let metadata = MetadataQuery()
        func search(_ hidden: SearchHiddenFilter) -> MetadataQuery.Progress {
            var filters = SearchFilters(); filters.hidden = hidden
            return metadata.filter(candidates, totalCandidates: candidates.count,
                plan: AdvancedSearchPlan.parse(SearchRequest(query: "", filters: filters)), matchPath: false,
                limit: 10, cancellation: CancellationFlag())
        }
        try check(Set(search(.visible).hits.map(\.path)) == [visible.path], "Finder flag 和隐藏祖先均须从可见结果排除")
        try check(Set(search(.hidden).hits.map(\.path)) == [flagged.path, dotChild.path, flaggedChild.path],
                  "普通名称的隐藏 flag、dot 祖先和 flag 祖先均须纳入隐藏结果")
        var filters = SearchFilters(); filters.hidden = .visible
        let unavailable = metadata.filter([candidates[0]], totalCandidates: 1,
            plan: AdvancedSearchPlan.parse(SearchRequest(query: "", filters: filters)), matchPath: false,
            limit: 10, cancellation: CancellationFlag(), readProperties: { _ in MetadataQuery.Properties(size: nil, modified: nil, hidden: nil) })
        try check(unavailable.totalMatches == 0 && unavailable.unavailable == 1, "无法确认 hidden 属性不得当作可见")
    }

    private static func connectionFilters() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("QuickFindFilterConnection-" + UUID().uuidString)
        let online = fixture.appendingPathComponent("在线根"), removable = fixture.appendingPathComponent("离线根")
        let data = fixture.appendingPathComponent("索引数据")
        try fm.createDirectory(at: online, withIntermediateDirectories: true)
        try fm.createDirectory(at: removable, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: fixture) }
        try Data().write(to: online.appendingPathComponent("状态文件_A.txt"))
        try Data().write(to: removable.appendingPathComponent("状态文件_B.txt"))
        let onlineRoot = IndexStore.makeRoot(path: online.path), offlineRoot = IndexStore.makeRoot(path: removable.path)
        let first = IndexStore(dataDirectory: data, initialRoots: [onlineRoot, offlineRoot])
        var firstStopped = false; defer { if !firstStopped { first.shutdown() } }
        first.start()
        func wait(_ label: String, _ predicate: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                if predicate() { return }; RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            throw EngineTestError.failed("筛选连接状态测试超时：" + label)
        }
        try wait("两个自有根扫描完成") {
            first.snapshot().roots.count == 2 && first.snapshot().roots.allSatisfy { $0.state == "就绪" }
                && first.search(SearchRequest(query: "状态文件")).totalMatches == 2
        }
        first.shutdown(); firstStopped = true
        try fm.moveItem(at: removable, to: fixture.appendingPathComponent("暂时断开"))
        let second = IndexStore(dataDirectory: data, initialRoots: [onlineRoot, offlineRoot])
        defer { second.shutdown() }; second.start()
        try wait("离线缓存与在线根载入") {
            second.snapshot().roots.count == 2
                && second.snapshot().roots.first(where: { $0.id == onlineRoot.id })?.state == "就绪"
                && second.snapshot().roots.first(where: { $0.id == offlineRoot.id })?.isOnline == false
                && second.search(SearchRequest(query: "状态文件")).totalMatches == 2
        }
        for (connection, expectedPath, expectedOnline) in [
            (SearchConnectionFilter.online, onlineRoot.path + "/状态文件_A.txt", true),
            (SearchConnectionFilter.offline, offlineRoot.path + "/状态文件_B.txt", false)] {
            var filters = SearchFilters(); filters.connection = connection
            let request = SearchRequest(query: "", kind: .files, filters: filters)
            let result = second.search(request, limit: 1)
            try check(result.totalMatches == 1 && result.hits.map(\.path) == [expectedPath]
                        && result.hits.first?.isOnline == expectedOnline, "连接状态须在首屏和计数前过滤")
            try check(second.search(request, limit: 0).totalMatches == 1 && second.search(request, limit: 0).hits.isEmpty,
                      "连接状态零首屏保留正确计数")
        }
        var offlineOnly = SearchFilters(); offlineOnly.connection = .offline
        try check(second.search(SearchRequest(query: "", rootID: onlineRoot.id, filters: offlineOnly)).totalMatches == 0,
                  "连接状态和指定根范围须取交集")
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Owned files exercise real FSEvents. Only scan-progress notifications are
/// injected: they must update the footer without scheduling another query.
enum IdleSearchTests {
    @MainActor
    static func run() throws -> [String: Any] {
        guard Thread.isMainThread else {
            throw EngineTestError.failed("空闲搜索诊断必须由主线程运行。")
        }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("QuickFindIdleSearchTests-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("真实文件")
        let data = fixture.appendingPathComponent("索引数据")
        let nested = root.appendingPathComponent("子目录")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let original = root.appendingPathComponent("检索稳定_甲.txt")
        try Data("甲文件".utf8).write(to: original)
        try Data("非匹配文件".utf8).write(to: root.appendingPathComponent("无关资料.pdf"))
        try Data("子文件".utf8).write(to: nested.appendingPathComponent("子文件.txt"))
        // Foundation URL paths can retain /var after resolving symlinks. The
        // scanner uses the root's physical /private/var path, so compare it too.
        let originalPath = IndexStore.makeRoot(path: original.path).path
        let nestedPath = IndexStore.makeRoot(path: nested.path).path

        let store = IndexStore(dataDirectory: data, initialRoots: [IndexStore.makeRoot(path: root.path)])
        let model = AppModel(store: store)
        defer { model.onChange = nil; model.shutdown() }
        model.query = "检索稳定"
        model.start()

        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw EngineTestError.failed(message) }
        }
        func pump(_ duration: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(duration))
        }
        func wait(_ label: String, timeout: TimeInterval = 12, _ predicate: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if predicate() { return }
                pump(0.02)
            }
            let storeState = store.snapshot()
            let rootStates = model.roots.map { $0.state + ":" + $0.path }
            throw EngineTestError.failed("空闲搜索测试超时：\(label)，状态：\(model.message)，"
                + "查询：\(model.query)，当前：\(model.resultsAreCurrent)，待查询：\(model.isSearchPending)，"
                + "扫描：\(model.isScanning)，调度：\(model.searchGeneration)，"
                + "根状态：\(rootStates)，"
                + "模型结果：\(model.results.map(\.path))，"
                + "实际索引结果：\(store.search(SearchRequest(query: model.query)).hits.map(\.path))，"
                + "实际扫描：\(storeState.isScanning)，revision：\(storeState.searchRevision)，"
                + "原始 URL：\(original.path)，物理期望：\(originalPath)")
        }
        try wait("初次真实扫描和查询") {
            !model.isScanning && model.roots.first?.state == "就绪"
                && model.resultsAreCurrent && model.results.map(\.path) == [originalPath]
        }
        // Let the final startup notification and any coalesced query complete.
        pump(0.3)
        let idlePaths = model.results.map(\.path)
        let userQueryTime = model.queryMilliseconds
        var lostCurrentResults = false
        var changedUserQueryTime = false
        model.onChange = {
            lostCurrentResults = lostCurrentResults || !model.resultsAreCurrent
            changedUserQueryTime = changedUserQueryTime || model.queryMilliseconds != userQueryTime
        }

        // Cover both the scan throttle interval and scan completion. Neither
        // changes index content, so neither may interrupt the completed query.
        pump(1.6)
        // Startup file events may be delivered during that throttle interval.
        // Capture the scheduling baseline immediately before synthetic notices.
        let initialRevision = store.snapshot().searchRevision
        let idleGeneration = model.searchGeneration
        var progress = store.snapshot()
        for step in 1...6 {
            progress.isScanning = true
            progress.scannedCount += step
            progress.message = "仅扫描进度 \(step)"
            store.onUpdate?(progress)
        }
        progress.isScanning = false
        progress.message = "仅扫描进度结束"
        store.onUpdate?(progress)
        try wait("进度通知抵达主线程", timeout: 2) { model.message == "仅扫描进度结束" }
        pump(0.15)
        try check(model.searchGeneration == idleGeneration,
                  "纯扫描进度重新调度了搜索：\(idleGeneration) -> \(model.searchGeneration)，"
                    + "revision：\(initialRevision) -> \(store.snapshot().searchRevision)。")
        try check(model.results.map(\.path) == idlePaths && model.totalMatches == 1,
                  "纯扫描进度改变了有效结果。")
        try check(!lostCurrentResults && !changedUserQueryTime,
                  "纯扫描进度打断有效结果或覆盖了用户查询耗时。")

        // A rename keeps the total count unchanged. It still has to advance the
        // content revision and refresh the same query through the real watcher.
        let renamed = root.appendingPathComponent("检索稳定_乙.txt")
        try fm.moveItem(at: original, to: renamed)
        let renamedPath = IndexStore.makeRoot(path: renamed.path).path
        try wait("同数量改名实时刷新") {
            store.snapshot().searchRevision > initialRevision
                && model.resultsAreCurrent && model.results.map(\.path) == [renamedPath]
        }
        try check(store.search(SearchRequest(query: "检索稳定_甲")).totalMatches == 0,
                  "改名前路径没有从真实索引清除。")
        try check(model.searchGeneration > idleGeneration, "真实改名未调度结果刷新。")

        let matching = root.appendingPathComponent("检索稳定_新建.txt")
        try Data("新增匹配文件".utf8).write(to: matching)
        let matchingPath = IndexStore.makeRoot(path: matching.path).path
        try wait("新建匹配文件实时刷新") {
            model.resultsAreCurrent && model.totalMatches == 2
                && Set(model.results.map(\.path)) == Set([renamedPath, matchingPath])
        }
        let beforeUnmatchedGeneration = model.searchGeneration
        let unrelated = root.appendingPathComponent("其他新建资料.pdf")
        try Data("新增非匹配文件".utf8).write(to: unrelated)
        let unrelatedPath = IndexStore.makeRoot(path: unrelated.path).path
        try wait("非匹配文件更新索引") {
            store.search(SearchRequest(query: unrelated.lastPathComponent)).totalMatches == 1
                && model.searchGeneration > beforeUnmatchedGeneration && model.resultsAreCurrent
        }
        pump(0.15)
        try check(model.totalMatches == 2 && Set(model.results.map(\.path)) == Set([renamedPath, matchingPath]),
                  "非匹配文件变化改变了当前查询结果。")
        try check(!lostCurrentResults && !changedUserQueryTime && model.queryMilliseconds == userQueryTime,
                  "后台真实文件更新打断有效查询或覆盖了用户查询耗时。")

        model.onChange = nil
        model.query = ""
        model.search(immediate: true)
        try wait("空查询显示全量") {
            model.resultsAreCurrent
                && model.totalMatches == store.search(SearchRequest(query: "")).totalMatches
                && model.results.contains(where: { $0.path == nestedPath && $0.isDirectory })
                && model.results.contains(where: { $0.path == unrelatedPath && !$0.isDirectory })
        }
        let blankTime = model.queryMilliseconds
        let blankGeneration = model.searchGeneration
        var blankProgress = store.snapshot()
        blankProgress.message = "空查询仅更新进度"
        store.onUpdate?(blankProgress)
        try wait("空查询进度通知", timeout: 2) { model.message == "空查询仅更新进度" }
        pump(0.1)
        try check(model.searchGeneration == blankGeneration && model.queryMilliseconds == blankTime,
                  "空查询下的纯进度更新重新搜索或覆盖了耗时。")
        model.kind = .files
        model.search(immediate: true)
        try wait("空查询文件筛选") {
            model.resultsAreCurrent && model.totalMatches == 5 && model.results.allSatisfy { !$0.isDirectory }
        }
        model.extensionFilter = "pdf"
        model.search(immediate: true)
        try wait("空查询扩展名筛选") {
            model.resultsAreCurrent && model.totalMatches == 2
                && model.results.allSatisfy { $0.path.hasSuffix(".pdf") }
        }
        model.kind = .folders
        model.extensionFilter = ""
        model.search(immediate: true)
        try wait("空查询文件夹筛选") {
            model.resultsAreCurrent && !model.results.isEmpty && model.results.allSatisfy(\.isDirectory)
        }

        return ["status": "passed", "ownedFixtureOnly": true,
            "progressDoesNotScheduleQuery": true, "emptyQueryProgressStable": true,
            "sameCountRenameRefreshes": true, "matchingCreationRefreshes": true,
            "unmatchedCreationKeepsResults": true, "backgroundResultsRemainCurrent": true,
            "backgroundPreservesUserQueryTiming": true,
            "emptyQueryListsAll": true, "emptyQueryTypeAndExtensionFilters": true,
            "filesystemChanges": "real owned-file rename/create through FSEvents",
            "scanProgress": "injected notification with unchanged searchRevision"]
    }
}

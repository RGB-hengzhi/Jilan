import Foundation
import Darwin

/// Every worker test executes this same signed binary's internal entry point.
/// Stall/crash/wire-fault seams operate only on disposable owned fixtures.
enum ScanWorkerTests {
    static func run() throws -> [String: Any] {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("QuickFindScanWorkerTests-" + UUID().uuidString)
        let blocked = fixture.appendingPathComponent("读取待返回")
        let good = fixture.appendingPathComponent("可继续目录")
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        try fm.createDirectory(at: good, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let cached = blocked.appendingPathComponent("旧缓存应保留.txt"), healthy = good.appendingPathComponent("其它文件.txt")
        try Data("owned timeout fixture".utf8).write(to: cached)
        try Data("owned healthy fixture".utf8).write(to: healthy)
        for number in 0..<600 { try Data().write(to: fixture.appendingPathComponent("文件-\(number).txt")) }
        var pids: [pid_t] = []
        func options(_ timeout: TimeInterval = 10) -> ScanWorker.Options {
            var value = ScanWorker.Options(); value.inactivityTimeout = timeout
            value.childStarted = { pids.append($0) }; return value
        }
        var expected: [String: Bool] = [:]
        let direct = FileScanner.walk(path: fixture.path, excludedPrefixes: [], cancelled: { false },
            onEntry: { expected[$0] = $1 }, onProgress: { _, _ in })
        try check(direct.completed && direct.issues.isEmpty, "owned fixture 必须可完整读取")
        var received: [String: Bool] = [:], progress = 0
        let normal = ScanWorker.scan(path: fixture.path, excludedPrefixes: [""], cancelled: { false },
            onEntry: { received[$0] = $1 }, onProgress: { count, _ in progress = count }, options: options())
        try check(normal.completed && normal.issues.isEmpty && received == expected
                    && normal.count == expected.count && progress == normal.count, "流式结果/最终报告必须与raw walk一致")
        var cancel = false, calls = 0
        let cancelled = ScanWorker.scan(path: fixture.path, excludedPrefixes: [], cancelled: { cancel },
            onEntry: { _, _ in calls += 1; if calls == 3 { cancel = true } }, onProgress: { _, _ in }, options: options())
        try check(!cancelled.completed && cancelled.count == 3 && calls == 3, "第三条取消后不得继续回调或采用helper计数")
        let cancellationBegan = ProcessInfo.processInfo.systemUptime
        var parkedCancel = false, parkedEntries = 0, parkedProgress = 0
        var parkedOptions = options(); parkedOptions.stallOnceAtPath = fixture.path
        let parked = ScanWorker.scan(path: fixture.path, excludedPrefixes: [], cancelled: { parkedCancel },
            onEntry: { _, _ in parkedEntries += 1 }, onProgress: { _, _ in parkedProgress += 1 },
            onIOIntent: { if $0 == fixture.path { parkedCancel = true } }, options: parkedOptions)
        let cancellationSeconds = ProcessInfo.processInfo.systemUptime - cancellationBegan
        try check(!parked.completed && parked.count == 0 && parkedEntries == 0 && parkedProgress == 0
                    && cancellationSeconds < 1, "已停住IO子进程必须在1秒内取消且无晚条目/进度")
        let savedCalls = calls
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try check(calls == savedCalls, "取消返回之后不能迟到回调")
        var timeoutOptions = options(0.35); timeoutOptions.stallOnceAtPath = blocked.path
        var retryEntries: [String: Bool] = [:]
        let retryIndex = EngineIndex()
        let retry = ScanWorker.scan(path: fixture.path, excludedPrefixes: [], cancelled: { false },
            onEntry: { retryEntries[$0] = $1 }, onProgress: { _, _ in },
            indexEntry: { path, directory in
                (retryIndex.add(path: path, isDirectory: directory), retryIndex.count)
            }, options: timeoutOptions)
        try check(retry.completed && retry.totalIssueCount == 1 && retry.issues.count == 1
                    && retry.issues[0].path == blocked.path && retryEntries[healthy.path] == false
                    && retryEntries[cached.path] == nil && retry.count == retryEntries.count, "超时后必须精确标记受限子树并继续其它目录，重试条目不得重复")
        // Legacy callbacks have no index ledger. A timeout returns incomplete
        // after one pass rather than allocating a full duplicate path table.
        let genericPidStart = pids.count
        let genericTimeout = ScanWorker.scan(path: fixture.path, excludedPrefixes: [], cancelled: { false },
            onEntry: { _, _ in }, onProgress: { _, _ in }, options: timeoutOptions)
        try check(!genericTimeout.completed && pids.count == genericPidStart + 1,
                  "无host ledger的超时不得重放条目或另建全路径缓存")

        var hostedCancel = false, hostedCalls = 0
        let cancelIndex = EngineIndex()
        let hosted = ScanWorker.scan(path: fixture.path, excludedPrefixes: [], cancelled: { hostedCancel },
            onEntry: { _, _ in hostedCalls += 1; if hostedCalls == 3 { hostedCancel = true } }, onProgress: { _, _ in },
            indexEntry: { path, directory in (cancelIndex.add(path: path, isDirectory: directory), cancelIndex.count) },
            options: options())
        try check(!hosted.completed && hosted.count == 3 && hostedCalls == 3 && cancelIndex.count == 3,
                  "host索引去重仍须第三条取消且计数精确")

        // At the stalled child's intent, replace the already indexed root with
        // a regular file. The retry must observe the new type and remove every
        // previously staged descendant, without opening that file's contents.
        let changing = fixture.appendingPathComponent("类型变化根"), changingParked = changing.appendingPathComponent("停住子目录")
        let displaced = fixture.appendingPathComponent("类型变化旧目录")
        try fm.createDirectory(at: changingParked, withIntermediateDirectories: true)
        try Data().write(to: changingParked.appendingPathComponent("曾存在的子项.txt"))
        let changeIndex = EngineIndex()
        var changedType = false, mutationFailed = false, typeCallbacks: [Bool] = []
        var changeOptions = options(0.2); changeOptions.stallOnceAtPath = changingParked.path
        let changed = ScanWorker.scan(path: changing.path, excludedPrefixes: [], cancelled: { false },
            onEntry: { path, directory in if path == changing.path { typeCallbacks.append(directory) } }, onProgress: { _, _ in },
            onIOIntent: { path in
                guard path == changingParked.path, !changedType else { return }
                do {
                    try fm.moveItem(at: changing, to: displaced)
                    try Data("owned replacement file".utf8).write(to: changing)
                    changedType = true
                } catch { mutationFailed = true }
            }, indexEntry: { path, directory in
                if !directory && changeIndex.pathIsDirectory(path) == true { changeIndex.removeSubtree(path: path) }
                return (changeIndex.add(path: path, isDirectory: directory), changeIndex.count)
            }, options: changeOptions)
        var replacementStat = stat()
        let replacementIsFile = lstat(changing.path, &replacementStat) == 0
            && replacementStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        let exactChangePaths = Set(changeIndex.query(SearchRequest(query: ""), rootID: "owned", limit: 20).hits.map(\.path))
        try check(!mutationFailed && changedType && replacementIsFile && changed.completed && changed.count == 1
                    && exactChangePaths == [changing.path] && changeIndex.pathIsDirectory(changing.path) == false
                    && typeCallbacks == [true, false], "重试目录转文件须清除staged子树、报告实际一个节点且类型变更只通知一次")

        var noRetryOptions = options(0.15); noRetryOptions.stallOnceAtPath = blocked.path; noRetryOptions.maximumTimeoutRetries = 0
        let noRetry = ScanWorker.scan(path: fixture.path, excludedPrefixes: [], cancelled: { false },
            onEntry: { _, _ in }, onProgress: { _, _ in }, options: noRetryOptions)
        try check(!noRetry.completed && noRetry.issues.first?.path == blocked.path, "重试额度用完必须保守未完成")
        var crashOptions = options(); crashOptions.exitBeforeReport = true
        let crash = ScanWorker.scan(path: fixture.path, excludedPrefixes: [], cancelled: { false },
            onEntry: { _, _ in }, onProgress: { _, _ in }, options: crashOptions)
        try check(!crash.completed && !crash.issues.isEmpty, "EOF/异常退出不能冒充完整扫描")
        for fault in ["oversized", "truncated"] {
            var faultOptions = options(); faultOptions.wireFault = fault
            var malformedEntries = 0
            let malformed = ScanWorker.scan(path: fixture.path, excludedPrefixes: [], cancelled: { false },
                onEntry: { _, _ in malformedEntries += 1 }, onProgress: { _, _ in }, options: faultOptions)
            try check(!malformed.completed && !malformed.issues.isEmpty && malformedEntries == 0, "\(fault)帧必须拒绝且不得产出条目")
        }
        var emptyCalls = 0
        let empty = ScanWorker.scan(path: "", excludedPrefixes: [], cancelled: { false },
            onEntry: { _, _ in emptyCalls += 1 }, onProgress: { _, _ in }, options: options())
        try check(!empty.completed && emptyCalls == 0 && !empty.issues.isEmpty, "空路径不能变成扫描当前目录")
        for pid in pids {
            errno = 0
            let code = kill(pid, 0), reason = errno
            try check(code == -1 && reason == ESRCH, "扫描子进程\(pid)必须已退出并回收，无僵尸或后台继续读取")
        }
        return ["status": "passed", "streamedFixtureEntries": normal.count,
            "batchBoundaryCancellationCount": cancelled.count, "parkedIOCancellationSeconds": cancellationSeconds,
            "timeoutRetryContinuesOtherDirectories": true, "timeoutIssueRetainsExactSubtree": true,
            "retryBudgetIsBounded": true, "genericTimeoutIsSinglePass": true,
            "hostedCancellationKeepsExactCount": true, "retryDirectoryToFileClearsStagedDescendants": true, "crashAndMalformedFramesRejected": true,
            "spawnedChildrenReaped": pids.count, "emptyPathDoesNotScanCWD": true]
    }
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw EngineTestError.failed("隔离扫描进程：" + message) }
    }
}

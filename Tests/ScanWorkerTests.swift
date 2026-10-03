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
        let retry = ScanWorker.scan(path: fixture.path, excludedPrefixes: [], cancelled: { false },
            onEntry: { retryEntries[$0] = $1 }, onProgress: { _, _ in }, options: timeoutOptions)
        try check(retry.completed && retry.totalIssueCount == 1 && retry.issues.count == 1
                    && retry.issues[0].path == blocked.path && retryEntries[healthy.path] == false
                    && retryEntries[cached.path] == nil && retry.count == retryEntries.count, "超时后必须精确标记受限子树并继续其它目录，重试条目不得重复")
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
            "retryBudgetIsBounded": true, "crashAndMalformedFramesRejected": true,
            "spawnedChildrenReaped": pids.count, "emptyPathDoesNotScanCWD": true]
    }
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw EngineTestError.failed("隔离扫描进程：" + message) }
    }
}

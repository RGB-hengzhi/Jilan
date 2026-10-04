import Foundation
import Darwin

enum BackgroundReadCancellationTestError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case .failed(let message): return message } }
}

private final class BackgroundReadCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func increment(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        counts[key, default: 0] += 1; return counts[key]!
    }
    func value(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key, default: 0] }
}

private final class BackgroundReadWeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
}

/// Actual owned files are read through the production services. Hooks only
/// pause an in-flight read so cancellation and coalescing can be deterministic.
enum BackgroundReadCancellationTests {
    @MainActor
    static func run() throws -> [String: Any] {
        guard Thread.isMainThread else { throw BackgroundReadCancellationTestError.failed("后台读取诊断必须在主线程运行。") }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("JilanBackgroundReadTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = try metadataCancellationAndCapacity(root: root)
        let directories = try directoryCoalescing(root: root)
        return ["status": "passed", "resultMetadata": metadata, "directoryBrowser": directories,
                "fixtureScope": "owned temporary files only; no application launch or disk scan"]
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw BackgroundReadCancellationTestError.failed(message) }
    }

    @MainActor
    private static func pump(until condition: () -> Bool, message: String) throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        try expect(condition(), message)
    }

    private static func directory(_ root: URL, _ name: String) throws -> URL {
        let value = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false)
        return value
    }

    private static func file(_ root: URL, _ name: String, size: Int) throws -> String {
        let value = root.appendingPathComponent(name)
        try Data(repeating: 0x61, count: size).write(to: value)
        return value.path
    }

    @MainActor
    private static func metadataCancellationAndCapacity(root: URL) throws -> [String: Any] {
        let old = try directory(root, "old-metadata")
        let current = try directory(root, "current-metadata")
        let oldPaths = try (0..<300).map { try file(old, "old-\($0).txt", size: 10) }
        let latestPath = try file(current, "最新.txt", size: 23)
        let counters = BackgroundReadCounters()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cache = ResultMetadataCache(testHooks: .init(beforeRead: { path in
            if path.hasPrefix(old.path + "/") {
                if counters.increment("obsolete") == 1 {
                    entered.signal()
                    if release.wait(timeout: .now() + 5) == .timedOut { _ = counters.increment("timeout") }
                }
            } else { _ = counters.increment("current") }
        }))
        var callbacks = 0
        var callbacksOnMain = true
        cache.onChange = { callbacks += 1; callbacksOnMain = callbacksOnMain && Thread.isMainThread }
        cache.load(paths: oldPaths)
        try expect(entered.wait(timeout: .now() + 2) == .success, "旧属性任务没有进入真实读取入口。")
        cache.load(paths: Array(oldPaths.reversed()))
        cache.invalidate()
        cache.load(paths: [latestPath])
        release.signal()
        try pump(until: { cache.value(path: latestPath) != nil && cache.pendingEntryCount == 0 }, message: "取消后新属性任务没有完成。")
        try expect(counters.value("timeout") == 0 && counters.value("obsolete") == 1, "取消后旧属性任务继续读取了其它路径。")
        try expect(callbacks == 1 && callbacksOnMain, "旧属性批次回调泄漏，或新批次未在主线程回调。")
        try expect(cache.value(path: latestPath)?.size == 23 && cache.value(path: latestPath)?.modified != nil, "新属性任务未返回真实文件属性。")
        try expect(oldPaths.allSatisfy { cache.value(path: $0) == nil }, "失效代的属性重新进入缓存。")

        cache.invalidate()
        var expectedSizes: [String: Int64] = [:]
        let files = try (0..<4_321).map { index -> String in
            let size = index % 251 + 1
            let path = try file(current, String(format: "排序-%05d.txt", index), size: size)
            expectedSizes[path] = Int64(size); return path
        }
        var peakCached = 0
        var boundedAtEveryCallback = true
        cache.onChange = {
            peakCached = max(peakCached, cache.cachedEntryCount)
            boundedAtEveryCallback = boundedAtEveryCallback && cache.cachedEntryCount <= cache.cacheCapacity
        }
        cache.load(paths: files)
        try pump(until: { cache.pendingEntryCount == 0 }, message: "超过默认容量的排序属性没有完成。")
        try expect(files.allSatisfy { cache.value(path: $0)?.size == expectedSizes[$0] }, "超过 4096 个已加载结果的排序属性被整体逐出。")
        try expect(cache.cacheCapacity == files.count && peakCached == files.count && boundedAtEveryCallback, "属性缓存没有按本代加载范围有界增长。")
        let additional = try (0..<200).map { try file(current, "后续-\($0).txt", size: 17) }
        let retained = Array(files.prefix(50))
        cache.load(paths: retained + additional)
        try pump(until: { cache.pendingEntryCount == 0 }, message: "属性缓存淘汰检查未完成。")
        try expect((retained + additional).allSatisfy { cache.value(path: $0) != nil }, "缓存淘汰了刚请求的有效排序属性。")
        try expect(cache.cachedEntryCount == files.count && boundedAtEveryCallback, "后续读取导致属性缓存超出本代容量。")
        cache.invalidate()
        try expect(cache.cachedEntryCount == 0 && cache.pendingEntryCount == 0 && cache.cacheCapacity == ResultMetadataCache.defaultCapacity, "invalidate 没有清空属性或恢复默认容量。")
        cache.onChange = nil

        let pressure = BackgroundReadCounters()
        let firstBatch = DispatchSemaphore(value: 0)
        let pressureCache = ResultMetadataCache(testHooks: .init(beforeRead: { _ in
            if pressure.increment("reads") == 100 { firstBatch.signal() }
        }))
        pressureCache.load(paths: Array(files.prefix(300)))
        try expect(firstBatch.wait(timeout: .now() + 2) == .success, "属性批次压力测试没有读取首批。")
        // The main callback is deliberately not serviced during this pause.
        usleep(30_000)
        try expect(pressure.value("reads") == 100, "主线程未接收首批时，属性后台继续堆积其它批次。")
        pressureCache.invalidate()
        pressureCache.load(paths: [latestPath])
        try pump(until: { pressureCache.value(path: latestPath)?.size == 23 }, message: "属性发布背压后，新代任务未恢复。")
        try expect(pressure.value("reads") == 101, "发布等待期间失效的旧属性任务未停止。")

        var largeCache: ResultMetadataCache? = ResultMetadataCache()
        let releasedCache = BackgroundReadWeakReference(largeCache)
        largeCache!.load(paths: files)
        try pump(until: { largeCache?.pendingEntryCount == 0 }, message: "销毁缓存测试的真实属性没有完成。")
        largeCache = nil
        try expect(releasedCache.value == nil, "销毁属性缓存时 LRU 节点或后台任务保留了缓存。")

        let teardownReads = BackgroundReadCounters()
        let teardownEntered = DispatchSemaphore(value: 0)
        let teardownRelease = DispatchSemaphore(value: 0)
        let teardownReturned = DispatchSemaphore(value: 0)
        var disappearingCache: ResultMetadataCache? = ResultMetadataCache(testHooks: .init(beforeRead: { _ in
            if teardownReads.increment("reads") == 1 {
                teardownEntered.signal(); _ = teardownRelease.wait(timeout: .now() + 5); teardownReturned.signal()
            }
        }))
        let weakCache = BackgroundReadWeakReference(disappearingCache)
        var teardownCallbacks = 0
        disappearingCache!.onChange = { teardownCallbacks += 1 }
        disappearingCache!.load(paths: oldPaths)
        try expect(teardownEntered.wait(timeout: .now() + 2) == .success, "属性销毁取消测试未进入读取。")
        disappearingCache = nil
        try expect(weakCache.value == nil, "旧属性任务保留了已销毁的缓存。")
        teardownRelease.signal()
        try expect(teardownReturned.wait(timeout: .now() + 2) == .success, "属性销毁取消的读取入口未返回。")
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        try expect(teardownReads.value("reads") == 1 && teardownCallbacks == 0, "缓存销毁后仍读取旧路径或发布属性。")
        return ["inFlightAndQueuedCancellation": true, "staleCallbacksSuppressed": true,
                "callbacksOnMain": true, "sortFixtureCount": files.count,
                "peakCachedEntries": peakCached, "boundedEvictionAndRecentReads": true,
                "invalidateResetsCapacity": true, "publishBackpressure": true,
                "deinitCancelsReadAndUnlinksCache": true]
    }

    @MainActor
    private static func directoryCoalescing(root: URL) throws -> [String: Any] {
        let old = try directory(root, "old-directory")
        let intermediate = try directory(root, "intermediate-directory")
        let latest = try directory(root, "latest-directory")
        for index in 0..<300 { _ = try file(old, "旧-\(index).txt", size: 10) }
        _ = try file(intermediate, "中间.txt", size: 12)
        _ = try file(latest, "最新.txt", size: 31)
        _ = try file(latest, ".隐藏.txt", size: 19)
        _ = try directory(latest, "中文文件夹")
        try FileManager.default.createSymbolicLink(atPath: latest.appendingPathComponent("失效链接").path,
                                                  withDestinationPath: root.appendingPathComponent("不存在").path)
        let counters = BackgroundReadCounters()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let browser = DirectoryBrowser(testHooks: .init(beforeEnumeration: { path in
            _ = counters.increment("enumerate:" + path)
        }, beforeEntryRead: { path in
            if path.hasPrefix(old.path + "/") && counters.increment("old-entry") == 1 {
                entered.signal()
                if release.wait(timeout: .now() + 5) == .timedOut { _ = counters.increment("timeout") }
            }
        }))
        var obsoleteCallbacks = 0
        var latestCallbacks = 0
        var callbacksOnMain = true
        var result: Result<[DirectoryEntry], Error>?
        browser.load(path: old.path) { _ in obsoleteCallbacks += 1 }
        try expect(entered.wait(timeout: .now() + 2) == .success, "旧目录任务没有进入文件属性读取。")
        for _ in 0..<200 { browser.load(path: intermediate.path) { _ in obsoleteCallbacks += 1 } }
        browser.load(path: latest.path) { value in
            result = value; latestCallbacks += 1; callbacksOnMain = callbacksOnMain && Thread.isMainThread
        }
        release.signal()
        try pump(until: { result != nil }, message: "合并切换后最新目录回调未到达。")
        let rows = try result!.get()
        try expect(obsoleteCallbacks == 0 && latestCallbacks == 1 && callbacksOnMain, "过期目录回调没有被抑制，或最新回调不正确。")
        try expect(counters.value("old-entry") == 1 && counters.value("timeout") == 0, "取消后旧目录继续检查属性。")
        try expect(counters.value("enumerate:" + intermediate.path) == 0 && counters.value("enumerate:" + latest.path) == 1, "快速切换仍执行了中间目录请求。")
        try expect(rows.count == 3 && rows.first?.isDirectory == true, "最新目录隐藏规则或文件夹优先排序改变。")
        try expect(rows.allSatisfy { $0.path.hasPrefix(latest.path + "/") }, "目录回调返回了旧目录或改变了输入路径。")
        try expect(rows.first { $0.name == "最新.txt" }?.size == 31, "目录浏览没有读取真实大小。")
        try expect(rows.first { $0.name == "失效链接" }?.isSymbolicLink == true && rows.first { $0.name == "失效链接" }?.isDirectory == false, "失效符号链接语义改变。")

        result = nil
        browser.load(path: latest.path, showHidden: true) { result = $0 }
        try pump(until: { result != nil }, message: "显示隐藏文件的目录请求未完成。")
        try expect(try result!.get().contains { $0.name == ".隐藏.txt" }, "显示隐藏文件设置未保留。")
        result = nil
        browser.load(path: "relative/path") { result = $0 }
        try pump(until: { result != nil }, message: "相对路径错误没有回调。")
        if case .failure(let error) = result! {
            let value = error as NSError
            try expect(value.domain == "QuickFind.DirectoryBrowser" && value.code == 1, "相对路径错误语义被改变。")
        } else { throw BackgroundReadCancellationTestError.failed("相对路径没有返回原有错误。") }

        let missing = root.appendingPathComponent("缺失目录")
        var originalError: NSError?
        do { _ = try FileManager.default.contentsOfDirectory(at: missing, includingPropertiesForKeys: [.isHiddenKey], options: [.skipsHiddenFiles]) }
        catch { originalError = error as NSError }
        result = nil
        browser.load(path: missing.path) { result = $0 }
        try pump(until: { result != nil }, message: "缺失目录错误没有回调。")
        if case .failure(let error) = result! {
            let value = error as NSError
            try expect(value.domain == originalError?.domain && value.code == originalError?.code, "目录读取错误没有保留 Foundation 原始错误。")
        } else { throw BackgroundReadCancellationTestError.failed("缺失目录未返回错误。") }

        let separateEntered = DispatchSemaphore(value: 0)
        let separateRelease = DispatchSemaphore(value: 0)
        let separate = DirectoryBrowser(testHooks: .init(beforeEnumeration: { path in
            if path == old.path { separateEntered.signal(); _ = separateRelease.wait(timeout: .now() + 5) }
        }))
        var cancelledCallbacks = 0
        separate.load(path: old.path) { _ in cancelledCallbacks += 1 }
        try expect(separateEntered.wait(timeout: .now() + 2) == .success, "独立目录实例没有开始读取。")
        result = nil
        browser.load(path: latest.path) { result = $0 }
        try pump(until: { result != nil }, message: "一个目录实例的慢任务阻止另一栏读取。")
        try expect(try result!.get().count == 3, "独立目录实例互相取消或返回了错误结果。")
        separate.cancel()
        var afterCancel: Result<[DirectoryEntry], Error>?
        separate.load(path: latest.path) { afterCancel = $0 }
        separateRelease.signal()
        try pump(until: { afterCancel != nil }, message: "显式取消后目录服务不能继续使用。")
        try expect(cancelledCallbacks == 0 && (try afterCancel!.get().count) == 3, "显式取消仍回调旧结果，或新请求没有正常返回。")

        let teardownEntered = DispatchSemaphore(value: 0)
        let teardownRelease = DispatchSemaphore(value: 0)
        let teardownReturned = DispatchSemaphore(value: 0)
        let teardownReads = BackgroundReadCounters()
        var disappearingBrowser: DirectoryBrowser? = DirectoryBrowser(testHooks: .init(beforeEnumeration: { _ in
            teardownEntered.signal(); _ = teardownRelease.wait(timeout: .now() + 5); teardownReturned.signal()
        }, beforeEntryRead: { _ in _ = teardownReads.increment("entries") }))
        let weakBrowser = BackgroundReadWeakReference(disappearingBrowser)
        var teardownCallbacks = 0
        disappearingBrowser!.load(path: old.path) { _ in teardownCallbacks += 1 }
        try expect(teardownEntered.wait(timeout: .now() + 2) == .success, "目录销毁取消测试未进入读取。")
        disappearingBrowser = nil
        try expect(weakBrowser.value == nil, "旧目录任务保留了已销毁的目录服务。")
        teardownRelease.signal()
        try expect(teardownReturned.wait(timeout: .now() + 2) == .success, "目录销毁取消的读取入口未返回。")
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        try expect(teardownReads.value("entries") == 0 && teardownCallbacks == 0, "目录服务销毁后仍读取属性或返回结果。")
        return ["rapidSwitchRequests": 202, "intermediateEnumerations": 0,
                "obsoleteEntryReads": counters.value("old-entry"), "latestCallbacks": latestCallbacks,
                "callbacksOnMain": true, "hiddenAndSymlinkSemantics": true,
                "relativeAndFoundationErrorsPreserved": true, "deinitCancelsRead": true,
                "independentInstancesAndExplicitCancellation": true]
    }
}

import Foundation
import AppKit
import Darwin

/// Pause at the final progress notification, before the new root is committed.
/// The partial first index must survive shutdown; a reload must not silently
/// replace it with an empty snapshot just because calibration was cancelled.
enum ScannerStoreTests {
    static func run() throws -> [String: Any] {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("QuickFindScannerStore-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("文件"), data = fixture.appendingPathComponent("缓存")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        for number in 0..<40 {
            try Data("owned partial-index fixture".utf8).write(to: root.appendingPathComponent("暂停缓存文件\(number).txt"))
        }
        guard let physical = realpath(root.path, nil) else { throw EngineTestError.failed("暂停缓存fixture物理路径读取失败") }
        let physicalRoot = String(cString: physical); free(physical)
        let expected = Set((0..<40).map { physicalRoot + "/暂停缓存文件\($0).txt" })
        let record = IndexStore.makeRoot(path: root.path)
        guard record.path == physicalRoot else { throw EngineTestError.failed("索引根须与独立POSIX物理路径一致") }
        let store = IndexStore(dataDirectory: data, initialRoots: [record], watchesFilesystem: false)
        var shutDown = false
        defer { store.onUpdate = nil; if !shutDown { store.shutdown() } }
        let paused = CancellationFlag()
        store.onUpdate = { snapshot in
            if snapshot.isScanning && snapshot.scannedCount >= 5 && !paused.isCancelled {
                paused.cancel(); store.cancelScan()
            }
        }
        store.start()
        try wait("首次扫描暂停") { paused.isCancelled && !store.snapshot().isScanning }
        let beforeExit = Set(store.search(SearchRequest(query: "暂停缓存文件"), limit: 100).hits.map(\.path))
        guard !beforeExit.isEmpty, beforeExit.isSubset(of: expected), store.snapshot().roots.first?.lastUpdated == nil else {
            throw EngineTestError.failed("首次暂停必须有有效部分索引且不得宣称完成校准：hits=\(beforeExit.count), subset=\(beforeExit.isSubset(of: expected)), rootCount=\(store.snapshot().roots.first?.count ?? -1), lastUpdated=\(store.snapshot().roots.first?.lastUpdated != nil), state=\(store.snapshot().roots.first?.state ?? "")")
        }
        store.onUpdate = nil; store.shutdown(); shutDown = true
        let saved = try EngineIndex.load(from: data.appendingPathComponent(record.id + ".qfi"))
        let savedPaths = Set(saved.query(SearchRequest(query: "暂停缓存文件"), rootID: record.id, limit: 100).hits.map(\.path))
        guard savedPaths == beforeExit else { throw EngineTestError.failed("退出未保存首次暂停的索引") }

        let reload = IndexStore(dataDirectory: data, initialRoots: [record], watchesFilesystem: false)
        let cacheObserved = CancellationFlag()
        reload.onUpdate = { snapshot in
            if snapshot.roots.first?.count == saved.count && !snapshot.isScanning {
                cacheObserved.cancel(); reload.cancelScan()
            }
        }
        defer { reload.onUpdate = nil; reload.shutdown() }
        reload.start()
        try wait("重新读取暂停缓存") { cacheObserved.isCancelled }
        let loadedPaths = Set(reload.search(SearchRequest(query: "暂停缓存文件"), limit: 100).hits.map(\.path))
        guard loadedPaths == beforeExit, reload.snapshot().roots.first?.lastUpdated == nil else {
            throw EngineTestError.failed("重新启动必须保留已保存部分索引并保留校准未完成状态")
        }
        let candidates = try candidateStream()
        let events = try eventStorm()
        let volumes = try volumeEvents()
        return ["status": "passed", "volumeEvents": volumes, "candidateStreaming": candidates, "boundedEventStorm": events, "firstScanPauseRetainsNames": true,
                "shutdownPersistsPartialIndex": true, "reloadKeepsExactPaths": true,
                "partialDoesNotClaimCompletedCalibration": true, "retainedFileCount": beforeExit.count]
    }

    private static func candidateStream() throws -> [String: Any] {
        let fm = FileManager.default
        let fixture = try physicalFixture("QuickFindCandidateStream-")
        let root = fixture.appendingPathComponent("索引"), nested = root.appendingPathComponent("重叠目录")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        var expected = Set([root.path, nested.path])
        for number in 0..<2005 {
            let path = nested.appendingPathComponent("中文候选\(number).txt").path
            try emptyFile(path); expected.insert(path)
        }
        let rootOnly = root.appendingPathComponent("根目录文件.txt")
        try emptyFile(rootOnly.path); expected.insert(rootOnly.path)
        let parent = IndexStore.makeRoot(path: root.path), child = IndexStore.makeRoot(path: nested.path)
        let store = IndexStore(dataDirectory: fixture.appendingPathComponent("缓存"), initialRoots: [parent, child], watchesFilesystem: false)
        defer { store.onUpdate = nil; store.shutdown() }
        store.start()
        try wait("候选流初始真实扫描") {
            let s = store.snapshot()
            return !s.isScanning && s.roots.count == 2 && s.roots.allSatisfy { $0.lastUpdated != nil }
        }
        let request = SearchRequest(query: "")
        let baseline = store.search(request, limit: 10_000)
        guard Set(baseline.hits.map(\.path)) == expected && baseline.totalMatches == expected.count else {
            throw EngineTestError.failed("重叠根真实初始集合错误：total=\(baseline.totalMatches),hits=\(baseline.hits.count),expected=\(expected.count),missing=\(Array(expected.subtracting(Set(baseline.hits.map(\.path)))).prefix(8)),extra=\(Array(Set(baseline.hits.map(\.path)).subtracting(expected)).prefix(8)),roots=\(store.snapshot().roots.map { ($0.path, $0.count, $0.state) })")
        }
        var streamed: [FileHit] = [], chunks: [Int] = [], initialTotal = -1
        let full = store.forEachCandidate(request, chunkSize: Int.max, onStart: { initialTotal = $0 }) { hits in
            // Re-entering a query proves delivery does not retain an engine lock.
            _ = store.search(SearchRequest(query: "根目录文件"), limit: 2)
            streamed += hits; chunks.append(hits.count); return true
        }
        guard full.completed && full.totalCandidates == expected.count && initialTotal == expected.count
            && full.processedCandidates == expected.count && streamed == baseline.hits
            && chunks.count >= 2 && chunks.allSatisfy({ $0 <= 2000 }) else {
            throw EngineTestError.failed("固定chunk候选流必须同search顺序/计数且不重入死锁：chunks=\(chunks)")
        }
        var cappedCount = 0
        let capped = store.forEachCandidate(request, chunkSize: 3, maximumCandidates: 7) { cappedCount += $0.count; return true }
        guard !capped.completed && capped.totalCandidates == expected.count && cappedCount == 7 && capped.processedCandidates == 7 else {
            throw EngineTestError.failed("候选上限不得虚报完整或候选总数")
        }
        var stoppedCalls = 0
        let stopped = store.forEachCandidate(request, chunkSize: 2) { _ in stoppedCalls += 1; return false }
        guard !stopped.completed && stopped.processedCandidates == 2 && stoppedCalls == 1 else {
            throw EngineTestError.failed("candidate callback取消必须立即停止")
        }
        let cancellation = CancellationFlag()
        var cancelledRequest = request; cancelledRequest.cancellation = cancellation
        var cancelledCalls = 0
        let cancelled = store.forEachCandidate(cancelledRequest, onStart: { _ in cancellation.cancel() }) { _ in cancelledCalls += 1; return true }
        guard !cancelled.completed && cancelled.totalCandidates == expected.count && cancelled.processedCandidates == 0 && cancelledCalls == 0 else {
            throw EngineTestError.failed("candidate count后取消不得继续传递chunk")
        }
        let old = nested.appendingPathComponent("中文候选0.txt"), renamed = nested.appendingPathComponent("重命名新结果.txt")
        let created = nested.appendingPathComponent("count之后新增.txt")
        var updated = false, mutationError: Error?, snapshotPaths = Set<String>()
        let snapshot = store.forEachCandidate(request, chunkSize: 19, onStart: { _ in
            do {
                try fm.moveItem(at: old, to: renamed); try emptyFile(created.path)
                let completed = CancellationFlag()
                store.refreshChangedPaths([old.path, renamed.path, created.path]) { completed.cancel() }
                try wait("count与stream之间真实增量完成") { completed.isCancelled }
                updated = true
            } catch { mutationError = error }
        }) { hits in snapshotPaths.formUnion(hits.map(\.path)); return true }
        if let mutationError { throw mutationError }
        guard updated && snapshot.completed && snapshot.totalCandidates == expected.count && snapshotPaths == expected else {
            throw EngineTestError.failed("count/stream/重叠membership必须保持同snapshot，增量不能改变候选")
        }
        expected.remove(old.path); expected.insert(renamed.path); expected.insert(created.path)
        guard Set(store.search(request, limit: 10_000).hits.map(\.path)) == expected else {
            throw EngineTestError.failed("下一次查询必须看见真实增量")
        }
        var files = request; files.kind = .files; files.extensionFilter = "txt"
        var filePaths = Set<String>()
        let filtered = store.forEachCandidate(files, chunkSize: 31) { filePaths.formUnion($0.map(\.path)); return true }
        guard filtered.completed && filtered.totalCandidates == expected.count - 2 && filePaths == expected.subtracting([root.path, nested.path]) else {
            throw EngineTestError.failed("空查询流也必须保持类型及扩展名筛选")
        }
        let previousDate = store.snapshot().roots.first(where: { $0.id == parent.id })?.lastUpdated
        let outside = root.appendingPathComponent("校准新文件.txt")
        try fm.removeItem(at: rootOnly); try emptyFile(outside.path)
        let calibrationCancelled = CancellationFlag()
        store.onUpdate = { snapshot in
            if snapshot.isScanning && snapshot.scannedCount > 0 && !calibrationCancelled.isCancelled {
                calibrationCancelled.cancel(); store.cancelScan()
            }
        }
        store.refreshAll()
        try wait("保留旧缓存的校准取消") { calibrationCancelled.isCancelled && !store.snapshot().isScanning }
        guard Set(store.search(request, limit: 10_000).hits.map(\.path)) == expected
            && store.snapshot().roots.first(where: { $0.id == parent.id })?.lastUpdated == previousDate else {
            throw EngineTestError.failed("取消staging校准必须保留已发布旧缓存及完成时间")
        }
        store.onUpdate = nil
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: nested.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path) }
        var inaccessible = stat()
        let denied = lstat(renamed.path, &inaccessible), denial = errno
        guard denied == -1 && (denial == EACCES || denial == EPERM) else {
            throw EngineTestError.failed("缓存合并fixture必须独立验证实际权限拒绝")
        }
        store.refreshAll()
        try wait("受限子树校准保留cache") {
            let snapshot = store.snapshot()
            return !snapshot.isScanning && snapshot.issues.contains { $0.path == nested.path }
                && snapshot.roots.contains { $0.id == parent.id && $0.lastUpdated != previousDate }
        }
        expected.remove(rootOnly.path); expected.insert(outside.path)
        guard Set(store.search(request, limit: 10_000).hits.map(\.path)) == expected else {
            throw EngineTestError.failed("受限缓存合并须保留未知子项，同时提交可读范围的真实删除与新增")
        }
        return ["status": "passed", "fixtureFiles": 2006, "maximumObservedChunk": chunks.max() ?? 0,
                "countAndStreamSameSnapshot": true, "overlappingRootsDeduplicated": true,
                "callbackReentry": true, "limitAndCancellation": true,
                "cancelledCalibrationKeepsPublishedCache": true, "permissionUnknownRetainsCachedSubtree": true]
    }

    private static func eventStorm() throws -> [String: Any] {
        let fm = FileManager.default
        let fixture = try physicalFixture("QuickFindEventBound-")
        let root = fixture.appendingPathComponent("索引")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let old = root.appendingPathComponent("删除旧文件.txt"), renamed = root.appendingPathComponent("变化文件.txt")
        try emptyFile(old.path); try emptyFile(renamed.path)
        let store = IndexStore(dataDirectory: fixture.appendingPathComponent("缓存"), initialRoots: [IndexStore.makeRoot(path: root.path)], watchesFilesystem: false)
        let workerParked = DispatchSemaphore(value: 0), releaseWorker = DispatchSemaphore(value: 0)
        let finalParked = DispatchSemaphore(value: 0), releaseFinal = DispatchSemaphore(value: 0)
        defer {
            releaseWorker.signal(); releaseFinal.signal(); store.onUpdate = nil; store.shutdown()
        }
        store.start()
        try wait("event storm初次真实扫描") { !store.snapshot().isScanning && store.snapshot().roots.first?.lastUpdated != nil }
        store.refreshChangedPaths([]) { workerParked.signal(); _ = releaseWorker.wait(timeout: .now() + 20) }
        guard workerParked.wait(timeout: .now() + 2) == .success else { throw EngineTestError.failed("event worker fixture未能暂停") }
        let repeated = FileChange(path: renamed.path, flags: 0, requiresFullScan: false)
        store.enqueueChanges(Array(repeating: repeated, count: 20_000))
        let coalesced = store.eventBacklogSnapshot()
        guard coalesced.pendingPaths == 1 && coalesced.pendingRoots == 0 else { throw EngineTestError.failed("重复事件应只保留一个真实路径") }
        try wait("single dispatched batch") { store.eventBacklogSnapshot().inFlight }
        try fm.removeItem(at: old)
        let overflowCount = IndexStore.maximumPendingEventPaths + 1
        var expected = Set([root.path, renamed.path]), hints: [FileChange] = []
        for number in 0..<overflowCount {
            let path = root.appendingPathComponent("风暴新建\(number).txt").path
            try emptyFile(path); expected.insert(path)
            hints.append(FileChange(path: path, flags: 0, requiresFullScan: false))
        }
        hints.append(FileChange(path: old.path, flags: 0, requiresFullScan: false))
        store.enqueueChanges(hints)
        let bounded = store.eventBacklogSnapshot()
        guard bounded.inFlight && bounded.pendingPaths <= IndexStore.maximumPendingEventPaths && bounded.pendingRoots == 1 else {
            throw EngineTestError.failed("忙碌worker前事件必须有界并明确升级受影响root校准：\(bounded)")
        }
        let finalSeen = CancellationFlag()
        let capturedCount = expected.count
        var finalOccurrences = 0
        store.onUpdate = { snapshot in
            if snapshot.isScanning && snapshot.scannedCount == capturedCount && !finalSeen.isCancelled {
                finalOccurrences += 1
                // Raw walk's final progress and the parent's final report each
                // notify. The second occurrence is after directory enumeration.
                guard finalOccurrences >= 2 else { return }
                finalSeen.cancel(); finalParked.signal(); _ = releaseFinal.wait(timeout: .now() + 20)
            }
        }
        releaseWorker.signal()
        guard finalParked.wait(timeout: .now() + 15) == .success else { throw EngineTestError.failed("事件降级校准未到真实最后进度") }
        // This name arrives after enumeration, while commit is still parked.
        // A queued calibration must not erase or swallow the following hint.
        let late = root.appendingPathComponent("扫描结束后新建.txt")
        try emptyFile(late.path); expected.insert(late.path)
        store.enqueueChanges([FileChange(path: late.path, flags: 0, requiresFullScan: false)])
        let duringCommit = store.eventBacklogSnapshot()
        guard duringCommit.inFlight && duringCommit.pendingPaths == 1 else { throw EngineTestError.failed("扫描提交期间后续变更必须独立排队") }
        releaseFinal.signal()
        try wait("校准和迟到delta全部完成") {
            let backlog = store.eventBacklogSnapshot()
            return !backlog.inFlight && backlog.pendingPaths == 0 && backlog.pendingRoots == 0
                && !store.snapshot().isScanning && store.search(SearchRequest(query: "扫描结束后新建"), limit: 2).totalMatches == 1
        }
        let actual = store.search(SearchRequest(query: ""), limit: 10_000)
        guard actual.totalMatches == expected.count && Set(actual.hits.map(\.path)) == expected else {
            throw EngineTestError.failed("事件合并/校准不得丢创建/删除/校准结束后增量：actual=\(actual.totalMatches),expected=\(expected.count)")
        }
        return ["status": "passed", "repeatedHints": 20_000, "uniquePhysicalCreations": overflowCount,
                "pendingPathLimit": IndexStore.maximumPendingEventPaths, "oneInFlightBatch": true,
                "overflowCalibratesAffectedRoot": true, "lateUpdateSurvivesCalibrationCommit": true]
    }

    private static func volumeEvents() throws -> [String: Any] {
        let fm = FileManager.default
        let fixture = try physicalFixture("QuickFindVolumeEvent-")
        let volumeA = fixture.appendingPathComponent("自有卷A"), volumeB = fixture.appendingPathComponent("自有卷B")
        let scopeA = volumeA.appendingPathComponent("只索引这层"), scopeB = volumeB.appendingPathComponent("另一个已配置范围")
        let unrelated = fixture.appendingPathComponent("无关安装镜像"), newVolume = fixture.appendingPathComponent("新本地卷")
        let data = fixture.appendingPathComponent("缓存")
        for url in [scopeA, scopeB, unrelated, newVolume, data] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: fixture) }
        let oldA = scopeA.appendingPathComponent("原A.txt"), newA = scopeA.appendingPathComponent("改名A.txt")
        let oldB = scopeB.appendingPathComponent("原B.txt"), unscannedB = scopeB.appendingPathComponent("无关卷不应重扫.txt")
        try emptyFile(oldA.path); try emptyFile(oldB.path)
        let recordA = IndexStore.makeRoot(path: scopeA.path), recordB = IndexStore.makeRoot(path: scopeB.path)
        let configured = [recordA, recordB]
        let config = data.appendingPathComponent("roots.json")
        let originalConfig = try JSONEncoder().encode(configured)
        try originalConfig.write(to: config)
        // Load an ordinary persisted custom scope. No QA identity or runtime
        // override is used to protect the selected roots.
        let store = IndexStore(dataDirectory: data, watchesFilesystem: false)
        let scopeEscaped = CancellationFlag()
        var scannedRoots = Set<String>()
        store.onUpdate = { snapshot in
            if snapshot.roots.contains(where: { ![recordA.id, recordB.id].contains($0.id) }) {
                scopeEscaped.cancel(); store.cancelScan()
            }
            if snapshot.isScanning { scannedRoots.formUnion(snapshot.roots.filter { $0.state == "扫描中" }.map(\.id)) }
        }
        defer { store.onUpdate = nil; store.shutdown() }
        store.start()
        try wait("自选scope初始扫描") { let snapshot = store.snapshot(); return !snapshot.isScanning && snapshot.roots.count == 2 && snapshot.roots.allSatisfy { $0.lastUpdated != nil } }
        let initial = store.snapshot()
        let initialA = initial.roots.first { $0.id == recordA.id }!, initialB = initial.roots.first { $0.id == recordB.id }!
        let baseline = Set([scopeA.path, scopeB.path, oldA.path, oldB.path])
        guard initial.roots.count == 2 && Set(store.search(SearchRequest(query: ""), limit: 100).hits.map(\.path)) == baseline else {
            throw EngineTestError.failed("mount fixture初始配置和物理名称集合须准确")
        }
        func finishQueuedEvents() throws {
            let completed = DispatchSemaphore(value: 0)
            store.refreshChangedPaths([]) { completed.signal() }
            guard completed.wait(timeout: .now() + 8) == .success else { throw EngineTestError.failed("volume event worker未完成") }
        }
        func send(_ url: URL, mounted: Bool, eligibility: @escaping (URL) -> Bool) throws {
            let completed = DispatchSemaphore(value: 0)
            store.handleVolumeEvent(at: url, mounted: mounted, eligibility: eligibility) { completed.signal() }
            guard completed.wait(timeout: .now() + 8) == .success else { throw EngineTestError.failed("注入volume event未完成") }
        }
        scannedRoots.removeAll()
        try emptyFile(unscannedB.path)
        var eligibilityCalls = 0
        try send(unrelated, mounted: true, eligibility: { _ in eligibilityCalls += 1; return true })
        let persistedAfterUnrelated = try Data(contentsOf: config)
        guard eligibilityCalls == 0 && scannedRoots.isEmpty && !scopeEscaped.isCancelled
            && store.snapshot().searchRevision == initial.searchRevision && store.snapshot().roots == initial.roots
            && persistedAfterUnrelated == originalConfig else {
            throw EngineTestError.failed("自选scope无关挂载不能查询自动发现、增加root、扫描或改持久化配置")
        }
        // Exercise the actual observer's URL decoding and missing-URL branch.
        // These are simulated notifications about owned fixture directories,
        // not a claim of physically mounting/unmounting a volume.
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.didMountNotification, object: nil,
                    userInfo: [NSWorkspace.volumeURLUserInfoKey: unrelated])
        center.post(name: NSWorkspace.didUnmountNotification, object: nil,
                    userInfo: [NSWorkspace.volumeURLUserInfoKey: unrelated])
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        try finishQueuedEvents()
        guard scannedRoots.isEmpty && store.snapshot().roots == initial.roots && !scopeEscaped.isCancelled else {
            throw EngineTestError.failed("真实observer无关或无URL通知不得扩大scope或重扫")
        }
        let detached = fixture.appendingPathComponent("卷A移出")
        try fm.moveItem(at: volumeA, to: detached)
        center.post(name: NSWorkspace.didUnmountNotification, object: nil,
                    userInfo: [NSWorkspace.volumeURLUserInfoKey: volumeA])
        try finishQueuedEvents()
        let disconnected = store.snapshot()
        guard disconnected.roots.first(where: { $0.id == recordA.id })?.isOnline == false
            && disconnected.roots.first(where: { $0.id == recordB.id }) == initialB && scannedRoots.isEmpty
            && Set(store.search(SearchRequest(query: ""), limit: 100).hits.map(\.path)) == baseline else {
            throw EngineTestError.failed("配置卷断开只更新其状态、保留缓存且不扫描其它scope")
        }
        let movedScope = detached.appendingPathComponent(scopeA.lastPathComponent)
        try fm.moveItem(at: movedScope.appendingPathComponent(oldA.lastPathComponent),
                        to: movedScope.appendingPathComponent(newA.lastPathComponent))
        try fm.moveItem(at: detached, to: volumeA)
        center.post(name: NSWorkspace.didMountNotification, object: nil,
                    userInfo: [NSWorkspace.volumeURLUserInfoKey: volumeA])
        try finishQueuedEvents()
        let reconnected = store.snapshot()
        let expected = Set([scopeA.path, scopeB.path, newA.path, oldB.path])
        let persistedAfterReconnect = try Data(contentsOf: config)
        guard !scopeEscaped.isCancelled && scannedRoots == [recordA.id]
            && reconnected.roots.first(where: { $0.id == recordA.id })?.isOnline == true
            && reconnected.roots.first(where: { $0.id == recordA.id })?.lastUpdated != initialA.lastUpdated
            && reconnected.roots.first(where: { $0.id == recordB.id }) == initialB
            && Set(store.search(SearchRequest(query: ""), limit: 100).hits.map(\.path)) == expected
            && store.search(SearchRequest(query: unscannedB.lastPathComponent)).totalMatches == 0
            && persistedAfterReconnect == originalConfig else {
            throw EngineTestError.failed("重连只校准该卷内已配置范围，不顺便收录其它卷新增名称或扩大索引")
        }

        // Plan-only whole-disk policy checks. Never start a store containing '/'
        // or read/scan that root in this test; all URL inputs are owned fixtures.
        let whole = RootRecord(id: "plan-only-system", path: "/", name: "不扫描的计划根", volumeID: "")
        let positive = IndexStore.planVolumeEvent(roots: [whole] + configured, at: newVolume, mounted: true,
                                                eligibility: { $0 == newVolume })
        guard positive.shouldDiscover && positive.affectedRootIDs.isEmpty else {
            throw EngineTestError.failed("wholeDisk新eligible卷应仅计划发现新卷，不能校准已有内置/其它根")
        }
        let readOnly = IndexStore.planVolumeEvent(roots: [whole] + configured, at: unrelated, mounted: true,
            eligibility: { _ in IndexStore.eligibleVolumeProperties(local: true, browsable: true, readOnly: true) })
        guard !readOnly.shouldDiscover && readOnly.affectedRootIDs.isEmpty
            && IndexStore.eligibleVolumeProperties(local: true, browsable: true, readOnly: false)
            && !IndexStore.eligibleVolumeProperties(local: false, browsable: true, readOnly: false)
            && !IndexStore.eligibleVolumeProperties(local: true, browsable: false, readOnly: false)
            && !IndexStore.eligibleVolumeProperties(local: nil, browsable: true, readOnly: false)
            && !IndexStore.eligibleVolumeProperties(local: true, browsable: true, readOnly: nil)
            && !IndexStore.isAutoDiscoverableVolume(scopeA) else {
            throw EngineTestError.failed("只读镜像、非本地、不可浏览、未知属性和普通子目录不能自动发现")
        }
        let existing = IndexStore.makeRoot(path: newVolume.path)
        let duplicate = IndexStore.planVolumeEvent(roots: [whole, existing], at: newVolume, mounted: true,
                                                  discoveredRootID: existing.id, eligibility: { _ in true })
        let oldIdentity = RootRecord(id: "plan-volume-uuid-a", path: newVolume.path, name: "旧同名卷", volumeID: "UUID-A")
        let reusedMountPoint = IndexStore.planVolumeEvent(roots: [whole, oldIdentity], at: newVolume, mounted: true,
                                                         discoveredRootID: "plan-volume-uuid-b", eligibility: { _ in true })
        guard reusedMountPoint.shouldDiscover && reusedMountPoint.affectedRootIDs == [oldIdentity.id] else {
            throw EngineTestError.failed("同挂载点新UUID必须允许发现新身份，不能按路径挡住替换卷")
        }
        let detachPlan = IndexStore.planVolumeEvent(roots: [whole] + configured, at: volumeA, mounted: false,
                                                   eligibility: { _ in true })
        let boundary = IndexStore.planVolumeEvent(roots: configured, at: URL(fileURLWithPath: volumeA.path + "同名前缀"), mounted: true,
                                                 eligibility: { _ in true })
        guard !duplicate.shouldDiscover && duplicate.affectedRootIDs == [existing.id]
            && !detachPlan.shouldDiscover && detachPlan.affectedRootIDs == [recordA.id]
            && !boundary.shouldDiscover && boundary.affectedRootIDs.isEmpty else {
            throw EngineTestError.failed("卷事件计划须保留去重、卸载和目录边界")
        }
        return ["status": "passed", "ordinaryPersistedCustomScope": true, "unrelatedMountDoesNotExpandScope": true,
                "observerRequiresNotificationURL": true, "disconnectKeepsCache": true,
                "reconnectCalibratesAffectedRootOnly": true, "wholeDiskNewEligibleVolumePlan": true,
                "sameMountPathDifferentVolumeIdentity": true,
                "readOnlyNonlocalUnbrowsableUnknownRejected": true, "wholeDiskRootNeverScanned": true,
                "physicalMountUnmount": "not tested; owned directories and injected notification URLs"]
    }

    private static func physicalFixture(_ prefix: String) throws -> URL {
        let logical = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: logical, withIntermediateDirectories: false)
        guard let path = realpath(logical.path, nil) else {
            try? FileManager.default.removeItem(at: logical)
            throw EngineTestError.failed("owned fixture realpath失败")
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    private static func emptyFile(_ path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw EngineTestError.failed("owned fixture创建失败：\(path) errno=\(errno)") }
        close(fd)
    }

    private static func wait(_ label: String, _ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        throw EngineTestError.failed("扫描缓存回归超时：" + label)
    }
}

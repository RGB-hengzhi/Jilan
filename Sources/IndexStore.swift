import Foundation
import CryptoKit
import AppKit
import Darwin
import CoreServices

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct StoreSnapshot {
    var searchRevision: UInt64
    var roots: [RootStatus]
    var isScanning: Bool
    var scannedCount: Int
    var issues: [ScanIssue]
    var message: String
    /// Content/attribute hints invalidate metadata independently of the name
    /// index. nil means the path budget was exceeded and all metadata is stale.
    var metadataRevision: UInt64 = 0
    var changedMetadataPaths: [String]? = nil
}

private struct RootMetadata: Codable {
    var lastUpdated: Date?
    var issueCount: Int
    var issues: [ScanIssue]
}

final class IndexStore: @unchecked Sendable {
    let dataDirectory: URL
    var onUpdate: ((StoreSnapshot) -> Void)?
    private let lock = NSRecursiveLock()
    private let worker = DispatchQueue(label: "cn.local.quickfind.index", qos: .utility)
    private let eventsQueue = DispatchQueue(label: "cn.local.quickfind.events", qos: .utility)
    private let watcherQueue = DispatchQueue(label: "cn.local.quickfind.watcher-preparation", qos: .utility)
    private var records: [RootRecord] = []
    private var engines: [String: EngineIndex] = [:]
    private var statuses: [String: RootStatus] = [:]
    private var rootIssues: [String: [ScanIssue]] = [:]
    private var scanning = false
    private var progressCount = 0
    // Progress and watcher notices do not change searchable data. Advance this
    // only when a published engine, root set or online status changes.
    private var searchRevision: UInt64 = 0
    private var metadataRevision: UInt64 = 0
    private var changedMetadataPaths: [String]? = nil
    static let maximumChangedMetadataPaths = 2000
    private var message = "正在载入本地索引…"
    private var token = CancellationFlag()
    private var watcher: FileWatcher?
    private var watcherToken = CancellationFlag()
    // The index worker can be busy calibrating a large root. Keep at most one
    // dispatched batch and one bounded, coalesced batch in front of it.
    static let maximumPendingEventPaths = 5000
    private var pendingEvents: [String: FileChange] = [:]
    private var pendingCalibrations: [String: String] = [:]
    private var eventWork: DispatchWorkItem?
    private var eventDrainInFlight = false
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private let lifecycle = CancellationFlag()
    private var stopped: Bool { lifecycle.isCancelled }
    private var dirtyRoots = Set<String>()
    private var persistenceTimer: DispatchSourceTimer?
    private var servicesInstalled = false
    private static let workerKey = DispatchSpecificKey<Bool>()
    private let initialRoots: [RootRecord]?
    private let watchesFilesystem: Bool

    init(dataDirectory: URL? = nil, initialRoots: [RootRecord]? = nil, watchesFilesystem: Bool = true) {
        self.dataDirectory = dataDirectory ?? RuntimePaths.dataDirectory
        self.initialRoots = initialRoots
        self.watchesFilesystem = watchesFilesystem
        worker.setSpecific(key: Self.workerKey, value: true)
    }

    static func volumeID(for path: String) -> String {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? ""
    }

    static func makeRoot(path: String, name: String? = nil) -> RootRecord {
        let lexical = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardized.path
        let normalized: String
        if let resolved = realpath(lexical, nil) { normalized = String(cString: resolved); free(resolved) }
        else { normalized = lexical }
        let volume = volumeID(for: normalized)
        let digest = SHA256.hash(data: Data((normalized + "\n" + volume).utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let label = name ?? (normalized == "/" ? "内置硬盘" : (normalized as NSString).lastPathComponent)
        return RootRecord(id: digest, path: normalized, name: label, volumeID: volume)
    }

    static func wholeDisks() -> [RootRecord] {
        var roots = [makeRoot(path: "/", name: "内置硬盘")]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey, .volumeURLKey],
            options: [.skipHiddenVolumes]) ?? []
        for url in urls where isAutoDiscoverableVolume(url) {
            roots.append(makeRoot(path: url.path))
        }
        return roots
    }

    /// Retain the first record and its display order. Canonical paths can make
    /// two selections (for example a folder and its symlink) share one ID.
    private static func uniqueRoots(_ roots: [RootRecord]) -> [RootRecord] {
        var seen = Set<String>()
        return roots.filter { seen.insert($0.id).inserted }
    }

    func start() {
        worker.async { [weak self] in self?.loadAndStart() }
    }

    private func loadAndStart() {
        guard !stopped else { return }
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let config = dataDirectory.appendingPathComponent("roots.json")
            if let initialRoots { lock.lock(); records = Self.uniqueRoots(initialRoots); lock.unlock() }
            else if FileManager.default.fileExists(atPath: config.path) {
                do {
                    let loaded = try JSONDecoder().decode([RootRecord].self, from: Data(contentsOf: config))
                    lock.lock(); records = Self.uniqueRoots(loaded); lock.unlock()
                }
                catch {
                    setMessage("索引位置配置读取失败。旧索引已保留，请重新添加位置。")
                    ensureServices(); publish(); return
                }
            } else {
                lock.lock(); records = Self.uniqueRoots(Self.wholeDisks()); lock.unlock()
                try writeConfig()
            }
            for record in records {
                var status = RootStatus(record: record)
                status.isOnline = isOnline(record)
                status.state = status.isOnline ? "等待校准" : "磁盘离线"
                if let meta = try? JSONDecoder().decode(RootMetadata.self,
                    from: Data(contentsOf: metadataURL(record.id))) {
                    status.lastUpdated = meta.lastUpdated
                    status.issueCount = meta.issueCount
                    lock.lock(); rootIssues[record.id] = meta.issues; lock.unlock()
                }
                if FileManager.default.fileExists(atPath: indexURL(record.id).path) {
                    do {
                        let engine = try EngineIndex.load(from: indexURL(record.id))
                        lock.lock(); engines[record.id] = engine; lock.unlock()
                        status.count = engine.count
                    } catch {
                        status.state = "缓存损坏，等待重建"
                        lock.lock(); rootIssues[record.id] = [ScanIssue(path: indexURL(record.id).path,
                            message: "缓存校验未通过，将重新扫描；原文件未改动。")]
                        lock.unlock()
                    }
                }
                lock.lock(); statuses[record.id] = status; searchRevision &+= 1; lock.unlock()
                publish()
            }
            setMessage("已载入缓存，正在校准实际文件；离线磁盘显示上次索引。")
            restartWatcher()
            ensureServices()
            lock.lock(); let startupTargets = records.filter { isOnline($0) }; let startupToken = token; lock.unlock()
            scan(startupTargets, token: startupToken)
        } catch {
            setMessage("无法建立索引目录：\(error.localizedDescription)")
            publish()
        }
    }

    func snapshot() -> StoreSnapshot {
        lock.lock(); defer { lock.unlock() }
        return StoreSnapshot(searchRevision: searchRevision, roots: records.compactMap { statuses[$0.id] }, isScanning: scanning,
            scannedCount: progressCount, issues: records.flatMap { rootIssues[$0.id] ?? [] } + (rootIssues["watcher"] ?? []), message: message,
            metadataRevision: metadataRevision, changedMetadataPaths: changedMetadataPaths)
    }

    private func publish() { onUpdate?(snapshot()) }
    private func setMessage(_ value: String) { lock.lock(); message = value; lock.unlock() }
    private func indexURL(_ id: String) -> URL { dataDirectory.appendingPathComponent(id + ".qfi") }
    private func metadataURL(_ id: String) -> URL { dataDirectory.appendingPathComponent(id + ".json") }

    private func isOnline(_ record: RootRecord) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: record.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        if record.path == "/" { return true }
        let currentID = Self.volumeID(for: record.path)
        return record.volumeID.isEmpty || currentID == record.volumeID
    }

    private func exclusions(for record: RootRecord) -> [String] {
        var result = [dataDirectory.path]
        if record.path == "/" { result += ["/dev", "/Volumes", "/System/Volumes", "/Network"] }
        return result
    }

    private func writeConfig() throws {
        let config = dataDirectory.appendingPathComponent("roots.json")
        if FileManager.default.fileExists(atPath: config.path) {
            let backup = dataDirectory.appendingPathComponent("roots.previous.json")
            let data = try Data(contentsOf: config)
            try data.write(to: backup, options: .atomic)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        lock.lock(); let roots = records; lock.unlock()
        try encoder.encode(roots).write(to: config, options: .atomic)
    }

    private func save(_ record: RootRecord, engine: EngineIndex, status: RootStatus, issues: [ScanIssue]) throws {
        try engine.save(to: indexURL(record.id))
        let meta = RootMetadata(lastUpdated: status.lastUpdated, issueCount: status.issueCount, issues: issues)
        try JSONEncoder().encode(meta).write(to: metadataURL(record.id), options: .atomic)
    }

    private func scan(_ targets: [RootRecord], token scanToken: CancellationFlag) {
        guard !scanToken.isCancelled, !stopped else { return }
        lock.lock(); scanning = true; progressCount = 0; lock.unlock(); publish()
        var processed = 0
        var interrupted = false
        for record in targets {
            guard !scanToken.isCancelled, !stopped else { break }
            guard isOnline(record) else {
                lock.lock()
                if statuses[record.id]?.isOnline != false { searchRevision &+= 1 }
                statuses[record.id]?.isOnline = false; statuses[record.id]?.state = "磁盘离线"; lock.unlock()
                continue
            }
            let engine = EngineIndex()
            lock.lock()
            let previous = engines[record.id]
            if previous == nil { engines[record.id] = engine; searchRevision &+= 1 }
            if statuses[record.id]?.isOnline != true { searchRevision &+= 1 }
            statuses[record.id]?.state = "扫描中"
            statuses[record.id]?.isOnline = true
            lock.unlock()
            if let previous { engine.reserveCapacity(previous.count) }
            publish()
            let report = FileScanner.scan(path: record.path, excludedPrefixes: exclusions(for: record),
                cancelled: { scanToken.isCancelled || self.stopped },
                onEntry: { _, _ in },
                onProgress: { count, path in
                    self.lock.lock(); self.progressCount = processed + count
                    if previous == nil {
                        if self.statuses[record.id]?.count != count { self.searchRevision &+= 1 }
                        self.statuses[record.id]?.count = count
                    }
                    self.message = "扫描 \(record.name)：\(path)"
                    self.lock.unlock(); self.publish()
                }, indexEntry: { path, isDir in
                    Self.acceptScannedEntry(path, directory: isDir, into: engine)
                })
            processed += report.count
            if !report.completed && !scanToken.isCancelled { interrupted = true }
            var completed = report.completed && !scanToken.isCancelled && !stopped
            if let previous, completed, report.totalIssueCount > 0,
               report.count > 1, isOnline(record) {
                let inaccessible = PathCoverage(report.issues.map(\.path))
                // If issue details were capped, their unknown subtrees must
                // remain conservatively searchable from the previous index.
                let retainAllMissing = report.totalIssueCount > report.issues.count
                completed = previous.forEachPathWhile { path, isDir in
                    guard !scanToken.isCancelled, !self.stopped else { return false }
                    if retainAllMissing || inaccessible.contains(path) {
                        // Fresh scan entries (including changed file types)
                        // always take priority over cached entries.
                        if !engine.hasPath(path) && !Self.hasFileAncestor(path, in: engine) {
                            engine.add(path: path, isDirectory: isDir)
                        }
                    }
                    return true
                }
            }
            lock.lock()
            completed = completed && !scanToken.isCancelled && !stopped
            if completed && isOnline(record) && !(report.count <= 1 && report.totalIssueCount > 0) {
                engines[record.id] = engine
                statuses[record.id]?.count = engine.count
                statuses[record.id]?.lastUpdated = Date()
                statuses[record.id]?.issueCount = report.totalIssueCount
                statuses[record.id]?.state = report.totalIssueCount > 0 ? "就绪（部分位置受限）" : "就绪"
                rootIssues[record.id] = report.issues
                let status = statuses[record.id]!
                lock.unlock()
                do { try save(record, engine: engine, status: status, issues: report.issues) }
                catch {
                    lock.lock(); statuses[record.id]?.state = "可搜索，缓存保存失败"
                    rootIssues[record.id, default: []].append(ScanIssue(path: dataDirectory.path, message: error.localizedDescription))
                    lock.unlock()
                }
            } else {
                if let previous { engines[record.id] = previous }
                statuses[record.id]?.count = engines[record.id]?.count ?? 0
                let online = isOnline(record)
                statuses[record.id]?.isOnline = online
                statuses[record.id]?.state = !online ? "磁盘离线" : completed ? "访问受限（保留旧索引）"
                    : scanToken.isCancelled ? "扫描已暂停" : "扫描未完成（保留索引）"
                statuses[record.id]?.issueCount = report.totalIssueCount
                rootIssues[record.id] = report.issues
                // A first scan can already contain useful names when it is
                // stopped. Persist that partial index, with its issues and the
                // original lastUpdated value, rather than losing it at exit.
                if previous == nil && (engines[record.id]?.count ?? 0) > 1 { dirtyRoots.insert(record.id) }
                lock.unlock()
            }
            lock.lock(); searchRevision &+= 1; lock.unlock()
            publish()
        }
        lock.lock(); scanning = false; progressCount = processed
        if scanToken.isCancelled { message = "扫描已暂停。已完成的索引仍可搜索，点击重新扫描可继续校准。" }
        else if interrupted { message = "本次校准未完整结束，已保留索引。请查看未覆盖路径并重新扫描。" }
        else { message = "索引已就绪。未获权限的位置请查看扫描问题；离线结果来自上次索引。" }
        lock.unlock(); publish()
    }

    private static func hasFileAncestor(_ path: String, in engine: EngineIndex) -> Bool {
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            if engine.pathIsDirectory(parent) == false { return true }
            if parent == "/" { break }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return false
    }

    private static func acceptScannedEntry(_ path: String, directory: Bool, into engine: EngineIndex) -> (changed: Bool, count: Int) {
        // A retry can observe a directory now replaced by a file/link. Remove
        // its previously staged descendants; the old published index stays safe.
        if !directory && engine.pathIsDirectory(path) == true { engine.removeSubtree(path: path) }
        let changed = engine.add(path: path, isDirectory: directory)
        return (changed, engine.count)
    }

    func refreshAll() {
        lock.lock(); token.cancel(); token = CancellationFlag(); let next = token; lock.unlock()
        worker.async { [weak self] in
            guard let self, !next.isCancelled else { return }
            self.updateOnlineStatuses(); self.restartWatcher()
            self.lock.lock(); let targets = self.records.filter { self.isOnline($0) }; self.lock.unlock()
            self.scan(targets, token: next)
        }
    }

    func cancelScan() { lock.lock(); token.cancel(); lock.unlock() }

    func addRoots(_ newRecords: [RootRecord]) {
        worker.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.lock.lock()
            let existingIDs = Set(self.records.map(\.id))
            let additions = Self.uniqueRoots(newRecords).filter { !existingIDs.contains($0.id) }
            for record in additions {
                self.records.append(record)
                self.statuses[record.id] = RootStatus(record: record)
            }
            if !additions.isEmpty { self.searchRevision &+= 1 }
            self.lock.unlock()
            do { try self.writeConfig() }
            catch { self.setMessage("位置配置保存失败：\(error.localizedDescription)"); self.publish(); return }
            self.restartWatcher(); self.publish()
            self.lock.lock(); let scanToken = self.token.isCancelled ? CancellationFlag() : self.token; self.token = scanToken; self.lock.unlock()
            self.scan(additions.filter { self.isOnline($0) }, token: scanToken)
        }
    }

    func removeRoot(id: String) {
        cancelScan()
        worker.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.lock.lock(); self.records.removeAll { $0.id == id }
            self.engines[id] = nil; self.statuses[id] = nil; self.rootIssues[id] = nil
            self.searchRevision &+= 1
            if self.token.isCancelled { self.token = CancellationFlag() }; self.lock.unlock()
            // Removing a location never touches its files. The old cache remains recoverable.
            do { try self.writeConfig() }
            catch { self.setMessage("位置配置保存失败：\(error.localizedDescription)") }
            self.restartWatcher(); self.publish()
        }
    }

    private func covers(_ ancestor: RootRecord, _ descendant: RootRecord) -> Bool {
        let nested = descendant.path == ancestor.path || descendant.path.hasPrefix(ancestor.path == "/" ? "/" : ancestor.path + "/")
        guard nested else { return false }
        return !exclusions(for: ancestor).contains { descendant.path == $0 || descendant.path.hasPrefix($0 + "/") }
    }

    private func querySources(_ request: SearchRequest) -> [(RootRecord, EngineIndex, Bool)] {
        lock.lock()
        let candidates = Self.uniqueRoots(records).filter { record in
            guard request.rootID == nil || record.id == request.rootID else { return false }
            let online = statuses[record.id]?.isOnline == true
            if request.filters.connection == .online && !online { return false }
            if request.filters.connection == .offline && online { return false }
            if request.rootID == nil, statuses[record.id]?.isOnline != true {
                return request.filters.connection == .offline || !records.contains { $0.id != record.id && $0.path == record.path && statuses[$0.id]?.isOnline == true }
            }
            return true
        }
        let sources = candidates.sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return $0.id < $1.id
        }.compactMap { record -> (RootRecord, EngineIndex, Bool)? in
            guard let engine = engines[record.id] else { return nil }
            return (record, engine, statuses[record.id]?.isOnline ?? false)
        }
        lock.unlock()
        return sources
    }

    struct CandidateStreamResult {
        let totalCandidates: Int
        let processedCandidates: Int
        let completed: Bool
        let elapsedMilliseconds: Double
    }

    /// Counts and streams the same immutable index snapshots. At most 2,000
    /// candidate hits exist in the stream at once; metadata work runs without
    /// holding an index lock. Narrower-root membership also uses its captured
    /// snapshot so a concurrent file update cannot change duplicate accounting.
    func forEachCandidate(_ request: SearchRequest, chunkSize: Int = 2000,
                          maximumCandidates: Int = Int.max,
                          onStart: ((Int) -> Void)? = nil,
                          onChunk: ([FileHit]) -> Bool) -> CandidateStreamResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let sources = querySources(request)
        var snapshots: [(RootRecord, SearchEngine.QueryCursor, Bool)] = []
        for (record, engine, online) in sources {
            let overlap = snapshots.filter { covers(record, $0.0) }.map { $0.1 }
            let cursor = engine.makeQueryCursor(request, rootID: record.id,
                excludeHit: overlap.isEmpty ? nil : { path in overlap.contains { $0.hasPath(path) } })
            snapshots.append((record, cursor, online))
        }
        var total = 0, processed = 0
        func result(_ completed: Bool) -> CandidateStreamResult {
            CandidateStreamResult(totalCandidates: total, processedCandidates: processed, completed: completed,
                elapsedMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        for (_, cursor, _) in snapshots {
            guard request.cancellation?.isCancelled != true else { return result(false) }
            total += cursor.countCandidates()
        }
        guard request.cancellation?.isCancelled != true else { return result(false) }
        onStart?(total)
        let size = max(1, min(2000, chunkSize)), maximum = max(0, maximumCandidates)
        for (_, cursor, online) in snapshots {
            while processed < maximum && !cursor.isComplete {
                guard request.cancellation?.isCancelled != true else { return result(false) }
                var hits = cursor.next(maximum: min(size, maximum - processed))
                guard request.cancellation?.isCancelled != true else { return result(false) }
                guard !hits.isEmpty else { break }
                for index in hits.indices { hits[index].isOnline = online }
                processed += hits.count
                guard onChunk(hits) else { return result(false) }
            }
            if processed >= maximum { break }
        }
        return result(request.cancellation?.isCancelled != true && processed == total)
    }

    func search(_ request: SearchRequest, limit: Int = 2000) -> SearchBatch {
        let start = DispatchTime.now().uptimeNanoseconds
        let sources = querySources(request)
        var hits: [FileHit] = [], total = 0
        var previous: [(RootRecord, EngineIndex)] = []
        for (record, engine, online) in sources {
            let overlapping = previous.filter { covers(record, $0.0) }.map { $0.1 }
            let response = engine.query(request, rootID: record.id, limit: max(0, limit - hits.count),
                excludeHit: overlapping.isEmpty ? nil : { path in overlapping.contains { $0.hasPath(path) } })
            total += response.totalMatches
            hits += response.hits.map { hit in var h = hit; h.isOnline = online; return h }
            previous.append((record, engine))
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        return SearchBatch(hits: hits, totalMatches: total, elapsedMilliseconds: milliseconds)
    }

    /// Completed app operations are authoritative change hints. ExFAT can move
    /// AppleDouble metadata without a deletion event for the old ._ filename.
    /// Check only known paths and their metadata neighbors, never their whole
    /// parent directory. applyChanges retains inaccessible entries and removes
    /// only paths whose lstat reports ENOENT/ENOTDIR.
    func refreshChangedPaths(_ paths: [String], completion: (() -> Void)? = nil) {
        worker.async { [weak self] in
            guard let self, !self.stopped else { completion?(); return }
            var changed = Set<String>()
            for path in paths where path.hasPrefix("/") {
                let url = URL(fileURLWithPath: path).standardized
                guard url.path != "/" else { continue }
                // Resolve the parent rather than the full path: a removed source
                // still needs its original basename, including case-only renames.
                let parent = Self.actualSpelling(of: url.deletingLastPathComponent().path)
                let physical = (parent as NSString).appendingPathComponent(url.lastPathComponent)
                changed.insert(physical)
                if !url.lastPathComponent.hasPrefix("._") {
                    changed.insert((parent as NSString).appendingPathComponent("._" + url.lastPathComponent))
                }
            }
            if !changed.isEmpty {
                self.applyChanges(changed.sorted().map { FileChange(path: $0, flags: 0, requiresFullScan: false) })
            }
            completion?()
        }
    }

    /// These are filesystem paths supplied by an operation or FSEvents, not
    /// user-entered scope expressions. Preserve every filename character,
    /// including spaces at the end of a directory name, when resolution fails.
    private static func actualSpelling(of path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func restartWatcher() {
        guard !stopped, watchesFilesystem else { return }
        lock.lock()
        let paths = records.filter { isOnline($0) }.map(\.path)
        watcherToken.cancel(); let preparation = CancellationFlag(); watcherToken = preparation
        rootIssues["watcher"] = [ScanIssue(path: paths.joined(separator: ", "), message: "实时监听准备中。扫描与搜索仍可进行。")]
        lock.unlock()
        // FSEventStreamCreate may block in open() on a protected or slow volume.
        // Keep it away from the indexing worker and from application termination.
        let candidate = FileWatcher(paths: paths, onChanges: { [weak self] changes in
            if !preparation.isCancelled { self?.enqueueChanges(changes) }
        })
        watcherQueue.async { [weak self] in
            guard let self, !preparation.isCancelled, !self.stopped else { return }
            self.watcher?.stop(); self.watcher = candidate
            let success = paths.isEmpty || candidate.start()
            if preparation.isCancelled || self.stopped { candidate.stop(); return }
            self.worker.async { [weak self] in
                guard let self, !preparation.isCancelled, !self.stopped else { return }
                self.lock.lock()
                self.rootIssues["watcher"] = success ? nil : [ScanIssue(path: paths.joined(separator: ", "), message: "实时监听启动失败，请手动重新扫描更新索引。")]
                self.lock.unlock(); self.publish()
            }
        }
    }

    /// File events are hints from the watcher, not a durable journal. Once a
    /// batch exceeds its path budget, explicitly calibrate the affected roots
    /// instead of silently dropping names or queuing unbounded arrays.
    func enqueueChanges(_ changes: [FileChange]) {
        // The watcher invokes this on its own queue. Apply backpressure here
        // rather than retaining another unbounded queue of raw event arrays.
        eventsQueue.sync { [weak self] in
            guard let self, !self.stopped else { return }
            self.lock.lock(); let roots = self.records; self.lock.unlock()
            let globalLoss = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
            for change in changes {
                if change.flags & globalLoss != 0 {
                    for root in roots { self.pendingCalibrations[root.id] = root.path }
                    self.pendingEvents.removeAll(keepingCapacity: false)
                    continue
                }
                let affected = roots.filter { root in
                    if change.requiresFullScan && Self.path(change.path, contains: root.path) { return true }
                    return Self.path(root.path, contains: change.path)
                        && !self.exclusions(for: root).contains { Self.path($0, contains: change.path) }
                }
                guard !affected.isEmpty else { continue }
                if change.requiresFullScan {
                    for root in affected { self.pendingCalibrations[root.id] = root.path }
                    self.removeCalibratedEvents()
                    continue
                }
                if self.pendingCalibrations.values.contains(where: { Self.path($0, contains: change.path) }) { continue }
                let previous = self.pendingEvents[change.path]
                self.pendingEvents[change.path] = FileChange(path: change.path,
                    flags: (previous?.flags ?? 0) | change.flags,
                    requiresFullScan: previous?.requiresFullScan == true || change.requiresFullScan,
                    hasUnclassifiedHint: previous?.hasUnclassifiedHint == true || change.hasUnclassifiedHint)
                if self.pendingEvents.count > Self.maximumPendingEventPaths {
                    // Promote only roots touched by this pending batch. The
                    // path dictionary is released before subsequent events.
                    for root in roots where self.pendingEvents.keys.contains(where: { Self.path(root.path, contains: $0) }) {
                        self.pendingCalibrations[root.id] = root.path
                    }
                    self.removeCalibratedEvents()
                }
            }
            self.scheduleEventDrain()
        }
    }

    private static func path(_ ancestor: String, contains descendant: String) -> Bool {
        descendant == ancestor || descendant.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
    }

    // All three methods below run only on eventsQueue. Changes received after a
    // batch is captured remain pending until that batch has completely applied.
    private func removeCalibratedEvents() {
        pendingEvents = pendingEvents.filter { key, _ in
            !pendingCalibrations.values.contains { Self.path($0, contains: key) }
        }
    }

    private func scheduleEventDrain() {
        guard !stopped, !eventDrainInFlight, eventWork == nil,
              !pendingEvents.isEmpty || !pendingCalibrations.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.drainEvents() }
        eventWork = work
        eventsQueue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func drainEvents() {
        eventWork = nil
        guard !stopped, !eventDrainInFlight else { return }
        let events = Array(pendingEvents.values)
            + pendingCalibrations.values.map { FileChange(path: $0, flags: 0, requiresFullScan: true) }
        pendingEvents.removeAll(keepingCapacity: false)
        pendingCalibrations.removeAll(keepingCapacity: false)
        guard !events.isEmpty else { return }
        eventDrainInFlight = true
        worker.async { [weak self] in
            guard let self else { return }
            self.applyChanges(events)
            self.eventsQueue.async { [weak self] in
                guard let self else { return }
                self.eventDrainInFlight = false
                self.scheduleEventDrain()
            }
        }
    }

    /// Lightweight diagnostics for the real aggregation queue, useful for
    /// verifying its memory bound while a calibration occupies the worker.
    func eventBacklogSnapshot() -> (pendingPaths: Int, pendingRoots: Int, inFlight: Bool) {
        eventsQueue.sync { (pendingEvents.count, pendingCalibrations.count, eventDrainInFlight) }
    }

    private func applyChanges(_ changes: [FileChange]) {
        guard !stopped else { return }
        lock.lock(); let currentRecords = records; lock.unlock()
        var fullRoots = Set<String>(), changedRoots = Set<String>()
        var requests: [String: [String: FileChange]] = [:]
        var metadataPaths = Set<String>(), allMetadataChanged = false
        func markMetadataChanged(at path: String) {
            guard !allMetadataChanged else { return }
            metadataPaths.insert(path)
            if metadataPaths.count > Self.maximumChangedMetadataPaths {
                metadataPaths.removeAll(keepingCapacity: false); allMetadataChanged = true
            }
        }
        for change in changes {
            let globalLoss = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
            if change.flags & globalLoss != 0 {
                currentRecords.filter { isOnline($0) }.forEach { fullRoots.insert($0.id) }
                continue
            }
            if change.requiresFullScan {
                for record in currentRecords where record.path.hasPrefix(change.path == "/" ? "/" : change.path + "/") {
                    fullRoots.insert(record.id)
                }
            }
            for record in currentRecords where change.path == record.path || change.path.hasPrefix(record.path == "/" ? "/" : record.path + "/") {
                if exclusions(for: record).contains(where: { change.path == $0 || change.path.hasPrefix($0 + "/") }) { continue }
                if change.requiresFullScan { fullRoots.insert(record.id); continue }
                let previous = requests[record.id]?[change.path]
                requests[record.id, default: [:]][change.path] = FileChange(path: change.path,
                    flags: (previous?.flags ?? 0) | change.flags,
                    requiresFullScan: previous?.requiresFullScan == true || change.requiresFullScan,
                    hasUnclassifiedHint: previous?.hasUnclassifiedHint == true || change.hasUnclassifiedHint)
            }
        }
        lock.lock()
        if token.isCancelled { token = CancellationFlag() }
        let incrementalToken = token
        lock.unlock()
        var interrupted = false
        for record in currentRecords {
            if stopped || incrementalToken.isCancelled { interrupted = true; break }
            guard isOnline(record) else { continue }
            if fullRoots.contains(record.id) {
                restartWatcher(); scan([record], token: incrementalToken); continue
            }
            guard let paths = requests[record.id], !paths.isEmpty else { continue }
            lock.lock(); let engine = engines[record.id]; lock.unlock()
            guard let engine else { continue }
            // A directory's chmod/xattr hint cannot subsume a child's creation
            // or rename: its fast path intentionally does not enumerate children.
            let minimal = paths.keys.filter { path in
                !paths.contains { other, hint in
                    other != path && !hint.isMetadataOnly && Self.path(other, contains: path)
                }
            }
            var indexChanged = false
            var metadataChanged = false
            var rootInterrupted = false
            for path in minimal {
                if stopped || incrementalToken.isCancelled { rootInterrupted = true; break }
                let change = paths[path]!
                var attributes = stat()
                if lstat(path, &attributes) == 0 {
                    // An old-case path still resolves after a case-only rename
                    // on APFS/ExFAT. Use the current spelling for all change
                    // sources, including a later coalesced FSEvents callback.
                    // Resolve no final symlink: even dangling links are nodes.
                    let currentPath: String
                    if attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                        let url = URL(fileURLWithPath: path)
                        let name = (try? url.resourceValues(forKeys: [.nameKey]))?.name ?? url.lastPathComponent
                        currentPath = (Self.actualSpelling(of: url.deletingLastPathComponent().path) as NSString).appendingPathComponent(name)
                    } else { currentPath = Self.actualSpelling(of: path) }
                    let isDirectory = attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
                    let previousType = engine.pathIsDirectory(path)
                    let directoryContentHint = isDirectory
                        && change.flags & UInt32(kFSEventStreamEventFlagItemModified) != 0
                    if change.isMetadataOnly && !directoryContentHint && currentPath == path && previousType == isDirectory {
                        // The name and node type are unchanged. Notify metadata
                        // consumers without rebuilding names or rewriting qfi.
                        markMetadataChanged(at: currentPath)
                        continue
                    }
                    if attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                        let staged = EngineIndex()
                        let report = FileScanner.scan(path: currentPath, excludedPrefixes: exclusions(for: record),
                            cancelled: { self.stopped || incrementalToken.isCancelled }, onEntry: { _, _ in }, onProgress: { _, _ in },
                            indexEntry: { Self.acceptScannedEntry($0, directory: $1, into: staged) })
                        guard report.completed && !incrementalToken.isCancelled && !stopped else {
                            rootInterrupted = true
                            lock.lock()
                            var retained = rootIssues[record.id] ?? []
                            let newIssues = report.issues.isEmpty ? [ScanIssue(path: path,
                                message: "实时目录更新已暂停，保留旧索引；请重新扫描校准。")]
                                : report.issues
                            for issue in newIssues where !retained.contains(where: { $0.id == issue.id }) { retained.append(issue) }
                            rootIssues[record.id] = Array(retained.prefix(1000))
                            statuses[record.id]?.issueCount = retained.count
                            statuses[record.id]?.state = incrementalToken.isCancelled || stopped
                                ? "实时更新已暂停（保留旧索引）" : "实时更新中断（保留旧索引）"
                            lock.unlock()
                            metadataChanged = true
                            if stopped || incrementalToken.isCancelled { break }
                            continue
                        }
                        // Serialize the final cancellation check with the
                        // subtree commit. A finished helper must not publish a
                        // directory snapshot after cancellation was accepted.
                        lock.lock()
                        guard !incrementalToken.isCancelled && !stopped else {
                            lock.unlock(); rootInterrupted = true; break
                        }
                        if report.totalIssueCount == 0 {
                            engine.removeSubtree(path: path)
                            if currentPath != path { engine.removeSubtree(path: currentPath) }
                        }
                        staged.forEachPath { engine.add(path: $0, isDirectory: $1) }
                        indexChanged = true
                        var updatedIssues = (rootIssues[record.id] ?? []).filter { $0.path != path && !$0.path.hasPrefix(path + "/") }
                        updatedIssues.append(contentsOf: report.issues)
                        rootIssues[record.id] = Array(updatedIssues.prefix(1000))
                        statuses[record.id]?.issueCount = updatedIssues.count
                        lock.unlock()
                        metadataChanged = true
                    } else {
                        var changed = false
                        if previousType != false || currentPath != path {
                            changed = engine.removeSubtree(path: path)
                        }
                        if currentPath != path && engine.pathIsDirectory(currentPath) != false {
                            changed = engine.removeSubtree(path: currentPath) || changed
                        }
                        // lstat preserves even dangling symbolic links as searchable entries.
                        changed = engine.add(path: currentPath, isDirectory: false) || changed
                        indexChanged = indexChanged || changed
                        if !changed { markMetadataChanged(at: currentPath) }
                    }
                } else {
                    let code = errno
                    if code == ENOENT || code == ENOTDIR {
                        // A partial/retained cache can contain descendants even
                        // when their exact ancestor is absent. File/mixed flags
                        // are hints and must not leave that old subtree behind.
                        indexChanged = engine.removeSubtree(path: path) || indexChanged
                    }
                    else {
                        let issue = ScanIssue(path: path, message: "实时更新无法访问（\(code)），保留旧索引：\(String(cString: strerror(code)))；请重新扫描校准。")
                        lock.lock()
                        var existing = rootIssues[record.id] ?? []
                        let newIssue = !existing.contains(where: { $0.id == issue.id })
                        if newIssue { existing.append(issue) }
                        rootIssues[record.id] = Array(existing.prefix(1000))
                        statuses[record.id]?.issueCount = existing.count
                        statuses[record.id]?.state = "实时更新访问受限（保留旧索引）"
                        lock.unlock()
                        metadataChanged = metadataChanged || newIssue
                        rootInterrupted = true
                    }
                }
            }
            lock.lock(); statuses[record.id]?.count = engine.count
            if indexChanged && !rootInterrupted {
                statuses[record.id]?.lastUpdated = Date()
                let restricted = (statuses[record.id]?.issueCount ?? 0) > 0
                statuses[record.id]?.state = restricted ? "就绪（部分位置受限）" : "就绪"
            }
            if rootInterrupted && (stopped || incrementalToken.isCancelled) {
                statuses[record.id]?.state = "实时更新已暂停（保留旧索引）"
            }
            if indexChanged || metadataChanged { dirtyRoots.insert(record.id) }
            if indexChanged { searchRevision &+= 1 }
            lock.unlock()
            if indexChanged { changedRoots.insert(record.id) }
            if rootInterrupted { interrupted = true }
        }
        if allMetadataChanged || !metadataPaths.isEmpty {
            lock.lock(); metadataRevision &+= 1
            changedMetadataPaths = allMetadataChanged ? nil : metadataPaths.sorted()
            lock.unlock()
        }
        if interrupted { setMessage("部分实时更新未完成，旧索引及问题记录已保留。请重新扫描校准。") }
        else if !changedRoots.isEmpty { setMessage("文件变化已更新。离线磁盘显示上次索引。") }
        updateOnlineStatuses(); publish()
    }

    private func updateOnlineStatuses() {
        lock.lock()
        for record in records {
            let online = isOnline(record)
            if statuses[record.id]?.isOnline != online { searchRevision &+= 1 }
            statuses[record.id]?.isOnline = online
            if !online { statuses[record.id]?.state = "磁盘离线" }
        }
        lock.unlock()
    }

    struct VolumeEventPlan {
        let affectedRootIDs: Set<String>
        let shouldDiscover: Bool
    }

    /// Pure scope decision. Injecting eligibility permits owned fixture tests
    /// without mounting anything or starting a scan of the system root.
    static func planVolumeEvent(roots: [RootRecord], at url: URL, mounted: Bool,
                               discoveredRootID: String? = nil,
                               eligibility: (URL) -> Bool = isAutoDiscoverableVolume) -> VolumeEventPlan {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.isEmpty else {
            return VolumeEventPlan(affectedRootIDs: [], shouldDiscover: false)
        }
        let volumePath = url.standardized.path
        let affected = Set(roots.filter { path(volumePath, contains: $0.path) }.map(\.id))
        // A mount point can be reused by a different volume UUID. Identity,
        // rather than its path, decides whether it is an already known root.
        // Without an identity this is a discovery candidate; the handler probes
        // only this URL and performs the final ID check before adding anything.
        let newIdentity = discoveredRootID.map { id in !roots.contains { $0.id == id } } ?? true
        let discover = mounted && roots.contains { $0.path == "/" } && newIdentity && eligibility(url)
        return VolumeEventPlan(affectedRootIDs: affected, shouldDiscover: discover)
    }

    static func eligibleVolumeProperties(local: Bool?, browsable: Bool?, readOnly: Bool?) -> Bool {
        local == true && browsable == true && readOnly == false
    }

    /// Automatic discovery excludes installation images and unknown volumes.
    /// A manually configured read-only root can still be searched/reconnected.
    static func isAutoDiscoverableVolume(_ url: URL) -> Bool {
        guard url.isFileURL, url.standardized.path.hasPrefix("/Volumes/"),
              let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsBrowsableKey,
                                                            .volumeIsReadOnlyKey, .volumeURLKey]),
              eligibleVolumeProperties(local: values.volumeIsLocal, browsable: values.volumeIsBrowsable,
                                       readOnly: values.volumeIsReadOnly),
              values.volume?.standardized.path == url.standardized.path else { return false }
        return true
    }

    /// Handle only this notification's volume. A custom folder scope must never
    /// become whole-disk indexing simply because an unrelated DMG was mounted.
    func handleVolumeEvent(at url: URL, mounted: Bool,
                           eligibility: @escaping (URL) -> Bool = IndexStore.isAutoDiscoverableVolume,
                           completion: (() -> Void)? = nil) {
        worker.async { [weak self] in
            guard let self, !self.stopped else { completion?(); return }
            defer { completion?() }
            self.lock.lock(); let configured = self.records; self.lock.unlock()
            let plan = Self.planVolumeEvent(roots: configured, at: url, mounted: mounted, eligibility: eligibility)
            var affected = configured.filter { plan.affectedRootIDs.contains($0.id) }
            var added = false
            if plan.shouldDiscover {
                // Read only the notified volume, never enumerate all mounted
                // disks. makeRoot preserves canonical spelling and volume ID.
                let discovered = Self.makeRoot(path: url.path)
                self.lock.lock()
                if !self.records.contains(where: { $0.id == discovered.id }) {
                    self.records.append(discovered)
                    self.statuses[discovered.id] = RootStatus(record: discovered)
                    self.searchRevision &+= 1
                    affected.append(discovered); added = true
                }
                self.lock.unlock()
            }
            guard !affected.isEmpty else { return }
            var targets: [RootRecord] = []
            for record in affected {
                let online = mounted && self.isOnline(record)
                self.lock.lock()
                if self.statuses[record.id]?.isOnline != online { self.searchRevision &+= 1 }
                self.statuses[record.id]?.isOnline = online
                self.statuses[record.id]?.state = online ? "等待校准" : "磁盘离线"
                self.lock.unlock()
                if online { targets.append(record) }
            }
            if added {
                do { try self.writeConfig() }
                catch { self.setMessage("新增磁盘位置保存失败：\(error.localizedDescription)") }
            }
            self.restartWatcher(); self.publish()
            guard mounted, !targets.isEmpty else { return }
            self.lock.lock()
            let next = self.token.isCancelled ? CancellationFlag() : self.token
            self.token = next; self.lock.unlock()
            self.scan(targets, token: next)
        }
    }

    private func installVolumeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                // Without the event URL there is no safe affected scope; do not
                // substitute a discovery of every disk or a full calibration.
                guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                self?.handleVolumeEvent(at: url, mounted: name == NSWorkspace.didMountNotification)
            })
        }
    }

    private func ensureServices() {
        guard !servicesInstalled, !stopped else { return }
        servicesInstalled = true
        installVolumeObservers(); installCalibrationTimer(); installPersistenceTimer()
    }

    private func installCalibrationTimer() {
        let source = DispatchSource.makeTimerSource(queue: worker)
        source.schedule(deadline: .now() + 6 * 3600, repeating: 6 * 3600)
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.updateOnlineStatuses()
            self.lock.lock(); let targets = self.records.filter { self.isOnline($0) }
            let next = self.token.isCancelled ? CancellationFlag() : self.token; self.token = next; self.lock.unlock()
            self.scan(targets, token: next)
        }
        source.resume(); timer = source
    }

    private func installPersistenceTimer() {
        let source = DispatchSource.makeTimerSource(queue: worker)
        source.schedule(deadline: .now() + 30, repeating: 30)
        source.setEventHandler { [weak self] in self?.flushDirty() }
        source.resume(); persistenceTimer = source
    }

    private func flushDirty() {
        lock.lock()
        let pending = records.compactMap { record -> (RootRecord, EngineIndex, RootStatus, [ScanIssue])? in
            guard dirtyRoots.contains(record.id), let engine = engines[record.id], let status = statuses[record.id] else { return nil }
            return (record, engine, status, rootIssues[record.id] ?? [])
        }
        dirtyRoots.removeAll(); lock.unlock()
        for (record, engine, status, issues) in pending {
            do { try save(record, engine: engine, status: status, issues: issues) }
            catch {
                lock.lock(); dirtyRoots.insert(record.id); statuses[record.id]?.state = "可搜索，缓存保存失败"; lock.unlock()
                setMessage("索引更新已生效，缓存保存失败：\(error.localizedDescription)")
                publish()
            }
        }
    }

    func shutdown() {
        lifecycle.cancel()
        lock.lock(); token.cancel(); watcherToken.cancel(); lock.unlock()
        watcherQueue.async { [weak self] in self?.watcher?.stop() }
        eventsQueue.async { [weak self] in
            self?.eventWork?.cancel(); self?.eventWork = nil
            self?.pendingEvents.removeAll(keepingCapacity: false)
            self?.pendingCalibrations.removeAll(keepingCapacity: false)
        }
        let cleanup = {
            self.timer?.cancel(); self.persistenceTimer?.cancel()
            self.observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
            self.observers.removeAll()
            self.flushDirty()
        }
        if DispatchQueue.getSpecific(key: Self.workerKey) == true { cleanup() }
        else {
            let completion = DispatchGroup(); completion.enter()
            worker.async { cleanup(); completion.leave() }
            _ = completion.wait(timeout: .now() + 3)
        }
    }
}

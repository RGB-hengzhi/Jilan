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
    private var message = "正在载入本地索引…"
    private var token = CancellationFlag()
    private var watcher: FileWatcher?
    private var watcherToken = CancellationFlag()
    private var pendingEvents: [FileChange] = []
    private var eventWork: DispatchWorkItem?
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
            includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeIsBrowsableKey],
            options: [.skipHiddenVolumes]) ?? []
        for url in urls where url.path.hasPrefix("/Volumes/") {
            let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsBrowsableKey])
            guard values?.volumeIsLocal != false, values?.volumeIsBrowsable != false else { continue }
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
            scannedCount: progressCount, issues: records.flatMap { rootIssues[$0.id] ?? [] } + (rootIssues["watcher"] ?? []), message: message)
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
            lock.unlock(); publish()
            let report = FileScanner.scan(path: record.path, excludedPrefixes: exclusions(for: record),
                cancelled: { scanToken.isCancelled || self.stopped },
                onEntry: { path, isDir in engine.add(path: path, isDirectory: isDir) },
                onProgress: { count, path in
                    self.lock.lock(); self.progressCount = processed + count
                    if previous == nil {
                        if self.statuses[record.id]?.count != count { self.searchRevision &+= 1 }
                        self.statuses[record.id]?.count = count
                    }
                    self.message = "扫描 \(record.name)：\(path)"
                    self.lock.unlock(); self.publish()
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
                        if !engine.hasPath(path) { engine.add(path: path, isDirectory: isDir) }
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

    func search(_ request: SearchRequest, limit: Int = 2000) -> SearchBatch {
        let start = DispatchTime.now().uptimeNanoseconds
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

    private func enqueueChanges(_ changes: [FileChange]) {
        eventsQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.pendingEvents += changes
            // A continuous stream must still update at bounded intervals.
            guard self.eventWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let events = self.pendingEvents; self.pendingEvents.removeAll()
                self.eventWork = nil
                self.worker.async { [weak self] in self?.applyChanges(events) }
            }
            self.eventWork = work
            self.eventsQueue.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func applyChanges(_ changes: [FileChange]) {
        guard !stopped else { return }
        lock.lock(); let currentRecords = records; lock.unlock()
        var fullRoots = Set<String>(), changedRoots = Set<String>()
        var requests: [String: Set<String>] = [:]
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
                requests[record.id, default: []].insert(change.path)
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
            let minimal = paths.filter { path in !paths.contains { other in other != path && path.hasPrefix(other + "/") } }
            var indexChanged = false
            var metadataChanged = false
            var rootInterrupted = false
            for path in minimal {
                if stopped || incrementalToken.isCancelled { rootInterrupted = true; break }
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
                    if attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                        let staged = EngineIndex()
                        let report = FileScanner.scan(path: currentPath, excludedPrefixes: exclusions(for: record),
                            cancelled: { self.stopped || incrementalToken.isCancelled }, onEntry: { staged.add(path: $0, isDirectory: $1) }, onProgress: { _, _ in })
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
                        engine.removeSubtree(path: path)
                        // lstat preserves even dangling symbolic links as searchable entries.
                        engine.add(path: currentPath, isDirectory: false)
                        indexChanged = true
                    }
                } else {
                    let code = errno
                    if code == ENOENT || code == ENOTDIR { engine.removeSubtree(path: path); indexChanged = true }
                    else {
                        let issue = ScanIssue(path: path, message: "实时更新无法访问（\(code)），保留旧索引：\(String(cString: strerror(code)))；请重新扫描校准。")
                        lock.lock()
                        var existing = rootIssues[record.id] ?? []
                        if !existing.contains(where: { $0.id == issue.id }) { existing.append(issue) }
                        rootIssues[record.id] = Array(existing.prefix(1000))
                        statuses[record.id]?.issueCount = existing.count
                        statuses[record.id]?.state = "实时更新访问受限（保留旧索引）"
                        lock.unlock()
                        metadataChanged = true
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

    private func installVolumeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.worker.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    if name == NSWorkspace.didMountNotification {
                        let discovered = Self.wholeDisks()
                        self.lock.lock()
                        for record in discovered where !self.records.contains(where: { $0.id == record.id }) {
                            self.records.append(record); self.statuses[record.id] = RootStatus(record: record)
                            self.searchRevision &+= 1
                        }
                        self.lock.unlock()
                        try? self.writeConfig()
                    }
                    self.updateOnlineStatuses(); self.restartWatcher(); self.publish()
                    self.lock.lock(); let targets = self.records.filter { self.isOnline($0) }
                    let next = self.token.isCancelled ? CancellationFlag() : self.token; self.token = next; self.lock.unlock()
                    self.scan(targets, token: next)
                }
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

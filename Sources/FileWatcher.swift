import Foundation
import CoreServices
import Darwin

struct FileChange {
    let path: String
    let flags: UInt32
    let requiresFullScan: Bool
    let hasUnclassifiedHint: Bool

    init(path: String, flags: UInt32, requiresFullScan: Bool, hasUnclassifiedHint: Bool = false) {
        self.path = path; self.flags = flags; self.requiresFullScan = requiresFullScan
        self.hasUnclassifiedHint = hasUnclassifiedHint || flags == 0
    }

    /// FileEvents describes content/attribute writes separately from changes to
    /// the name tree. Mixed/coalesced hints and flagless operation hints retain
    /// their conservative structural handling.
    var isMetadataOnly: Bool {
        let metadata = UInt32(kFSEventStreamEventFlagItemModified
            | kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemFinderInfoMod
            | kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemXattrMod)
        let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCloned)
        return !requiresFullScan && !hasUnclassifiedHint && flags & metadata != 0 && flags & structural == 0
    }
}

/// FSEvents is a change hint, not a complete durable change journal. A startup
/// full scan and a reconnect full scan are required in addition to this stream.
final class FileWatcher {
    private let paths: [String]
    private let sink: FileEventSink
    // Capture before scanning can begin. Creating the actual stream may be
    // deferred to another queue, so SinceNow would otherwise lose that interval.
    private let startingEventID: FSEventStreamEventId
    private let eventQueue = DispatchQueue(label: "cn.local.fastfind.fsevents", qos: .utility)
    private let queueID = UUID()
    private let lifecycle = NSLock()
    private var stream: FSEventStreamRef?

    init(paths: [String], onChanges: @escaping ([FileChange]) -> Void) {
        self.startingEventID = FSEventsGetCurrentEventId()
        let roots = Array(Set(paths.map { URL(fileURLWithPath: $0).standardized.path })).sorted()
        self.paths = roots
        let mappings = roots.map { logical in
            guard let resolved = realpath(logical, nil) else { return (physical: logical, logical: logical) }
            defer { free(resolved) }
            return (physical: String(cString: resolved), logical: logical)
        }.sorted { $0.physical.count > $1.physical.count }
        self.sink = FileEventSink(pathMappings: mappings, onChanges: onChanges)
        eventQueue.setSpecific(key: Self.queueKey, value: queueID)
    }

    @discardableResult
    func start() -> Bool {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        if stream != nil { return true }
        guard !paths.isEmpty else { return false }
        // The stream retains a separate callback sink, never a pointer to this
        // watcher. This keeps queued callbacks safe while the watcher is torn down.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { raw in
                guard let raw = raw else { return nil }
                _ = Unmanaged<FileEventSink>.fromOpaque(raw).retain()
                return raw
            },
            release: { raw in
                if let raw = raw { Unmanaged<FileEventSink>.fromOpaque(raw).release() }
            }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, opaque, eventCount, rawPaths, flags, _ in
            guard let opaque = opaque else { return }
            let sink = Unmanaged<FileEventSink>.fromOpaque(opaque).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes makes this a CFArray of CFStrings,
            // rather than the unsafe default char** payload.
            let pathsArray = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue()
            let count = min(eventCount, CFArrayGetCount(pathsArray))
            let fullScanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
            var changes: [FileChange] = []
            changes.reserveCapacity(count)
            for index in 0..<count {
                let eventFlags = flags[index]
                // Historical replay ends with a control sentinel, whose path
                // must be ignored according to the FSEvents API contract.
                if eventFlags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
                guard let value = CFArrayGetValueAtIndex(pathsArray, index) else { continue }
                let cfString = unsafeBitCast(value, to: CFString.self)
                let eventPath = sink.logicalPath(cfString as String)
                changes.append(FileChange(path: eventPath, flags: eventFlags,
                                          requiresFullScan: eventFlags & fullScanFlags != 0))
            }
            if !changes.isEmpty { sink.onChanges(changes) }
        }
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                               paths as CFArray, startingEventID,
                                               0.20, options) else { return false }
        FSEventStreamSetDispatchQueue(created, eventQueue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    func stop() {
        lifecycle.lock()
        let previous = stream
        stream = nil
        if let previous = previous {
            FSEventStreamStop(previous)
            FSEventStreamInvalidate(previous)
            FSEventStreamRelease(previous)
        }
        lifecycle.unlock()
        // Drain callbacks before an owner may release this watcher. Never block
        // the queue from one of its own callbacks.
        if DispatchQueue.getSpecific(key: Self.queueKey) != queueID {
            eventQueue.sync {}
        }
    }

    private static let queueKey = DispatchSpecificKey<UUID>()

    deinit { stop() }
}

private final class FileEventSink {
    let pathMappings: [(physical: String, logical: String)]
    let onChanges: ([FileChange]) -> Void

    init(pathMappings: [(physical: String, logical: String)], onChanges: @escaping ([FileChange]) -> Void) {
        self.pathMappings = pathMappings
        self.onChanges = onChanges
    }

    func logicalPath(_ physicalPath: String) -> String {
        for mapping in pathMappings {
            if physicalPath == mapping.physical { return mapping.logical }
            let prefix = mapping.physical == "/" ? "/" : mapping.physical + "/"
            if physicalPath.hasPrefix(prefix) {
                let relative = String(physicalPath.dropFirst(prefix.count))
                return mapping.logical == "/" ? "/" + relative : mapping.logical + "/" + relative
            }
        }
        return physicalPath
    }
}

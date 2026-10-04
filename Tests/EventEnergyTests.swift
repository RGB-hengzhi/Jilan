// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreServices
import Darwin

/// Real owned files and injected FileEvents separate name-tree maintenance
/// from content/attribute changes. No system root or user library is scanned.
enum EventEnergyTests {
    static func run() throws -> [String: Any] {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("QuickFindEventEnergy-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("files"), subtree = root.appendingPathComponent("subtree")
        try fm.createDirectory(at: subtree, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        for number in 0...IndexStore.maximumChangedMetadataPaths {
            try Data("owned content".utf8).write(to: subtree.appendingPathComponent("file\(number).txt"))
        }
        let record = IndexStore.makeRoot(path: root.path)
        let physicalSubtree = record.path + "/subtree"
        let modified = physicalSubtree + "/file0.txt"
        let data = fixture.appendingPathComponent("cache-metadata")
        let store = IndexStore(dataDirectory: data, initialRoots: [record], watchesFilesystem: false)
        var stopped = false
        defer { if !stopped { store.shutdown() } }
        store.start(); try initial(store)
        let before = store.snapshot(), qfi = data.appendingPathComponent(record.id + ".qfi")
        let originalCache = try Data(contentsOf: qfi), originalStat = try stamp(qfi)
        try Data("changed content and size".utf8).write(to: URL(fileURLWithPath: modified))
        // Deliberately withhold this child's structural hint. A metadata-only
        // parent event must not discover it by walking the entire subtree.
        let unreported = physicalSubtree + "/unreported-child.txt"
        try Data().write(to: URL(fileURLWithPath: unreported))
        try send(store, [hint(modified, kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),
                         hint(physicalSubtree, kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsDir)])
        let after = store.snapshot()
        try check(after.searchRevision == before.searchRevision && after.roots.first?.count == before.roots.first?.count,
                  "pure content/directory attributes changed the name index")
        try check(after.metadataRevision == before.metadataRevision + 1
                  && Set(after.changedMetadataPaths ?? []) == [modified, physicalSubtree],
                  "metadata batch needs one bounded revision with exact paths")
        try check(store.search(SearchRequest(query: "unreported-child")).totalMatches == 0,
                  "directory attribute hint recursively discovered an unreported child")
        let attributeHints = [kFSEventStreamEventFlagItemFinderInfoMod, kFSEventStreamEventFlagItemChangeOwner,
                              kFSEventStreamEventFlagItemXattrMod].map { hint(modified, $0 | kFSEventStreamEventFlagItemIsFile) }
        try send(store, attributeHints)
        try check(store.snapshot().searchRevision == before.searchRevision
                  && store.snapshot().metadataRevision == after.metadataRevision + 1,
                  "coalesced attribute flags must stay metadata-only")
        let boundedBefore = store.snapshot()
        let overflow = (0...IndexStore.maximumChangedMetadataPaths).map {
            hint(physicalSubtree + "/file\($0).txt", kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        }
        try send(store, overflow)
        let boundedAfter = store.snapshot()
        try check(boundedAfter.searchRevision == boundedBefore.searchRevision
                  && boundedAfter.metadataRevision == boundedBefore.metadataRevision + 1
                  && boundedAfter.changedMetadataPaths == nil,
                  "metadata path overflow must invalidate metadata without calibrating names")
        store.shutdown(); stopped = true
        let finalCache = try Data(contentsOf: qfi), finalStat = try stamp(qfi)
        try check(originalCache == finalCache && originalStat == finalStat,
                  "pure metadata events rewrote the name cache at shutdown")

        let structural = try structuralChanges(fixture: fixture, record: record, subtree: physicalSubtree)
        let orphaned = try orphanedCachedDescendants(fixture: fixture)
        return ["status": "passed", "ownedFiles": IndexStore.maximumChangedMetadataPaths + 1,
                "pureFileContentDoesNotChangeNameRevision": true, "directoryAttributesDoNotWalkDescendants": true,
                "allMetadataFlagsCoalesce": true, "boundedMetadataOverflowInvalidatesAll": true,
                "unchangedNameCacheBytesAndMtime": true, "structuralChanges": structural,
                "retainedCacheWithoutExactAncestor": orphaned,
                "method": "owned physical fixtures; injected FileEvents; no energy measurement"]
    }

    private static func orphanedCachedDescendants(fixture: URL) throws -> [String: Any] {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("orphan-files"), data = fixture.appendingPathComponent("orphan-cache")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        let record = IndexStore.makeRoot(path: root.path)
        let deleted = record.path + "/deleted-ancestor", mixed = record.path + "/mixed-ancestor"
        let replaced = record.path + "/file-ancestor", neighbor = record.path + "/deleted-ancestor-adjacent/keep.txt"
        let cached = EngineIndex()
        cached.add(path: record.path, isDirectory: true)
        for path in [deleted + "/child.txt", deleted + "/grandchild/nested.txt", mixed + "/child.txt", replaced + "/child.txt", neighbor] {
            cached.add(path: path, isDirectory: false)
        }
        try check(cached.pathIsDirectory(deleted) == nil && cached.pathIsDirectory(mixed) == nil,
                  "retained-cache fixture must lack exact ancestor nodes")
        try cached.save(to: data.appendingPathComponent(record.id + ".qfi"))
        let store = IndexStore(dataDirectory: data, initialRoots: [record], watchesFilesystem: false)
        let loaded = CancellationFlag()
        defer { store.onUpdate = nil; store.shutdown() }
        store.onUpdate = { value in
            if !loaded.isCancelled && value.roots.first?.count == cached.count && !value.isScanning {
                loaded.cancel(); store.cancelScan()
            }
        }
        store.start()
        try wait("owned retained cache loaded") { loaded.isCancelled }
        let ready = DispatchSemaphore(value: 0)
        store.refreshChangedPaths([]) { ready.signal() }
        try check(ready.wait(timeout: .now() + 8) == .success, "retained cache startup barrier failed")
        store.onUpdate = nil
        try check(store.search(SearchRequest(query: "child.txt")).totalMatches == 3,
                  "owned cache children must be present before deletion hints")
        try send(store, [hint(deleted, kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile),
                         hint(mixed, kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir)])
        let afterDeletion = Set(store.search(SearchRequest(query: ""), limit: 20).hits.map(\.path))
        try check(afterDeletion == [record.path, replaced + "/child.txt", neighbor],
                  "file/mixed deletion hints left cached orphan descendants or erased adjacent names")
        try Data().write(to: URL(fileURLWithPath: replaced))
        try send(store, [hint(replaced, kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)])
        let afterReplacement = Set(store.search(SearchRequest(query: ""), limit: 20).hits.map(\.path))
        try check(afterReplacement == [record.path, replaced, neighbor],
                  "a new file over a missing cached ancestor must retire its old descendants")
        return ["status": "passed", "fixture": "owned qfi loaded while startup calibration explicitly cancelled",
                "missingExactAncestor": true, "fileDeletionRetiresOrphanDescendants": true,
                "mixedFileDirectoryDeletionRetiresOrphanDescendants": true,
                "newFileRetiresOrphanDescendants": true, "adjacentPrefixPreserved": true]
    }

    private static func structuralChanges(fixture: URL, record: RootRecord, subtree: String) throws -> [String: Any] {
        let fm = FileManager.default, data = fixture.appendingPathComponent("cache-structural")
        let store = IndexStore(dataDirectory: data, initialRoots: [record], watchesFilesystem: false)
        defer { store.shutdown() }
        store.start(); try initial(store)
        let before = store.snapshot()
        let old = subtree + "/file0.txt", renamed = subtree + "/renamed.txt"
        let deleted = subtree + "/file1.txt", created = subtree + "/created.txt"
        try fm.moveItem(atPath: old, toPath: renamed)
        try fm.removeItem(atPath: deleted); try Data().write(to: URL(fileURLWithPath: created))
        try send(store, [hint(subtree, kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsDir),
                         hint(old, kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile),
                         hint(renamed, kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile),
                         hint(created, kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),
                         hint(deleted, kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile),
                         hint(subtree + "/unknown-deleted.txt", kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)])
        try check(store.snapshot().searchRevision > before.searchRevision
                  && store.search(SearchRequest(query: "file0.txt")).totalMatches == 0
                  && store.search(SearchRequest(query: "file1.txt")).totalMatches == 0
                  && store.search(SearchRequest(query: "renamed.txt")).totalMatches == 1
                  && store.search(SearchRequest(query: "created.txt")).totalMatches == 1,
                  "parent metadata hint masked create/rename/delete or mixed flags")
        let unknown = subtree + "/unknown-modified.txt"
        try Data().write(to: URL(fileURLWithPath: unknown))
        try send(store, [hint(unknown, kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)])
        try check(store.search(SearchRequest(query: "unknown-modified.txt")).totalMatches == 1,
                  "unknown modified path must still be inspected and indexed")

        let replacement = subtree + "/type-replacement"
        try fm.createDirectory(atPath: replacement, withIntermediateDirectories: false)
        try Data().write(to: URL(fileURLWithPath: replacement + "/inside.txt"))
        try send(store, [hint(replacement, kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)])
        try check(store.search(SearchRequest(query: "inside.txt")).totalMatches == 1, "new directory missed descendants")
        try fm.removeItem(atPath: replacement); try Data().write(to: URL(fileURLWithPath: replacement))
        try send(store, [hint(replacement, kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsFile)])
        let replacementHits = store.search(SearchRequest(query: "type-replacement")).hits
        try check(replacementHits.count == 1 && replacementHits.first?.isDirectory == false
                  && store.search(SearchRequest(query: "inside.txt")).totalMatches == 0,
                  "metadata hint describing a changed type must remove stale descendants")

        let flagless = subtree + "/flagless-recovery.txt"
        try Data().write(to: URL(fileURLWithPath: flagless))
        try send(store, [hint(subtree, 0), hint(subtree, kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsDir)])
        try check(store.search(SearchRequest(query: "flagless-recovery.txt")).totalMatches == 1,
                  "coalescing must not turn an unclassified flagless hint into metadata-only")

        let missed = subtree + "/missed-event.txt"
        try Data().write(to: URL(fileURLWithPath: missed))
        try send(store, [FileChange(path: record.path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), requiresFullScan: true)])
        try check(store.search(SearchRequest(query: "missed-event.txt")).totalMatches == 1,
                  "full recovery must preserve missing-event calibration")
        return ["ancestorMetadataKeepsChildEvents": true, "mixedStructuralMetadataFlags": true,
                "creationRenameDeletion": true, "unknownModifiedIsIndexed": true,
                "directoryToFileRetiresDescendants": true, "flaglessCoalescingStaysConservative": true,
                "fullRecoveryStillScans": true]
    }
    private static func hint(_ path: String, _ flags: Int) -> FileChange {
        FileChange(path: path, flags: UInt32(flags), requiresFullScan: false)
    }
    private static func stamp(_ url: URL) throws -> [Int64] {
        var value = stat()
        try check(lstat(url.path, &value) == 0, "cache stat failed")
        return [Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec)]
    }
    private static func initial(_ store: IndexStore) throws {
        try wait("owned initial scan") { !store.snapshot().isScanning && store.snapshot().roots.first?.lastUpdated != nil }
    }
    private static func send(_ store: IndexStore, _ changes: [FileChange]) throws {
        store.enqueueChanges(changes)
        try wait("event drain") {
            let state = store.eventBacklogSnapshot()
            return state.pendingPaths == 0 && state.pendingRoots == 0 && !state.inFlight
        }
    }
    private static func wait(_ label: String, _ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        throw EngineTestError.failed("event energy test timed out: " + label)
    }
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw EngineTestError.failed("event energy regression: " + message) }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreServices

private final class MetadataEventReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [String: Int] = [:]
    func add(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        reads[path, default: 0] += 1; return reads[path]!
    }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return reads[path, default: 0] }
}

/// Real owned-file writes use the production event aggregation and search
/// pipeline. FileEvents flags are supplied explicitly, keeping the test
/// deterministic without claiming it is a native FSEvents delivery test.
enum MetadataEventRefreshTests {
    @MainActor
    static func run() throws -> [String: Any] {
        let fm = FileManager.default
        // A visible home-level fixture permits testing Finder hidden flags
        // without inheriting the hidden flag of /private or Library.
        let fixture = fm.homeDirectoryForCurrentUser.appendingPathComponent("JilanMetadataEventTests-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("files")
        let data = fixture.appendingPathComponent("index")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let file = root.appendingPathComponent("owned-content.txt")
        try Data(repeating: 1, count: 8).write(to: file)
        let path = IndexStore.makeRoot(path: file.path).path
        let store = IndexStore(dataDirectory: data, initialRoots: [IndexStore.makeRoot(path: root.path)], watchesFilesystem: false)
        let model = AppModel(store: store)
        defer { model.onChange = nil; model.shutdown() }
        model.query = "owned-content"
        model.start()
        try wait("初次索引和名称查询") { !model.isScanning && model.resultsAreCurrent && model.totalMatches == 1 }
        let nameRevision = store.snapshot().searchRevision
        let nameGeneration = model.searchGeneration
        let modification = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        let attributes = UInt32(kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsFile)
        let finderInfo = UInt32(kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemIsFile)

        func publishMetadata(_ flags: UInt32, expected: Int, searches: Bool) throws {
            let beforeRevision = model.latestMetadataRevision
            let beforeGeneration = model.searchGeneration
            store.enqueueChanges([FileChange(path: path, flags: flags, requiresFullScan: false)])
            try wait("内容或属性事件抵达并刷新") {
                model.latestMetadataRevision != beforeRevision && model.resultsAreCurrent
                    && !model.isInspectingMetadata && model.totalMatches == expected
                    && (!searches || model.searchGeneration > beforeGeneration)
            }
            try check(store.snapshot().searchRevision == nameRevision, "普通内容/属性写入不应改变名称索引 revision。")
            if !searches { try check(model.searchGeneration == beforeGeneration, "纯名称/路径/扩展名条件不应因内容写入而重搜。") }
            try check(model.changedMetadataPaths?.contains(path) == true, "内容变化路径没有传给展示属性和预览刷新。")
        }

        try Data(repeating: 2, count: 16).write(to: file)
        try publishMetadata(modification, expected: 1, searches: false)
        try check(model.searchGeneration == nameGeneration, "名称查询在内容追加后重复执行。")
        model.matchPath = true; model.extensionFilter = "txt"
        model.filters.includedPaths = [root.path]
        model.search(immediate: true)
        try wait("名称、路径及扩展名条件") { model.resultsAreCurrent && model.totalMatches == 1 }
        try Data(repeating: 3, count: 24).write(to: file)
        try publishMetadata(modification, expected: 1, searches: false)

        model.sizeFilter = ">=1kib"
        model.search(immediate: true)
        try wait("小文件不匹配大小条件") { model.resultsAreCurrent && !model.isInspectingMetadata && model.totalMatches == 0 }
        try Data(repeating: 4, count: 4_096).write(to: file)
        try publishMetadata(modification, expected: 1, searches: true)
        try check(model.results.first?.size == 4_096, "大小筛选没有携带更新后的真实字节数。")
        try Data(repeating: 5, count: 4).write(to: file)
        try publishMetadata(modification, expected: 0, searches: true)

        let now = Date()
        let oldDate = now.addingTimeInterval(-10 * 24 * 3600)
        model.sizeFilter = ""; model.modifiedFilter = "today"
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: path)
        model.invalidateMetadata(); model.search(immediate: true)
        try wait("旧修改日期不匹配今天") { model.resultsAreCurrent && !model.isInspectingMetadata && model.totalMatches == 0 }
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: path)
        try publishMetadata(attributes, expected: 1, searches: true)
        try check(abs((model.results.first?.modifiedDate ?? .distantPast).timeIntervalSince(now)) < 1,
                  "修改日期没有更新为真实文件属性。")

        model.modifiedFilter = ""; model.filters.createdFilter = "today"
        try fm.setAttributes([.creationDate: oldDate, .modificationDate: oldDate], ofItemAtPath: path)
        model.invalidateMetadata(); model.search(immediate: true)
        try wait("旧创建日期不匹配今天") { model.resultsAreCurrent && !model.isInspectingMetadata && model.totalMatches == 0 }
        try fm.setAttributes([.creationDate: now, .modificationDate: now], ofItemAtPath: path)
        try publishMetadata(attributes, expected: 1, searches: true)
        try check(abs((model.results.first?.createdDate ?? .distantPast).timeIntervalSince(now)) < 1,
                  "创建日期没有更新为真实文件属性。")

        model.filters.createdFilter = ""; model.filters.hidden = .visible
        model.search(immediate: true)
        try wait("Finder flag 变化前可见") { model.resultsAreCurrent && !model.isInspectingMetadata && model.totalMatches == 1 }
        var hiddenValues = URLResourceValues(); hiddenValues.isHidden = true
        var fileURL = file
        try fileURL.setResourceValues(hiddenValues)
        try publishMetadata(finderInfo, expected: 0, searches: true)
        hiddenValues.isHidden = false
        try fileURL.setResourceValues(hiddenValues)
        try publishMetadata(finderInfo, expected: 1, searches: true)

        let cacheReport = try cacheInvalidation(fixture: fixture)
        let previewReport = try aliasPreviewScope(fixture: fixture)

        model.filters = SearchFilters(); model.search(immediate: true)
        try wait("回到名称查询") { model.resultsAreCurrent && !model.isInspectingMetadata && model.totalMatches == 1 }
        // Only these two edge cases inject snapshots: paths belong to one
        // revision batch, so a skipped batch requires full invalidation.
        var skipped = store.snapshot()
        skipped.metadataRevision = model.latestMetadataRevision &+ 2
        skipped.changedMetadataPaths = [path]
        store.onUpdate?(skipped)
        try wait("跨 revision 通知") { model.latestMetadataRevision == skipped.metadataRevision }
        try check(model.changedMetadataPaths == nil, "跨过元数据 revision 时不能只失效最后一批路径。")
        var beforeWrap = skipped; beforeWrap.metadataRevision = UInt64.max
        store.onUpdate?(beforeWrap)
        try wait("revision 接近回绕") { model.latestMetadataRevision == UInt64.max }
        var wrapped = beforeWrap; wrapped.metadataRevision = 0
        store.onUpdate?(wrapped)
        try wait("revision 回绕") { model.latestMetadataRevision == 0 }
        try check(model.changedMetadataPaths == [path], "合法的 revision 回绕应保留这一批变化路径。")

        return ["status": "passed", "ownedFixtureOnly": true,
                "eventDelivery": "production aggregation with explicit FileEvents flags; real owned-file writes",
                "nameRevisionUnchangedByContentAndAttributes": true,
                "namePathExtensionSearchNotRepeated": true,
                "sizeFilterZeroOneZero": true,
                "modifiedDateRefresh": true, "createdDateRefresh": true,
                "finderHiddenFlagRefresh": true, "changedPathsReachModel": true,
                "revisionGapFallsBackToFullInvalidation": true,
                "revisionWrapKeepsSingleBatchPaths": true,
                "revisionEdgeCases": "ordered snapshot simulation only",
                "displayMetadataCache": cacheReport, "aliasPreviewScope": previewReport]
    }

    @MainActor
    private static func cacheInvalidation(fixture: URL) throws -> [String: Any] {
        let changed = fixture.appendingPathComponent("cache-changed.txt")
        let stable = fixture.appendingPathComponent("cache-stable.txt")
        try Data(repeating: 1, count: 8).write(to: changed)
        try Data(repeating: 1, count: 13).write(to: stable)
        let reads = MetadataEventReadCounter()
        let cache = ResultMetadataCache(testHooks: .init(beforeRead: { _ = reads.add($0) }))
        cache.load(paths: [changed.path, stable.path])
        try wait("显示属性初次读取") { cache.pendingEntryCount == 0 && cache.cachedEntryCount == 2 }
        let stableReads = reads.count(stable.path)
        let now = Date()
        try Data(repeating: 2, count: 512).write(to: changed)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: changed.path)
        cache.invalidate(paths: [changed.path])
        try check(cache.value(path: changed.path) == nil && cache.value(path: stable.path)?.size == 13,
                  "路径失效应清除变化项并保留无关的缓存。")
        cache.load(paths: [changed.path, stable.path])
        try wait("显示属性精确刷新") { cache.pendingEntryCount == 0 && cache.value(path: changed.path)?.size == 512 }
        try check(reads.count(stable.path) == stableReads, "精确失效导致无关文件属性重复读取。")
        try check(abs((cache.value(path: changed.path)?.modified ?? .distantPast).timeIntervalSince(now)) < 1,
                  "显示属性缓存没有刷新真实修改时间。")

        // Query A's cache survives switching to query B. An event for A must
        // invalidate it even while B alone is being requested/displayed.
        cache.load(paths: [stable.path])
        let beforeHiddenReads = reads.count(changed.path)
        let updatedDate = now.addingTimeInterval(60)
        try Data(repeating: 2, count: 768).write(to: changed)
        try FileManager.default.setAttributes([.modificationDate: updatedDate], ofItemAtPath: changed.path)
        let hiddenAffected = cache.invalidateChangedPaths([changed.path])
        try check(hiddenAffected.contains(changed.path) && cache.value(path: changed.path) == nil,
                  "切换查询后的旧缓存没有按原始事件路径失效。")
        cache.load(paths: [stable.path])
        try check(reads.count(changed.path) == beforeHiddenReads && cache.value(path: stable.path)?.size == 13,
                  "隐藏缓存失效不应立即读取不可见项或清除无关查询缓存。")
        cache.load(paths: [changed.path])
        try wait("切回旧查询取得最新属性") { cache.pendingEntryCount == 0 && cache.value(path: changed.path)?.size == 768 }
        try check(abs((cache.value(path: changed.path)?.modified ?? .distantPast).timeIntervalSince(updatedDate)) < 1
                    && reads.count(stable.path) == stableReads,
                  "10 秒缓存期内切回旧查询仍显示旧大小或日期。")

        let group = fixture.appendingPathComponent("cache-group")
        let other = fixture.appendingPathComponent("cache-group-other")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let first = group.appendingPathComponent("first.txt"), second = group.appendingPathComponent("second.txt")
        let sibling = other.appendingPathComponent("sibling.txt")
        try Data(repeating: 1, count: 9).write(to: first)
        try Data(repeating: 1, count: 10).write(to: second)
        try Data(repeating: 1, count: 11).write(to: sibling)
        cache.load(paths: [first.path, second.path, sibling.path])
        try wait("祖先事件的旧缓存夹具") { cache.pendingEntryCount == 0 && cache.value(path: second.path) != nil }
        let siblingReads = reads.count(sibling.path)
        try Data(repeating: 2, count: 111).write(to: first)
        try FileManager.default.setAttributes([.modificationDate: updatedDate], ofItemAtPath: second.path)
        let ancestorAffected = cache.invalidateChangedPaths([group.path])
        try check(Set(ancestorAffected) == [first.path, second.path]
                    && cache.value(path: sibling.path)?.size == 11,
                  "祖先变化应失效所有缓存子项，不能误失效同前缀的兄弟目录。")
        cache.load(paths: [first.path, second.path, stable.path, sibling.path])
        try wait("祖先范围缓存刷新") { cache.pendingEntryCount == 0 && cache.value(path: first.path)?.size == 111 }
        try check(abs((cache.value(path: second.path)?.modified ?? .distantPast).timeIntervalSince(updatedDate)) < 1
                    && reads.count(sibling.path) == siblingReads && reads.count(stable.path) == stableReads,
                  "祖先范围失效没有刷新子项真实日期，或多读取无关项。")

        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let inFlightReads = MetadataEventReadCounter()
        let inFlight = ResultMetadataCache(testHooks: .init(beforeRead: { path in
            if path == changed.path && inFlightReads.add(path) == 1 {
                entered.signal(); _ = release.wait(timeout: .now() + 5)
            }
        }))
        inFlight.load(paths: [changed.path])
        try check(entered.wait(timeout: .now() + 2) == .success, "路径失效测试没有进入在途属性读取。")
        try Data(repeating: 3, count: 1_024).write(to: changed)
        inFlight.invalidateChangedPaths([fixture.path]); inFlight.load(paths: [changed.path])
        release.signal()
        try wait("在途路径失效后恢复") { inFlight.pendingEntryCount == 0 && inFlight.value(path: changed.path)?.size == 1_024 }
        try check(inFlightReads.count(changed.path) == 2, "在途路径失效应取消旧批次并只重新读取一次。")
        return ["pathInvalidationRefreshesRealSizeAndDate": true,
                "unrelatedCachedPathsRetainedWithoutRead": true,
                "crossQueryCachedAttributesInvalidateBeforeTTL": true,
                "invisibleInvalidationDoesNotReadUntilRequested": true,
                "ancestorInvalidatesCachedDescendantsOnly": true,
                "ancestorInvalidatesPendingRead": true,
                "inFlightInvalidationSuppressesStaleRead": true]
    }

    private static func aliasPreviewScope(fixture: URL) throws -> [String: Any] {
        let fm = FileManager.default
        let physicalDirectory = fixture.appendingPathComponent("preview-physical")
        let aliasDirectory = fixture.appendingPathComponent("preview-alias")
        try fm.createDirectory(at: physicalDirectory, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: aliasDirectory, withDestinationURL: physicalDirectory)
        let physicalFile = physicalDirectory.appendingPathComponent("selected.txt")
        let aliasFile = aliasDirectory.appendingPathComponent("selected.txt")
        try Data(repeating: 1, count: 32).write(to: physicalFile)
        let resolved = PreviewMetadataScope.resolvePhysicalPath(aliasFile.path)
        try check(resolved == physicalFile.path, "真实符号链接目录没有解析到预览文件的物理路径。")
        try Data(repeating: 2, count: 64).write(to: physicalFile)
        let aliasAttributes = try fm.attributesOfItem(atPath: aliasFile.path)
        try check((aliasAttributes[.size] as? NSNumber)?.int64Value == 64,
                  "通过别名目录读取的真实内容没有跟随物理文件变化。")
        try check(PreviewMetadataScope.shouldRefresh(path: aliasFile.path, physicalPath: resolved,
                                                    changedPaths: [physicalFile.path]),
                  "物理文件事件没有匹配别名路径中的选中预览。")
        try check(PreviewMetadataScope.shouldRefresh(path: aliasFile.path, physicalPath: resolved,
                                                    changedPaths: [physicalDirectory.path]),
                  "物理祖先事件没有匹配别名预览。")
        try check(PreviewMetadataScope.shouldRefresh(path: aliasFile.path, physicalPath: resolved,
                                                    changedPaths: [aliasDirectory.path]),
                  "词法别名祖先变化不能刷新预览身份。")
        try check(!PreviewMetadataScope.shouldRefresh(path: aliasFile.path, physicalPath: resolved,
                                                     changedPaths: [fixture.appendingPathComponent("unrelated.txt").path]),
                  "已解析身份的预览仍被无关文件事件刷新。")
        try check(PreviewMetadataScope.shouldRefresh(path: aliasFile.path, physicalPath: nil,
                                                    changedPaths: [physicalFile.path]),
                  "首次预览尚未解析身份时应保守检查当前选中项。")
        return ["fixture": "real symlink directory and real edited file; production scope helper",
                "physicalExactAndAncestorMatch": true, "lexicalAncestorMatch": true,
                "unrelatedEventIgnoredAfterResolution": true, "unresolvedIdentityConservative": true]
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw EngineTestError.failed(message) }
    }

    @MainActor
    private static func wait(_ label: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        try check(condition(), "元数据事件回归超时：" + label)
    }
}

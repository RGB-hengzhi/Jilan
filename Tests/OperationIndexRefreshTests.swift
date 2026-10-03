import Foundation
import Darwin

/// Disable the journal on these owned fixtures so a successful test cannot be
/// explained by an unrelated FSEvents hint or a full parent-directory scan.
enum OperationIndexRefreshTests {
    static func run() throws -> [String: Any] {
        try localPathHints()
        try trailingSpaceParent()
        let caseInsensitiveLocal = try caseOnlyPaths(base: FileManager.default.temporaryDirectory)
        var external = "not configured"
        if let path = ProcessInfo.processInfo.environment["FASTFIND_TEST_VOLUME_ROOT"], !path.isEmpty {
            let base = URL(fileURLWithPath: path)
            let format = try base.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]).volumeLocalizedFormatDescription ?? ""
            if format.localizedCaseInsensitiveContains("exfat") {
                try exfatSidecars(base: base); _ = try caseOnlyPaths(base: base)
                external = "passed: real ExFAT AppleDouble and case-only rename"
            }
            else { external = "configured volume is " + format + "; ExFAT case not run" }
        }
        return ["status": "passed", "journalIndependentKnownPaths": true, "appleDoubleNeighbors": true,
            "noParentDirectoryRescan": true, "permissionUnknownRetained": true, "trailingSpaceDirectory": true,
            "caseOnlyRenameAndDanglingSymlink": true, "localCaseInsensitiveVolume": caseInsensitiveLocal,
            "realExFAT": external]
    }
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw EngineTestError.failed("操作后索引同步：" + message) }
    }
    private static func wait(_ description: String, _ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        throw EngineTestError.failed("操作后索引同步超时：" + description)
    }
    private static func refresh(_ store: IndexStore, _ paths: [String]) throws {
        let finished = DispatchSemaphore(value: 0)
        store.refreshChangedPaths(paths) { finished.signal() }
        try check(finished.wait(timeout: .now() + 8) == .success, "局部路径更新未完成")
    }
    private static func localPathHints() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("QuickFindOperationIndex-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("文件"), data = fixture.appendingPathComponent("索引")
        let protected = root.appendingPathComponent("权限目录")
        try fm.createDirectory(at: protected, withIntermediateDirectories: true)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.path); try? fm.removeItem(at: fixture) }
        let old = root.appendingPathComponent("原名.txt"), new = root.appendingPathComponent("新名.txt")
        let oldSidecar = root.appendingPathComponent("._原名.txt"), newSidecar = root.appendingPathComponent("._新名.txt")
        let unrelated = root.appendingPathComponent("其它项.txt"), unavailable = protected.appendingPathComponent("仍应保留.txt")
        for url in [old, oldSidecar, unrelated, unavailable] { try Data("owned fixture".utf8).write(to: url) }
        let record = IndexStore.makeRoot(path: root.path)
        let physicalNew = record.path + "/" + new.lastPathComponent
        let physicalNewSidecar = record.path + "/" + newSidecar.lastPathComponent
        let physicalUnavailable = record.path + "/权限目录/" + unavailable.lastPathComponent
        let store = IndexStore(dataDirectory: data, initialRoots: [record], watchesFilesystem: false)
        defer { store.shutdown() }
        store.start()
        try wait("初始扫描") { store.snapshot().roots.first?.state == "就绪" && store.search(SearchRequest(query: "原名.txt")).totalMatches == 2 }
        let revision = store.snapshot().searchRevision
        try fm.moveItem(at: old, to: new)
        if fm.fileExists(atPath: oldSidecar.path) { try fm.moveItem(at: oldSidecar, to: newSidecar) }
        try fm.removeItem(at: unrelated)
        try check(store.search(SearchRequest(query: "原名.txt")).totalMatches == 2, "关闭journal时应明确保留旧缓存")
        try refresh(store, [old.path, new.path])
        try check(store.search(SearchRequest(query: "原名.txt")).totalMatches == 0, "原名与旧sidecar均须移除索引")
        try check(Set(store.search(SearchRequest(query: "新名.txt")).hits.map(\.path)) == [physicalNew, physicalNewSidecar], "实际新文件及sidecar均须索引")
        try check(store.snapshot().searchRevision > revision && !store.snapshot().isScanning, "局部变化必须发布新revision且无需全扫描")
        try check(store.search(SearchRequest(query: "其它项.txt")).totalMatches == 1, "不得通过扫描整个父目录顺便清掉无关缓存")
        try check(fm.fileExists(atPath: new.path) && fm.fileExists(atPath: newSidecar.path), "索引校准不得删除真实文件")
        try refresh(store, [unrelated.path])
        try check(store.search(SearchRequest(query: "其它项.txt")).totalMatches == 0, "明确missing路径应移除")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: protected.path)
        var attributes = stat()
        let unavailableResult = unavailable.path.withCString { lstat($0, &attributes) }
        let unavailableError = errno
        try check(unavailableResult == -1 && (unavailableError == EACCES || unavailableError == EPERM), "权限fixture须实际不可访问，不能假称已测试")
        try refresh(store, [physicalUnavailable])
        try check(store.search(SearchRequest(query: "仍应保留.txt")).totalMatches == 1
                    && store.snapshot().issues.contains(where: { $0.path == physicalUnavailable }), "权限未知保留缓存并报告问题")
    }
    private static func exfatSidecars(base: URL) throws {
        let fm = FileManager.default
        let fixture = base.appendingPathComponent("QuickFindExFATOperation-" + UUID().uuidString)
        let data = fm.temporaryDirectory.appendingPathComponent("QuickFindExFATOperationData-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: fixture); try? fm.removeItem(at: data) }
        let old = fixture.appendingPathComponent("原始唯一文件.txt"), new = fixture.appendingPathComponent("改名完成文件.txt")
        let oldSidecar = fixture.appendingPathComponent("._" + old.lastPathComponent), newSidecar = fixture.appendingPathComponent("._" + new.lastPathComponent)
        let payload = Data("real ExFAT owned rename\n".utf8)
        try payload.write(to: old)
        let metadata = Data("owned AppleDouble attribute".utf8)
        let code = metadata.withUnsafeBytes { value in setxattr(old.path, "com.quickfind.operation-index-test", value.baseAddress, value.count, 0, 0) }
        try check(code == 0 && fm.fileExists(atPath: oldSidecar.path), "ExFAT真实sidecar必须已产生")
        let record = IndexStore.makeRoot(path: fixture.path)
        let store = IndexStore(dataDirectory: data, initialRoots: [record], watchesFilesystem: false)
        defer { store.shutdown() }
        store.start()
        try wait("ExFAT初始扫描") { store.snapshot().roots.first?.state == "就绪" && store.search(SearchRequest(query: old.lastPathComponent)).totalMatches == 2 }
        var report: FileOperationReport?
        let service = FileOperationService()
        service.start(request: FileOperationRequest(kind: .rename, sources: [old], names: [old.path: new.lastPathComponent]),
            resolveConflict: { _, resolve in resolve(.cancel) }, progress: { _ in }, completion: { report = $0 })
        try wait("ExFAT实际改名") { report != nil }
        try check(report?.errors.isEmpty == true && report?.completedPaths == [new.path]
                    && !fm.fileExists(atPath: oldSidecar.path) && fm.fileExists(atPath: newSidecar.path), "FileManager应实际迁移AppleDouble且报告成功")
        try check(store.search(SearchRequest(query: old.lastPathComponent)).totalMatches == 2, "遗漏所有事件时旧cache必须仍在以证明回归有效")
        try refresh(store, [old.path] + (report?.completedPaths ?? []))
        try check(store.search(SearchRequest(query: old.lastPathComponent)).totalMatches == 0, "真实ExFAT旧主文件/sidecar不能幽灵残留")
        try check(Set(store.search(SearchRequest(query: new.lastPathComponent)).hits.map(\.path)) == [new.path, newSidecar.path], "真实ExFAT新主文件/sidecar均存在")
        let movedContents = try Data(contentsOf: new)
        try check(movedContents == payload, "索引修复不得改变主文件内容")
    }

    private static func trailingSpaceParent() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("QuickFindSpacedOperation-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("目录末尾空格 "), data = fixture.appendingPathComponent("索引")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let old = root.appendingPathComponent("旧名.txt"), new = root.appendingPathComponent("新名.txt")
        try Data("preserve exact filesystem path".utf8).write(to: old)
        let record = IndexStore.makeRoot(path: root.path)
        let store = IndexStore(dataDirectory: data, initialRoots: [record], watchesFilesystem: false)
        defer { store.shutdown() }
        store.start()
        try wait("尾空格目录初始扫描") { store.snapshot().roots.first?.state == "就绪" && store.search(SearchRequest(query: "旧名.txt")).totalMatches == 1 }
        try fm.moveItem(at: old, to: new)
        try refresh(store, [old.path, new.path])
        try check(store.search(SearchRequest(query: "旧名.txt")).totalMatches == 0
                    && store.search(SearchRequest(query: "新名.txt")).hits.map(\.path) == [record.path + "/新名.txt"], "真实目录末尾空格不能被操作路径规范化裁剪")
    }

    private static func caseOnlyPaths(base: URL) throws -> Bool {
        let fm = FileManager.default
        let fixture = base.appendingPathComponent("QuickFindCaseOperation-" + UUID().uuidString)
        let data = fm.temporaryDirectory.appendingPathComponent("QuickFindCaseOperationData-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: fixture); try? fm.removeItem(at: data) }
        let old = fixture.appendingPathComponent("CaseOnly.txt"), new = fixture.appendingPathComponent("caseonly.txt")
        let oldLink = fixture.appendingPathComponent("CaseLink"), newLink = fixture.appendingPathComponent("caselink")
        let supportsLinks = (try? fixture.resourceValues(forKeys: [.volumeSupportsSymbolicLinksKey]).volumeSupportsSymbolicLinks) ?? false
        try Data("unchanged case-only payload".utf8).write(to: old)
        if supportsLinks { try fm.createSymbolicLink(atPath: oldLink.path, withDestinationPath: "/QuickFindMissingTarget-" + UUID().uuidString) }
        let record = IndexStore.makeRoot(path: fixture.path)
        let store = IndexStore(dataDirectory: data, initialRoots: [record], watchesFilesystem: false)
        defer { store.shutdown() }
        func expectedPaths(_ url: URL) -> Set<String> {
            var paths: Set<String> = [record.path + "/" + url.lastPathComponent]
            let neighbor = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
            var attributes = stat()
            if lstat(neighbor.path, &attributes) == 0 { paths.insert(record.path + "/" + neighbor.lastPathComponent) }
            return paths
        }
        let initialPaths = expectedPaths(old)
        store.start()
        try wait("大小写初始扫描") { store.snapshot().roots.first?.state == "就绪" && store.search(SearchRequest(query: "caseonly.txt")).totalMatches == initialPaths.count }
        let service = FileOperationService()
        func rename(_ source: URL, _ destination: URL) throws {
            var finished: FileOperationReport?
            service.start(request: FileOperationRequest(kind: .rename, sources: [source], names: [source.path: destination.lastPathComponent]),
                resolveConflict: { _, resolve in resolve(.cancel) }, progress: { _ in }, completion: { finished = $0 })
            try wait("真实大小写改名") { finished != nil }
            try check(finished?.errors.isEmpty == true && finished?.completedPaths == [destination.path], "大小写改名必须实际成功")
            try refresh(store, [source.path] + (finished?.completedPaths ?? []))
        }
        try check(Set(store.search(SearchRequest(query: "caseonly.txt")).hits.map(\.path)) == initialPaths, "显式刷新前须确有旧拼写cache及真实sidecar集合")
        try rename(old, new)
        let renamedPaths = expectedPaths(new)
        try check(renamedPaths.count == initialPaths.count
                    && Set(store.search(SearchRequest(query: "caseonly.txt")).hits.map(\.path)) == renamedPaths, "大小写改名不得产生相同节点双cache或数量膨胀")
        // Emulate a delayed callback using the old spelling after the direct
        // operation hint: the shared update path must never reinsert it.
        try refresh(store, [old.path])
        try check(store.search(SearchRequest(query: "caseonly.txt")).totalMatches == renamedPaths.count
                    && Set(store.search(SearchRequest(query: "caseonly.txt")).hits.map(\.path)) == renamedPaths, "迟到旧拼写事件不得重入旧cache")
        if supportsLinks {
            try rename(oldLink, newLink)
            try refresh(store, [oldLink.path])
            let linkHits = store.search(SearchRequest(query: "caselink")).hits
            try check(Set(linkHits.map(\.path)) == expectedPaths(newLink)
                        && linkHits.allSatisfy { !$0.isDirectory }, "大小写改名须保留dangling symlink节点及真实sidecar且不展开目标")
        }
        return !((try? fixture.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true)
    }
}

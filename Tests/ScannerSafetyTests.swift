import Foundation
import Darwin

enum ScannerSafetyTests {
    private struct Observation {
        var report: ScanReport
        var entries: [String: Bool]
        var calls: Int
        var intents: [String]
        var finalCount: Int
    }
    private enum Replacement { case link, fifo, file }

    static func run() throws -> [String: Any] {
        let local = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let localFormat = try local.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]).volumeLocalizedFormatDescription ?? "unknown"
        try basicNames(base: local)
        try stableSpecialNodes(base: local)
        for replacement in [Replacement.link, .fifo, .file] { try replacedDirectory(base: local, replacement: replacement) }
        try movedAncestor(base: local)
        try replacedRootAncestor(base: local)
        try errorsAndCancellation(base: local)
        try issueLimit(base: local)
        var external = "not configured"
        if let path = ProcessInfo.processInfo.environment["FASTFIND_TEST_VOLUME_ROOT"], !path.isEmpty {
            let base = URL(fileURLWithPath: path)
            let format = try base.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]).volumeLocalizedFormatDescription ?? "unknown"
            try basicNames(base: base)
            external = "passed: real " + format + " filename/directory coverage and exclusion boundaries"
        }
        return ["status": "passed", "localFilesystem": localFormat, "descriptorAnchoredDescent": true,
                "directoryReplacedBySymlinkFIFOAndFile": true, "noContentsOrSymlinkTargetOpened": true,
                "errnoPermissionCancellation": true, "pendingIOPath": true, "issueDetailsCappedAt1000": true,
                "externalVolume": external]
    }

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw FilesystemTestError.failed("扫描安全：" + message) }
    }
    private static func ownedFixture(base: URL) throws -> URL {
        let url = base.appendingPathComponent("QuickFindScannerSafety-" + UUID().uuidString)
        try directory(url.path)
        guard let physical = realpath(url.path, nil) else { throw FilesystemTestError.failed("fixture realpath failed") }
        defer { free(physical) }
        return URL(fileURLWithPath: String(cString: physical))
    }
    private static func directory(_ path: String) throws {
        guard mkdir(path, 0o700) == 0 else { throw FilesystemTestError.failed("mkdir fixture: \(errno)") }
    }
    private static func file(_ path: String, mode: mode_t = 0o600) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw FilesystemTestError.failed("open fixture: \(errno)") }
        close(fd)
    }
    private static func observe(_ path: String, exclusions: [String] = [], cancelled: () -> Bool = { false },
                                onEntry: ((String, Bool) -> Void)? = nil,
                                onIntent: ((String) -> Void)? = nil) -> Observation {
        var entries: [String: Bool] = [:], calls = 0, intents: [String] = [], finalCount = -1
        let report = FileScanner.walk(path: path, excludedPrefixes: exclusions, cancelled: cancelled,
            onEntry: { name, isDirectory in entries[name] = isDirectory; calls += 1; onEntry?(name, isDirectory) },
            onProgress: { count, _ in finalCount = count }, onIOIntent: { intents.append($0); onIntent?($0) })
        return Observation(report: report, entries: entries, calls: calls, intents: intents, finalCount: finalCount)
    }
    private static func basicNames(base: URL) throws {
        let fixture = try ownedFixture(base: base)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.path + "/扫描根目录"
        let directories = [root, root + "/中文目录", root + "/.git", root + "/正常包.app", root + "/正常包.app/Contents",
                           root + "/排除", root + "/排除但应保留"]
        let files = [root + "/中文目录/文件 空格.txt", root + "/.隐藏文件", root + "/.git/config",
                     root + "/正常包.app/Contents/info.txt", root + "/排除/不能出现.txt", root + "/排除但应保留/应保留.txt"]
        for path in directories { try directory(path) }
        for path in files { try file(path) }
        var expected = Dictionary(uniqueKeysWithValues: directories.filter { $0 != root + "/排除" }.map { ($0, true) })
        for path in files where path != root + "/排除/不能出现.txt" { expected[path] = false }
        // ExFAT may materialize AppleDouble even for POSIX permission metadata.
        // Independently inspect only neighbors of the nodes we actually created;
        // never derive expected coverage from the scanner's own output.
        for path in directories + files {
            let url = URL(fileURLWithPath: path)
            let sidecar = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent).path
            if sidecar.hasPrefix(root + "/") && !sidecar.hasPrefix(root + "/排除/") {
                var attributes = stat()
                if lstat(sidecar, &attributes) == 0 { expected[sidecar] = false }
            }
        }
        let result = observe(root + "/./", exclusions: [root + "/排除"])
        try check(result.report.completed && result.report.totalIssueCount == 0, "基本名称扫描应完整无问题")
        try check(result.entries == expected && result.calls == expected.count && result.report.count == expected.count,
                  "中文/空格/隐藏/.git/应用包/排除边界须严格匹配实际独立集合：\(result.entries)")
        try check(result.finalCount == expected.count && result.intents.allSatisfy { $0 == root || $0.hasPrefix(root + "/") }, "最终进度及物理 pending 路径")
        let excludedRoot = observe(root, exclusions: [root])
        try check(excludedRoot.report.completed && excludedRoot.report.count == 0 && excludedRoot.intents.isEmpty, "排除根不得开始属性或目录IO")
        // A name-only scanner must index even a regular file with no read bits.
        let unreadableFile = root + "/仅名称.txt"
        try file(unreadableFile, mode: 0)
        let leaf = observe(unreadableFile)
        try check(leaf.report.completed && leaf.report.totalIssueCount == 0 && leaf.entries == [unreadableFile: false], "单个普通文件只读取属性，不读取内容")
    }
    private static func stableSpecialNodes(base: URL) throws {
        let fixture = try ownedFixture(base: base)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.path + "/walk", outside = fixture.path + "/outside"
        try directory(root); try directory(outside); try file(outside + "/不应索引.txt")
        try check(symlink(outside, root + "/目录链接") == 0, "目录链接fixture")
        try check(symlink(fixture.path + "/不存在", root + "/失效链接") == 0, "失效链接fixture")
        try check(symlink(root, root + "/循环链接") == 0, "循环链接fixture")
        try check(mkfifo(root + "/命名管道", 0o600) == 0, "FIFO fixture")
        let expected = [root: true, root + "/目录链接": false, root + "/失效链接": false,
                        root + "/循环链接": false, root + "/命名管道": false]
        let result = observe(root)
        try check(result.report.completed && result.report.totalIssueCount == 0 && result.entries == expected, "特殊节点仅名称、链接目标/循环不得下探")
        let fifo = observe(root + "/命名管道")
        try check(fifo.report.completed && fifo.entries == [root + "/命名管道": false] && fifo.report.totalIssueCount == 0, "根路径FIFO不得等待写端")
        let link = observe(root + "/目录链接")
        try check(link.report.completed && link.entries == [root + "/目录链接": false] && link.report.totalIssueCount == 0, "根路径链接不得跟随")
        let spaced = fixture.path + "/目录末尾空格 "
        try directory(spaced); try file(spaced + "/内容.txt")
        let spacedResult = observe(spaced)
        try check(spacedResult.entries == [spaced: true, spaced + "/内容.txt": false] && spacedResult.report.totalIssueCount == 0, "真实根路径尾空格不能trim")
    }
    private static func replacedDirectory(base: URL, replacement: Replacement) throws {
        let fixture = try ownedFixture(base: base)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.path + "/walk", victim = root + "/victim", outside = fixture.path + "/outside", stash = fixture.path + "/stash"
        try directory(root); try directory(victim); try directory(outside)
        try file(victim + "/原目录文件.txt"); try file(outside + "/外部标记.txt")
        var mutationError: Error?, replaced = false
        let result = observe(root, onEntry: { path, isDirectory in
            if path == victim && isDirectory && !replaced {
                replaced = true
                do {
                    try check(rename(victim, stash) == 0, "竞态移动目录fixture")
                    switch replacement {
                    case .link: try check(symlink(outside, victim) == 0, "竞态链接fixture")
                    case .fifo: try check(mkfifo(victim, 0o600) == 0, "竞态FIFO fixture")
                    case .file: try file(victim)
                    }
                } catch { mutationError = error }
            }
        })
        if let mutationError { throw mutationError }
        try check(replaced && result.report.completed && result.entries == [root: true, victim: true] && result.calls == 2,
                  "确定性目录替换后不得进入目标/旧目录/外部路径")
        try check(result.report.totalIssueCount == 1 && result.report.issues.first?.path == victim, "目录类型已变须报告准确路径")
        try check(result.intents.contains(victim), "失败的目录打开前须记录准确pending path")
        if replacement != .link { try check(result.report.issues.first?.message.contains("（20）") == true, "FIFO/普通文件替换应 ENOTDIR") }
    }
    private static func movedAncestor(base: URL) throws {
        let fixture = try ownedFixture(base: base)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.path + "/walk", parent = root + "/parent", child = parent + "/child"
        let outside = fixture.path + "/outside", stash = fixture.path + "/stash"
        for path in [root, parent, child, outside, outside + "/child"] { try directory(path) }
        try file(child + "/original"); try file(outside + "/child/outside-marker")
        var mutationError: Error?, moved = false
        let result = observe(root, onEntry: { path, isDirectory in
            if path == child && isDirectory && !moved {
                moved = true
                do {
                    try check(rename(parent, stash) == 0 && symlink(outside, parent) == 0, "移动祖先fixture")
                } catch { mutationError = error }
            }
        })
        if let mutationError { throw mutationError }
        let expected = [root: true, parent: true, child: true, child + "/original": false]
        try check(moved && result.report.completed && result.report.totalIssueCount == 0 && result.entries == expected,
                  "已打开的父目录句柄必须锚定后续下降，不得由祖先路径链接重定向")
    }
    private static func replacedRootAncestor(base: URL) throws {
        let fixture = try ownedFixture(base: base)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let parent = fixture.path + "/parent", root = parent + "/walk", stash = fixture.path + "/stash"
        let outside = fixture.path + "/outside"
        for path in [parent, root, outside, outside + "/walk"] { try directory(path) }
        try file(root + "/original"); try file(outside + "/walk/outside-marker")
        var mutationError: Error?, moved = false
        let result = observe(root, onEntry: { path, isDirectory in
            if path == root && isDirectory && !moved {
                moved = true
                do { try check(rename(parent, stash) == 0 && symlink(outside, parent) == 0, "根祖先移动fixture") }
                catch { mutationError = error }
            }
        })
        if let mutationError { throw mutationError }
        try check(moved && result.report.completed && result.entries == [root: true] && result.report.totalIssueCount == 1
                  && result.report.issues.first?.path == root, "根打开fd须验证原属性身份，祖先链接竞态不能重定向整次扫描")
    }
    private static func errorsAndCancellation(base: URL) throws {
        let fixture = try ownedFixture(base: base)
        let denied = fixture.path + "/受限目录", root = fixture.path + "/walk"
        defer { chmod(denied, 0o700); try? FileManager.default.removeItem(at: fixture) }
        try directory(root); try directory(root + "/child"); try file(root + "/child/inside")
        let missing = observe(fixture.path + "/missing")
        try check(missing.report.count == 0 && missing.report.totalIssueCount == 1 && missing.report.issues.first?.message.contains("（2）") == true, "不存在路径须准确ENOENT")
        try directory(denied); try file(denied + "/inside")
        try check(chmod(denied, 0) == 0 && access(denied, R_OK | X_OK) != 0, "实际POSIX不可读fixture，不能假称权限已测")
        let unavailable = observe(denied)
        try check(unavailable.report.completed && unavailable.entries == [denied: true] && unavailable.calls == 1
                  && unavailable.report.totalIssueCount == 1 && unavailable.report.issues.first?.path == denied
                  && unavailable.report.issues.first?.message.contains("权限不足") == true, "权限错误单次索引目录并保留准确问题")
        var count = 0
        let cancelled = observe(root, cancelled: { count >= 2 }, onEntry: { _, _ in count += 1 })
        try check(!cancelled.report.completed && cancelled.report.count == 2 && cancelled.finalCount == 2
                  && cancelled.entries[root + "/child/inside"] == nil, "取消后不得继续下降，最终进度须保留")
        var stop = false
        let beforeIO = observe(root, cancelled: { stop }, onIntent: { _ in stop = true })
        try check(!beforeIO.report.completed && beforeIO.report.count == 0 && beforeIO.intents == [root], "IO intent之后取消须在系统调用前生效")
    }
    private static func issueLimit(base: URL) throws {
        let fixture = try ownedFixture(base: base)
        defer { try? FileManager.default.removeItem(at: fixture) }
        // Minimal fixture beyond the documented 1000-detail cap. Replacing each
        // directory in its callback makes all errors deterministic ENOTDIR.
        let root = fixture.path + "/walk"
        try directory(root)
        for n in 0..<1001 { try directory(root + "/node-" + String(n)) }
        var mutationError: Error?
        let result = observe(root, onEntry: { path, isDirectory in
            if path != root && isDirectory {
                if rmdir(path) != 0 { mutationError = FilesystemTestError.failed("cap rmdir fixture") }
                else { do { try file(path) } catch { mutationError = error } }
            }
        })
        if let mutationError { throw mutationError }
        try check(result.report.completed && result.report.count == 1002 && result.calls == 1002
                  && result.report.totalIssueCount == 1001 && result.report.issues.count == 1000,
                  "只截断问题详情，不截断问题总数或枚举")
    }
}

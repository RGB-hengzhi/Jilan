import Foundation
import CoreServices
import Darwin

enum FilesystemTestError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

enum FilesystemTests {
    static func run() throws {
        try scannerTest()
        try watcherTest()
        if let path = ProcessInfo.processInfo.environment["FASTFIND_TEST_VOLUME_ROOT"], !path.isEmpty {
            try externalVolumeTest(path: path)
            try watcherTest(baseDirectory: URL(fileURLWithPath: path))
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw FilesystemTestError.failed(message) }
    }

    private static func scannerTest() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("疾速查找-扫描测试-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let nested = root.appendingPathComponent("中文文件夹")
        let excluded = root.appendingPathComponent("排除")
        let sibling = root.appendingPathComponent("排除但应保留")
        for directory in [nested, excluded, sibling] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let includedFile = nested.appendingPathComponent("家庭资料.txt")
        let hidden = root.appendingPathComponent(".隐藏文件")
        let dotGit = root.appendingPathComponent(".git")
        let sourceFile = dotGit.appendingPathComponent("config")
        let bundle = root.appendingPathComponent("正常包.app")
        let bundleFile = bundle.appendingPathComponent("Contents/info.txt")
        try fm.createDirectory(at: dotGit, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundleFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        for file in [includedFile, hidden, excluded.appendingPathComponent("不能出现.txt"),
                     sibling.appendingPathComponent("应保留.txt"), sourceFile, bundleFile] {
            try Data("name-only scanner test".utf8).write(to: file)
        }
        let symlink = nested.appendingPathComponent("循环链接")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: root)
        let broken = root.appendingPathComponent("失效链接")
        try fm.createSymbolicLink(atPath: broken.path, withDestinationPath: root.appendingPathComponent("不存在").path)

        var entries: [String: Bool] = [:]
        var calls = 0
        var progress = -1
        let report = FileScanner.scan(path: root.path, excludedPrefixes: [excluded.path], cancelled: { false },
                                      onEntry: { entries[$0] = $1; calls += 1 },
                                      onProgress: { progress = $0; _ = $1 })
        try expect(report.completed, "扫描未正常结束")
        try expect(report.totalIssueCount == 0, "正常扫描出现问题：\(report.issues)")
        try expect(report.count == entries.count && calls == entries.count, "目录或文件重复入库")
        try expect(progress == report.count, "最终进度计数不一致")
        try expect(entries[includedFile.path] == false, "中文文件漏扫")
        try expect(entries[nested.path] == true, "目录漏扫")
        try expect(entries[hidden.path] == false, "隐藏文件被隐式忽略")
        try expect(entries[sourceFile.path] == false, ".git 被隐式忽略")
        try expect(entries[bundleFile.path] == false, "应用包内容被隐式忽略")
        try expect(entries[symlink.path] == false && entries[broken.path] == false, "符号链接自身未索引")
        try expect(entries.keys.allSatisfy { !$0.hasPrefix(symlink.path + "/") }, "符号链接被跟随")
        try expect(entries[excluded.path] == nil, "排除目录仍被索引")
        try expect(entries[sibling.path] == true, "排除前缀错误匹配同名开头目录")

        if let physical = realpath(root.path, nil) {
            let physicalRoot = String(cString: physical)
            free(physical)
            var physicalEntries: [String] = []
            let physicalReport = FileScanner.scan(path: physicalRoot, excludedPrefixes: [], cancelled: { false },
                onEntry: { physicalEntries.append($0); _ = $1 }, onProgress: { _, _ in })
            try expect(physicalReport.completed && physicalReport.totalIssueCount == 0, "物理根扫描失败")
            try expect(physicalEntries.allSatisfy { $0 == physicalRoot || $0.hasPrefix(physicalRoot + "/") },
                       "物理根被Foundation折回符号链接别名")
        }

        var cancelCount = 0
        let cancelledReport = FileScanner.scan(path: root.path, excludedPrefixes: [], cancelled: { cancelCount >= 3 },
                                               onEntry: { _, _ in cancelCount += 1 }, onProgress: { _, _ in })
        try expect(!cancelledReport.completed && cancelledReport.count == 3, "取消扫描无效")

        let missing = root.appendingPathComponent("不存在目录")
        let missingReport = FileScanner.scan(path: missing.path, excludedPrefixes: [], cancelled: { false },
                                             onEntry: { _, _ in }, onProgress: { _, _ in })
        try expect(missingReport.totalIssueCount > 0 && !missingReport.issues.isEmpty, "不存在路径没有报告问题")

        let unreadable = root.appendingPathComponent("权限测试")
        try fm.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data().write(to: unreadable.appendingPathComponent("内部文件.txt"))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
        if access(unreadable.path, R_OK | X_OK) != 0 {
            var unreadableCalls = 0
            let permissionReport = FileScanner.scan(path: unreadable.path, excludedPrefixes: [], cancelled: { false },
                                                    onEntry: { _, _ in unreadableCalls += 1 }, onProgress: { _, _ in })
            try expect(permissionReport.totalIssueCount > 0, "不可读目录没有报告权限错误")
            try expect(unreadableCalls <= 1, "不可读目录重复入库")
            print("PASS scanner: 中文、隐藏项、目录、应用包、链接循环、排除、取消、物理根路径、权限错误")
        } else {
            print("PASS scanner: 中文、隐藏项、目录、应用包、链接循环、排除、取消、物理根路径；权限测试被当前系统权限跳过")
        }
    }

    private static func externalVolumeTest(path: String) throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path).appendingPathComponent("疾速查找-外盘测试-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let included = root.appendingPathComponent("中文目录/外置文件.txt")
        let hidden = root.appendingPathComponent(".隐藏文件")
        let excluded = root.appendingPathComponent("排除目录")
        try fm.createDirectory(at: included.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: excluded, withIntermediateDirectories: true)
        for file in [included, hidden, excluded.appendingPathComponent("已排除.txt")] {
            try Data("external volume fixture".utf8).write(to: file)
        }
        var entries: [String: Bool] = [:]
        let report = FileScanner.scan(path: root.path, excludedPrefixes: [excluded.path], cancelled: { false },
                                      onEntry: { entries[$0] = $1 }, onProgress: { _, _ in })
        try expect(report.completed && report.totalIssueCount == 0, "外置盘扫描失败：\(report.issues)")
        try expect(entries[included.path] == false && entries[hidden.path] == false, "外置盘中文或隐藏文件漏扫")
        try expect(entries[excluded.path] == nil, "外置盘排除目录仍被扫描")
        print("PASS external volume scanner: \(path)，中文、目录、隐藏项、排除")
    }

    private static func watcherTest(baseDirectory: URL? = nil) throws {
        let fm = FileManager.default
        let root = (baseDirectory ?? fm.temporaryDirectory).resolvingSymlinksInPath()
            .appendingPathComponent("疾速查找-事件测试-" + UUID().uuidString)
        let renamedRoot = URL(fileURLWithPath: root.path + "-根目录已改名")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: renamedRoot)
        }
        let condition = NSCondition()
        var events: [FileChange] = []
        let watcher = FileWatcher(paths: [root.path]) { changes in
            condition.lock()
            events.append(contentsOf: changes)
            condition.broadcast()
            condition.unlock()
        }
        try expect(watcher.start(), "FSEvents 无法启动")
        // Start is idempotent; duplicate streams must not be created.
        try expect(watcher.start(), "FSEvents 重复启动失败")
        defer { watcher.stop() }

        func received(_ path: String, _ flags: UInt32) -> Bool {
            let deadline = Date().addingTimeInterval(8)
            condition.lock()
            defer { condition.unlock() }
            while true {
                if events.contains(where: {
                    return $0.path == path && ($0.flags & flags != 0 || $0.requiresFullScan)
                }) { return true }
                if !condition.wait(until: deadline) {
                    let details = events.map { "\($0.path) [\($0.flags)]" }
                    print("FSEvents timeout expected \(path) flags=\(flags); received \(details)")
                    return false
                }
            }
        }

        let original = root.appendingPathComponent("事件中文.txt")
        try Data("created".utf8).write(to: original)
        try expect(received(original.path, UInt32(kFSEventStreamEventFlagItemCreated)), "没有收到创建事件")
        let renamed = root.appendingPathComponent("已改名.txt")
        try fm.moveItem(at: original, to: renamed)
        try expect(received(renamed.path, UInt32(kFSEventStreamEventFlagItemRenamed)), "没有收到改名事件")
        let destination = root.appendingPathComponent("移动目的目录")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let moved = destination.appendingPathComponent("已移动.txt")
        try fm.moveItem(at: renamed, to: moved)
        try expect(received(moved.path, UInt32(kFSEventStreamEventFlagItemRenamed)), "没有收到移动事件")
        try fm.removeItem(at: moved)
        try expect(received(moved.path, UInt32(kFSEventStreamEventFlagItemRemoved)), "没有收到删除事件")
        try fm.moveItem(at: root, to: renamedRoot)
        try expect(received(root.path, UInt32(kFSEventStreamEventFlagRootChanged)), "根目录改变没有触发完整扫描提示")
        watcher.stop()
        watcher.stop()
        print("PASS watcher: 创建、改名、移动、删除、根目录改变、重复启动与停止")
    }
}

import Foundation
import Darwin

enum WorkspaceFilesystemTestError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case .failed(let message): return message } }
}

/// These checks mutate only UUID-named owned fixtures. The runloop is pumped
/// because production service callbacks deliberately arrive on the main thread.
enum WorkspaceFilesystemTests {
    private static let fm = FileManager.default

    static func run() throws -> [String: Any] {
        guard Thread.isMainThread else {
            throw WorkspaceFilesystemTestError.failed("工作区诊断必须由主线程运行。")
        }
        let internalRoot = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("QuickFindWorkspaceTests-" + UUID().uuidString)
        try fm.createDirectory(at: internalRoot, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: internalRoot) }
        var report = try testVolume(root: internalRoot, symlinks: true)
        report["internalFixture"] = "passed: owned fixture on internal temporary volume"
        try cancellation(root: internalRoot)
        report["partialCopyCancellation"] = true
        report["byteProgressAndThrottling"] = true
        try trash(root: internalRoot)
        report["systemTrash"] = true
        if let base = ProcessInfo.processInfo.environment["FASTFIND_TEST_VOLUME_ROOT"], !base.isEmpty {
            let externalRoot = URL(fileURLWithPath: base).resolvingSymlinksInPath()
                .appendingPathComponent("QuickFindWorkspaceExternalTests-" + UUID().uuidString)
            try fm.createDirectory(at: externalRoot, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: externalRoot) }
            report["externalFixture"] = try testVolume(root: externalRoot, symlinks: false)
            try crossVolume(sourceRoot: internalRoot, targetRoot: externalRoot)
            try crossVolume(sourceRoot: externalRoot, targetRoot: internalRoot)
            report["crossVolumeCopyThenMove"] = true
            report["crossVolumeSourceMutationGuards"] = ["directoryAddedDuringCopy": true,
                "fileChangedAfterCommit": true, "childAddedAfterCommit": true,
                "incompleteMovesNotCountedAsComplete": true, "bothVolumeDirections": true]
        } else {
            report["externalFixture"] = "not configured; set FASTFIND_TEST_VOLUME_ROOT to an owned test location"
        }
        report["status"] = "passed"
        return report
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw WorkspaceFilesystemTestError.failed(message) }
    }

    private static func write(_ content: String, _ path: URL) throws {
        try Data(content.utf8).write(to: path)
    }
    private static func text(_ path: URL) throws -> String {
        String(decoding: try Data(contentsOf: path), as: UTF8.self)
    }

    @discardableResult
    private static func operation(_ request: FileOperationRequest,
        choice: FileConflictChoice = .skip,
        conflict: ((FileConflict) throws -> Void)? = nil,
        observer: ((FileOperationToken) -> Void)? = nil,
        progressObserver: ((FileOperationProgress, FileOperationToken) -> Void)? = nil,
        testHooks: FileOperationTestHooks? = nil) throws -> FileOperationReport {
        let service = FileOperationService(testHooks: testHooks)
        var report: FileOperationReport?
        var callbackError: Error?
        var callbacksOnMain = true
        var operationToken: FileOperationToken?
        let token = service.start(request: request, resolveConflict: { value, reply in
            callbacksOnMain = callbacksOnMain && Thread.isMainThread
            do { try conflict?(value); reply(choice) }
            catch { callbackError = error; reply(.cancel) }
        }, progress: { value in
            callbacksOnMain = callbacksOnMain && Thread.isMainThread
            if let operationToken = operationToken { progressObserver?(value, operationToken) }
        }, completion: {
            callbacksOnMain = callbacksOnMain && Thread.isMainThread
            report = $0
        })
        operationToken = token
        let deadline = Date().addingTimeInterval(30)
        while report == nil && Date() < deadline {
            observer?(token)
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        if let callbackError = callbackError { throw callbackError }
        guard let result = report else { token.cancel(); throw WorkspaceFilesystemTestError.failed("文件操作测试超时。") }
        try expect(callbacksOnMain, "文件操作回调没有统一在主线程。")
        return result
    }

    private static func browse(_ directory: URL, hidden: Bool) throws -> [DirectoryEntry] {
        var result: Result<[DirectoryEntry], Error>?
        var onMain = false
        DirectoryBrowser().load(path: directory.path, showHidden: hidden) {
            onMain = Thread.isMainThread; result = $0
        }
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard let result = result else { throw WorkspaceFilesystemTestError.failed("目录浏览测试超时。") }
        try expect(onMain, "目录浏览回调未在主线程。")
        return try result.get()
    }

    private static func testVolume(root: URL, symlinks: Bool) throws -> [String: Any] {
        let source = root.appendingPathComponent("源目录")
        let destination = root.appendingPathComponent("目标目录")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let folder = source.appendingPathComponent("中文文件夹")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("合同.txt")
        try write("新合同内容", file)
        try write("隐藏内容", source.appendingPathComponent(".隐藏文件"))
        try write("内部文件", folder.appendingPathComponent("资料.txt"))
        var link: URL?
        if symlinks {
            let loop = folder.appendingPathComponent("循环链接")
            try fm.createSymbolicLink(atPath: loop.path, withDestinationPath: folder.path)
            let broken = source.appendingPathComponent("失效链接")
            try fm.createSymbolicLink(atPath: broken.path, withDestinationPath: root.appendingPathComponent("不存在").path)
            link = broken
        }
        let visible = try browse(source, hidden: false)
        try expect(visible.first?.path == folder.path, "目录浏览没有文件夹优先排序。")
        try expect(!visible.contains(where: { $0.name == ".隐藏文件" }), "目录浏览未隐藏隐藏文件。")
        try expect(visible.first(where: { $0.path == file.path })?.size == Int64(Data("新合同内容".utf8).count), "文件大小错误。")
        let all = try browse(source, hidden: true)
        try expect(all.contains(where: { $0.name == ".隐藏文件" }), "显示隐藏项没有生效。")
        if let link = link {
            try expect(all.first(where: { $0.path == link.path })?.isSymbolicLink == true, "失效链接丢失或被跟随。")
        }

        var result = try operation(FileOperationRequest(kind: .copy, sources: [folder], destination: destination))
        let copiedFolder = destination.appendingPathComponent(folder.lastPathComponent)
        try expect(result.errors.isEmpty && result.completedPaths == [copiedFolder.path], "中文目录复制失败：\(result.errors)")
        try expect(try text(copiedFolder.appendingPathComponent("资料.txt")) == "内部文件", "复制目录内容错误。")
        if symlinks {
            try expect(try fm.destinationOfSymbolicLink(atPath: copiedFolder.appendingPathComponent("循环链接").path) == folder.path,
                       "目录复制错误跟随符号链接。")
        }
        if let link = link {
            result = try operation(FileOperationRequest(kind: .copy, sources: [link], destination: destination))
            try expect(result.errors.isEmpty, "失效链接不能复制。")
            try expect(try fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent(link.lastPathComponent).path)
                == root.appendingPathComponent("不存在").path, "失效链接目标发生变化。")
        }

        let targetFile = destination.appendingPathComponent(file.lastPathComponent)
        try write("原目标内容", targetFile)
        result = try operation(FileOperationRequest(kind: .copy, sources: [file], destination: destination), choice: .skip)
        try expect(result.skipped == 1 && result.errors.isEmpty && (try text(targetFile)) == "原目标内容", "重名跳过损坏原目标。")
        result = try operation(FileOperationRequest(kind: .copy, sources: [file], destination: destination), choice: .keepBoth)
        try expect(result.errors.isEmpty && (try text(destination.appendingPathComponent("合同 (2).txt"))) == "新合同内容", "保留两份没有生成新文件名。")
        result = try operation(FileOperationRequest(kind: .copy, sources: [file], destination: destination), choice: .replace)
        try expect(result.errors.isEmpty && result.recoveryPaths.count == 1 && (try text(targetFile)) == "新合同内容", "重名替换失败。")
        try expect(try text(URL(fileURLWithPath: result.recoveryPaths[0])) == "原目标内容", "替换备份不可恢复。")

        let disappearing = source.appendingPathComponent("替换失败.txt")
        let originalTarget = destination.appendingPathComponent(disappearing.lastPathComponent)
        try write("会消失的源", disappearing)
        try write("必须恢复的原目标", originalTarget)
        result = try operation(FileOperationRequest(kind: .move, sources: [disappearing], destination: destination),
            choice: .replace, conflict: { value in
                try expect(value.source == disappearing, "恢复测试源文件错误。")
                // The owned source disappears after conflict confirmation, a real
                // I/O failure that exercises rollback after destination backup.
                try fm.removeItem(at: disappearing)
            })
        try expect(!result.errors.isEmpty && result.completedPaths.isEmpty, "替换失败没有报告错误。")
        try expect(try text(originalTarget) == "必须恢复的原目标", "替换失败未恢复原目标。")
        try expect(result.recoveryPaths.isEmpty, "已自动恢复的备份仍被报告为遗留恢复项。")

        result = try operation(FileOperationRequest(kind: .copy, sources: [folder], destination: folder))
        try expect(!result.errors.isEmpty, "允许把文件夹复制进自身。")
        result = try operation(FileOperationRequest(kind: .move, sources: [folder, folder.appendingPathComponent("资料.txt")], destination: destination))
        try expect(!result.errors.isEmpty && fm.fileExists(atPath: folder.appendingPathComponent("资料.txt").path), "父子选择未预检拒绝。")
        result = try operation(FileOperationRequest(kind: .copy, sources: [file], destination: source))
        try expect(result.completedPaths.isEmpty && result.skipped == 1, "同路径复制产生错误结果。")

        let renameA = source.appendingPathComponent("改名A.txt"), renameB = source.appendingPathComponent("改名B.txt")
        try write("A", renameA); try write("B", renameB)
        result = try operation(FileOperationRequest(kind: .rename, sources: [renameA, renameB],
            names: [renameA.path: "重复.txt", renameB.path: "重复.txt"]))
        try expect(!result.errors.isEmpty && (try text(renameA)) == "A" && (try text(renameB)) == "B", "批量重名未预检或改变了源文件。")
        result = try operation(FileOperationRequest(kind: .rename, sources: [renameA, renameB],
            names: [renameA.path: "新A.txt", renameB.path: "新B.txt"]))
        try expect(result.errors.isEmpty && result.completedPaths.count == 2, "批量改名失败。")
        let newA = source.appendingPathComponent("新A.txt"), newB = source.appendingPathComponent("新B.txt")
        result = try operation(FileOperationRequest(kind: .rename, sources: [newA], names: [newA.path: newB.lastPathComponent]), choice: .replace)
        try expect(!result.errors.isEmpty && (try text(newA)) == "A" && (try text(newB)) == "B", "改名覆盖了已有文件。")
        result = try operation(FileOperationRequest(kind: .rename, sources: [newA], names: [newA.path: "../越界.txt"]))
        try expect(!result.errors.isEmpty && fm.fileExists(atPath: newA.path), "改名接受越界路径。")

        let created = destination.appendingPathComponent("新建中文文件夹")
        result = try operation(FileOperationRequest(kind: .createFolder, sources: [], destination: created))
        try expect(result.errors.isEmpty && result.completedPaths == [created.path], "新建文件夹失败。")
        result = try operation(FileOperationRequest(kind: .createFolder, sources: [], destination: created))
        try expect(!result.errors.isEmpty, "新建文件夹静默接受重名。")
        result = try operation(FileOperationRequest(kind: .move, sources: [newA], destination: created))
        try expect(result.errors.isEmpty && !fm.fileExists(atPath: newA.path) && (try text(created.appendingPathComponent(newA.lastPathComponent))) == "A", "同卷移动失败。")
        return ["directoryBrowser": true, "mainThreadCallbacks": true, "copyDirectories": true,
                "copySymbolicLinks": symlinks, "conflictSkipKeepBothReplace": true,
                "replacementRecovery": true, "rollbackAfterRealIOFailure": true,
                "rejectSelfAndNestedSelection": true, "batchRenamePreflight": true,
                "renameCannotOverwrite": true, "createFolderAndMove": true]
    }

    private static func cancellation(root: URL) throws {
        let source = root.appendingPathComponent("取消源目录")
        let destination = root.appendingPathComponent("取消目标目录")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let preserved = destination.appendingPathComponent("保留原文件.txt")
        try write("不可删除", preserved)
        let bytes = Data(repeating: 0x71, count: 4 * 1024 * 1024)
        for index in 0..<24 { try bytes.write(to: source.appendingPathComponent("大文件\(index).dat")) }
        var observedPartial = false
        var observedByteProgress = false
        let result = try operation(FileOperationRequest(kind: .copy, sources: [source], destination: destination), observer: { token in
            let children = (try? fm.contentsOfDirectory(atPath: destination.path)) ?? []
            if children.contains(where: { $0.hasPrefix(".QuickFind-传输-") }) {
                observedPartial = true
            }
        }, progressObserver: { value, token in
            if let current = value.currentBytes, current > 0, value.totalBytes == Int64(bytes.count),
               URL(fileURLWithPath: value.currentPath).lastPathComponent.hasPrefix("大文件") {
                observedByteProgress = true
                observedPartial = observedPartial || ((try? fm.contentsOfDirectory(atPath: destination.path)) ?? [])
                    .contains(where: { $0.hasPrefix(".QuickFind-传输-") })
                token.cancel()
            }
        })
        try expect(observedPartial && observedByteProgress && result.cancelled, "未收到当前文件字节进度或未在部分复制期间成功取消。")
        try expect(!fm.fileExists(atPath: destination.appendingPathComponent(source.lastPathComponent).path), "取消后遗留半成品目标。")
        try expect(try text(preserved) == "不可删除", "取消清理误删既有目标文件。")
        try expect(try fm.contentsOfDirectory(atPath: source.path).count == 24, "取消操作改变了源文件。")
        try expect(try fm.contentsOfDirectory(atPath: destination.path).allSatisfy { !$0.hasPrefix(".QuickFind-传输-") }, "取消后遗留暂存目录。")
        let successDestination = root.appendingPathComponent("字节进度目标")
        try fm.createDirectory(at: successDestination, withIntermediateDirectories: false)
        var byteCallbacks = 0
        var usefulByteProgress = false
        var invalidByteProgress = false
        let begin = DispatchTime.now().uptimeNanoseconds
        let copied = try operation(FileOperationRequest(kind: .copy, sources: [source], destination: successDestination),
            progressObserver: { value, _ in
                if let current = value.currentBytes, let total = value.totalBytes {
                    byteCallbacks += 1
                    if current > 0 { usefulByteProgress = true }
                    if current < 0 || current > total || total != Int64(bytes.count) ||
                        !URL(fileURLWithPath: value.currentPath).lastPathComponent.hasPrefix("大文件") {
                        invalidByteProgress = true
                    }
                }
            })
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000_000
        try expect(copied.errors.isEmpty && usefulByteProgress && !invalidByteProgress, "当前文件的字节进度不准确或复制失败。")
        try expect(byteCallbacks <= 3 + Int(ceil(elapsed / 0.2)), "字节进度未节流，主线程回调过多：\(byteCallbacks)。")
        try expect(try fm.contentsOfDirectory(atPath: successDestination.appendingPathComponent(source.lastPathComponent).path).count == 24,
                   "节流字节进度导致目录复制不完整。")
        let waiting = source.appendingPathComponent("等待冲突.txt")
        try write("等待源", waiting)
        try write("等待目标", destination.appendingPathComponent(waiting.lastPathComponent))
        let service = FileOperationService()
        var report: FileOperationReport?
        var token: FileOperationToken?
        token = service.start(request: FileOperationRequest(kind: .copy, sources: [waiting], destination: destination),
            resolveConflict: { _, _ in token?.cancel() }, progress: { _ in }, completion: { report = $0 })
        let deadline = Date().addingTimeInterval(5)
        while report == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try expect(report?.cancelled == true, "等待冲突答复时取消未唤醒队列。")
    }

    private static func crossVolume(sourceRoot: URL, targetRoot: URL) throws {
        let source = sourceRoot.appendingPathComponent("跨卷移动源")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try write("跨卷中文内容", source.appendingPathComponent("合同.txt"))
        let destination = targetRoot.appendingPathComponent("跨卷目标")
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let report = try operation(FileOperationRequest(kind: .move, sources: [source], destination: destination))
        try expect(report.errors.isEmpty && !fm.fileExists(atPath: source.path), "跨卷移动未完成：\(report.errors)")
        try expect(try text(destination.appendingPathComponent("跨卷移动源/合同.txt")) == "跨卷中文内容", "跨卷移动目标内容错误。")

        let changingFolder = sourceRoot.appendingPathComponent("跨卷复制期间变化")
        try fm.createDirectory(at: changingFolder, withIntermediateDirectories: false)
        try Data(repeating: 0x43, count: 48 * 1024 * 1024).write(to: changingFolder.appendingPathComponent("正在复制.dat"))
        let changingDestination = targetRoot.appendingPathComponent("复制期间变化目标")
        try fm.createDirectory(at: changingDestination, withIntermediateDirectories: false)
        let added = changingFolder.appendingPathComponent("复制期间新增.txt")
        var mutated = false
        var mutationError: Error?
        let changedDuringCopy = try operation(FileOperationRequest(kind: .move, sources: [changingFolder], destination: changingDestination), observer: { _ in
            if !mutated && ((try? fm.contentsOfDirectory(atPath: changingDestination.path)) ?? [])
                .contains(where: { $0.hasPrefix(".QuickFind-传输-") }) {
                mutated = true
                do { try write("不能丢失的新增文件", added) } catch { mutationError = error }
            }
        })
        if let mutationError = mutationError { throw mutationError }
        try expect(mutated && !changedDuringCopy.errors.isEmpty && changedDuringCopy.completedPaths.isEmpty,
                   "跨卷复制期间目录变化未被识别。")
        try expect(try text(added) == "不能丢失的新增文件", "跨卷移动删除了复制期间新增的文件。")
        try expect(!fm.fileExists(atPath: changingDestination.appendingPathComponent(changingFolder.lastPathComponent).path),
                   "复制期间变化仍然提交了不完整目标。")

        let changingFile = sourceRoot.appendingPathComponent("提交后修改.txt")
        try write("复制时的原内容", changingFile)
        let afterCommit = try operation(FileOperationRequest(kind: .move, sources: [changingFile], destination: destination),
            testHooks: FileOperationTestHooks(beforeCrossVolumeSourceRemoval: { url in
                try write("提交后新增的内容，必须保留", url)
            }))
        try expect(afterCommit.completedPaths.isEmpty && afterCommit.copiedPaths.count == 1 && !afterCommit.errors.isEmpty,
                   "跨卷移动未删除源文件却被计为移动成功。")
        try expect(try text(changingFile) == "提交后新增的内容，必须保留", "删除前守卫未保留修改后的源文件。")
        try expect(try text(destination.appendingPathComponent(changingFile.lastPathComponent)) == "复制时的原内容",
                   "删除前守卫损坏已提交的副本。")

        let changedAfterCommitFolder = sourceRoot.appendingPathComponent("提交后新增子项")
        try fm.createDirectory(at: changedAfterCommitFolder, withIntermediateDirectories: false)
        try write("原文件", changedAfterCommitFolder.appendingPathComponent("原文件.txt"))
        let addedAfterCommit = changedAfterCommitFolder.appendingPathComponent("提交后新增.txt")
        let newChildReport = try operation(FileOperationRequest(kind: .move, sources: [changedAfterCommitFolder], destination: destination),
            testHooks: FileOperationTestHooks(beforeCrossVolumeSourceRemoval: { url in
                try write("必须保留的新子项", url.appendingPathComponent("提交后新增.txt"))
            }))
        try expect(newChildReport.completedPaths.isEmpty && newChildReport.copiedPaths.count == 1 && !newChildReport.errors.isEmpty,
                   "跨卷移动未检查新增目录子项。")
        try expect(try text(addedAfterCommit) == "必须保留的新子项", "跨卷移动删除了提交后新增的子项。")
    }

    private static func trash(root: URL) throws {
        let source = root.appendingPathComponent("QuickFind-废纸篓测试-" + UUID().uuidString + ".txt")
        try write("只属于自动测试的文件", source)
        let result = try operation(FileOperationRequest(kind: .trash, sources: [source]))
        try expect(result.errors.isEmpty && result.completedPaths == [source.path] && !fm.fileExists(atPath: source.path),
                   "系统废纸篓操作失败：\(result.errors)")
        // Remove only this UUID-owned fixture from the user's trash, leaving all
        // other trash items untouched. The service itself never empties trash.
        let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let candidates = (try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
        for candidate in candidates where candidate.lastPathComponent.hasPrefix(source.deletingPathExtension().lastPathComponent) {
            try fm.removeItem(at: candidate)
        }
    }
}

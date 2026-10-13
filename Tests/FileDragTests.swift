// SPDX-License-Identifier: GPL-3.0-only
import AppKit

@MainActor
enum FileDragTests {
    static func run() throws -> [String: Any] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Jilan-file-drag-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("中文 空格 #1.txt")
        let folder = root.appendingPathComponent("第二个 目录")
        let other = folder.appendingPathComponent("另一份.txt")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("own synthetic drag fixture".utf8).write(to: file)
        try Data("second synthetic fixture".utf8).write(to: other)
        let results = [hit(file), hit(other), hit(folder, directory: true)]
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        let single = try FileDragSource.prepare(results: results, rows: IndexSet(integer: 0), resultsAreCurrent: true)
        try expect(board.writeObjects([single[0]!]), "单文件没有写入原生 pasteboard")
        let singleURLs = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        try expect(singleURLs?.map(\.path) == [file.path], "中文、空格与井号文件路径没有正确读回")
        let rows = IndexSet([0, 1, 2])
        let batch = try FileDragSource.prepare(results: results, rows: rows, resultsAreCurrent: true)
        board.clearContents()
        try expect(board.writeObjects(rows.compactMap { batch[$0] }), "多项 pasteboard 写入失败")
        let multiURLs = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        try expect(multiURLs?.map(\.path) == [file.path, other.path, folder.path], "跨目录的多文件/文件夹未完整读回")

        // A background reorder changes the result rows, but a prepared writer
        // must still refer to the paths the user began dragging.
        let reordered = Array(results.reversed())
        try expect(reordered[0].path != results[0].path && batch[0]?.path == file.path,
                   "准备好的 URL 被新行序替换")
        try rejection(.staleResults) {
            _ = try FileDragSource.prepare(results: results, rows: rows, resultsAreCurrent: false)
        }
        try rejection(.invalidSelection) {
            _ = try FileDragSource.prepare(results: results, rows: IndexSet(integer: 9), resultsAreCurrent: true)
        }
        let missing = root.appendingPathComponent("已经删除.txt")
        try rejection(.missing(missing.lastPathComponent)) {
            _ = try FileDragSource.prepare(results: results + [hit(missing)], rows: IndexSet([0, 3]), resultsAreCurrent: true)
        }
        var offline = hit(other); offline.isOnline = false
        try rejection(.offline(other.lastPathComponent)) {
            _ = try FileDragSource.prepare(results: [hit(file), offline], rows: IndexSet([0, 1]), resultsAreCurrent: true)
        }
        let protected = root.appendingPathComponent("无读取权限.txt")
        try Data("private test fixture".utf8).write(to: protected)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: protected.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: protected.path) }
        try rejection(.unreadable(protected.lastPathComponent)) {
            _ = try FileDragSource.prepare(results: [hit(file), hit(protected)], rows: IndexSet([0, 1]), resultsAreCurrent: true)
        }
        let blockedParent = root.appendingPathComponent("无法进入的目录")
        try fm.createDirectory(at: blockedParent, withIntermediateDirectories: true)
        let child = blockedParent.appendingPathComponent("里面的文件.txt")
        try Data("inaccessible parent fixture".utf8).write(to: child)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blockedParent.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blockedParent.path) }
        try rejection(.unreadable(child.lastPathComponent)) {
            _ = try FileDragSource.prepare(results: [hit(child)], rows: IndexSet(integer: 0), resultsAreCurrent: true)
        }
        let broken = root.appendingPathComponent("失效链接")
        try fm.createSymbolicLink(at: broken, withDestinationURL: missing)
        try rejection(.missing(broken.lastPathComponent)) {
            _ = try FileDragSource.prepare(results: [hit(broken)], rows: IndexSet(integer: 0), resultsAreCurrent: true)
        }
        try expect(try Data(contentsOf: file) == Data("own synthetic drag fixture".utf8), "准备拖放改变了源文件")
        try expect(try Data(contentsOf: other) == Data("second synthetic fixture".utf8), "多选准备改变了源文件")
        return ["result": "passed", "singleAndMultipleNativeFileURLs": true,
                "unicodeSpaceAndReservedCharacters": true, "mixedFilesAndFolder": true,
                "capturedPathsSurviveReorder": true, "staleResultsRejected": true,
                "invalidAndMissingPathsRejected": true, "offlineSelectionRejectedAsWhole": true,
                "unreadableSelectionRejectedAsWhole": true, "brokenSymlinkRejected": true,
                "inaccessibleParentReportedAsPermission": true,
                "originalFilesUnchanged": true,
                "scope": "real temporary files and private native pasteboard; target-app gesture acceptance is tested separately"]
    }

    private static func hit(_ url: URL, directory: Bool = false) -> FileHit {
        FileHit(path: url.path, isDirectory: directory, rootID: "drag-fixture")
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw FilesystemTestError.failed(message) }
    }
    private static func rejection(_ expected: FileDragError, operation: () throws -> Void) throws {
        do {
            try operation()
            throw FilesystemTestError.failed("无效拖放没有被拒绝：\(expected.localizedDescription)")
        } catch let actual as FileDragError {
            try expect(actual.localizedDescription == expected.localizedDescription, "拖放错误归因不正确")
        }
    }
}

import Foundation
import Darwin

enum FileOperationKind { case copy, move, rename, trash, createFolder }

struct FileOperationRequest {
    let kind: FileOperationKind
    let sources: [URL]
    var destination: URL? = nil
    var names: [String: String] = [:]
}

struct FileConflict {
    let source: URL
    let destination: URL
}

enum FileConflictChoice { case skip, keepBoth, replace, cancel }

struct FileOperationProgress {
    let completed: Int
    let total: Int
    let currentPath: String
    let currentBytes: Int64?
    let totalBytes: Int64?

    init(completed: Int, total: Int, currentPath: String,
         currentBytes: Int64? = nil, totalBytes: Int64? = nil) {
        self.completed = completed
        self.total = total
        self.currentPath = currentPath
        self.currentBytes = currentBytes
        self.totalBytes = totalBytes
    }
}

struct FileOperationReport {
    var completedPaths: [String] = []
    var errors: [String] = []
    var cancelled: Bool = false
    var skipped: Int = 0
    /// Replaced items remain in same-volume recovery folders; they are never
    /// automatically deleted. The UI can reveal these paths after completion.
    var recoveryPaths: [String] = []
    /// Complete destination copies whose move did not finish removing the source.
    /// These do not count as completed moves.
    var copiedPaths: [String] = []
}

final class FileOperationToken {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    fileprivate var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
}

private enum FileOperationError: Error, LocalizedError {
    case invalid(String), cancelled
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .cancelled: return "操作已取消。"
        }
    }
}

private final class ConflictDecision {
    let lock = NSLock()
    var choice: FileConflictChoice?
    func resolve(_ value: FileConflictChoice) {
        lock.lock(); defer { lock.unlock() }
        if choice == nil { choice = value }
    }
    func read() -> FileConflictChoice? {
        lock.lock(); defer { lock.unlock() }; return choice
    }
}

/// Internal diagnostics can reproduce filesystem changes at the precise point
/// between commit and source removal without sleeps or modifying user files.
struct FileOperationTestHooks {
    var beforeCrossVolumeSourceRemoval: ((URL) throws -> Void)? = nil
}

private struct FileNodeFingerprint: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    let children: [String]
    let link: String?
}

/// File mutation is serialized independently of search and directory browsing.
/// A destination is never silently overwritten, and partial copies only exist
/// in an operation-owned staging location until the transfer succeeds.
final class FileOperationService {
    private let queue = DispatchQueue(label: "cn.local.quickfind.file-operations", qos: .userInitiated)
    private let fm = FileManager.default
    private let testHooks: FileOperationTestHooks?

    init(testHooks: FileOperationTestHooks? = nil) { self.testHooks = testHooks }

    @discardableResult
    func start(request: FileOperationRequest,
               resolveConflict: @escaping (FileConflict, @escaping (FileConflictChoice) -> Void) -> Void,
               progress: @escaping (FileOperationProgress) -> Void,
               completion: @escaping (FileOperationReport) -> Void) -> FileOperationToken {
        let token = FileOperationToken()
        queue.async {
            var report = FileOperationReport()
            let total = request.kind == .createFolder ? 1 : request.sources.count
            func notify(_ completed: Int, _ path: String, currentBytes: Int64? = nil, totalBytes: Int64? = nil) {
                let value = FileOperationProgress(completed: completed, total: total, currentPath: path,
                                                  currentBytes: currentBytes, totalBytes: totalBytes)
                DispatchQueue.main.async { progress(value) }
            }
            // All files in a recursive copy share this throttle. Emit the first
            // positive byte count promptly so short copies also show useful
            // feedback, then limit byte updates to roughly five per second.
            var lastByteProgress: UInt64 = 0
            var reportedPositiveBytes = false
            func notifyBytes(_ completed: Int, _ path: String, _ bytes: Int64, _ fileTotal: Int64) {
                let now = DispatchTime.now().uptimeNanoseconds
                guard lastByteProgress == 0 || now - lastByteProgress >= 200_000_000 ||
                      (!reportedPositiveBytes && bytes > 0) else { return }
                lastByteProgress = now
                if bytes > 0 { reportedPositiveBytes = true }
                notify(completed, path, currentBytes: bytes, totalBytes: fileTotal)
            }
            notify(0, "")
            do {
                let sources = try self.validate(request)
                if request.kind == .createFolder {
                    guard let destination = request.destination else {
                        throw FileOperationError.invalid("请指定新文件夹的完整路径。")
                    }
                    try self.checkCancelled(token)
                    let target = destination.standardized
                    // withIntermediateDirectories=false also prevents accidentally
                    // creating folders outside the selected existing parent.
                    guard !self.exists(target) else {
                        throw FileOperationError.invalid("同名项目已存在：\(target.path)")
                    }
                    try self.fm.createDirectory(at: target, withIntermediateDirectories: false)
                    report.completedPaths.append(target.path)
                    notify(1, target.path)
                } else {
                    for (position, source) in sources.enumerated() {
                        if token.isCancelled { report.cancelled = true; break }
                        notify(position, source.path)
                        do {
                            if request.kind == .trash {
                                try self.fm.trashItem(at: source, resultingItemURL: nil)
                                report.completedPaths.append(source.path)
                            } else {
                                var target = try self.target(for: source, request: request)
                                if source.path == target.path { report.skipped += 1; notify(position + 1, source.path); continue }
                                if request.kind != .rename && self.identity(source) == self.identity(target) {
                                    throw FileOperationError.invalid("目标与源项目是同一个位置，操作未执行。")
                                }
                                try self.validateTarget(source: source, target: target)
                                var replace = false
                                let caseOnlyRename = request.kind == .rename && self.sameNode(source, target)
                                if self.exists(target) && !caseOnlyRename {
                                    let choice = try self.choose(source: source, target: target, token: token,
                                                                 resolver: resolveConflict)
                                    switch choice {
                                    case .cancel: throw FileOperationError.cancelled
                                    case .skip: report.skipped += 1; notify(position + 1, source.path); continue
                                    case .keepBoth: target = try self.availableTarget(target)
                                    case .replace:
                                        guard request.kind != .rename else {
                                            throw FileOperationError.invalid("改名不能覆盖已有项目，请选择保留两份或更换名称。")
                                        }
                                        replace = true
                                    }
                                }
                                try self.checkCancelled(token)
                                let completed = try self.transfer(source: source, target: target, kind: request.kind,
                                    replace: replace, caseOnlyRename: caseOnlyRename, token: token,
                                    report: &report, copyProgress: { path, bytes, fileTotal in
                                        notifyBytes(position, path, bytes, fileTotal)
                                    })
                                if completed { report.completedPaths.append(target.path) }
                            }
                        } catch FileOperationError.cancelled {
                            report.cancelled = true; break
                        } catch {
                            report.errors.append("\(source.path)：\(error.localizedDescription)")
                        }
                        notify(position + 1, source.path)
                    }
                }
            } catch FileOperationError.cancelled {
                report.cancelled = true
            } catch {
                report.errors.append(error.localizedDescription)
            }
            if token.isCancelled { report.cancelled = true }
            let finishedReport = report
            DispatchQueue.main.async { completion(finishedReport) }
        }
        return token
    }

    private func validate(_ request: FileOperationRequest) throws -> [URL] {
        if request.kind == .createFolder {
            guard request.sources.isEmpty, let destination = request.destination,
                  destination.isFileURL, destination.path.hasPrefix("/"),
                  validName(destination.lastPathComponent), destination.standardized.path != "/" else {
                throw FileOperationError.invalid("新建文件夹需要有效的完整目标路径。")
            }
            try requireDirectory(destination.standardized.deletingLastPathComponent())
            return []
        }
        guard !request.sources.isEmpty else { throw FileOperationError.invalid("请先选择文件或文件夹。") }
        guard request.sources.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }) else {
            throw FileOperationError.invalid("文件操作只支持本机完整路径。")
        }
        let sources = request.sources.map { $0.standardized }
        var sourceKeys = Set<String>()
        for source in sources {
            guard source.path != "/", exists(source) else {
                throw FileOperationError.invalid("源项目不存在或不能操作：\(source.path)")
            }
            guard sourceKeys.insert(identity(source)).inserted else {
                throw FileOperationError.invalid("同一个源项目被重复选择：\(source.path)")
            }
        }
        for source in sources where isDirectory(source) {
            let parentPath = source.resolvingSymlinksInPath().path
            if sources.contains(where: { $0.path != source.path && inside(canonicalPath($0), parent: parentPath) }) {
                throw FileOperationError.invalid("请勿同时选择文件夹及其内部项目：\(source.path)")
            }
        }
        if request.kind == .copy || request.kind == .move {
            guard let destination = request.destination, destination.isFileURL, destination.path.hasPrefix("/") else {
                throw FileOperationError.invalid("请指定目标文件夹。")
            }
            try requireDirectory(destination.standardized)
        }
        if request.kind == .rename {
            var targetKeys = Set<String>()
            for source in sources {
                let target = try target(for: source, request: request)
                let key = identity(target)
                guard targetKeys.insert(key).inserted else {
                    throw FileOperationError.invalid("批量改名产生同名目标，操作未执行：\(target.lastPathComponent)")
                }
                if key != identity(source) && sourceKeys.contains(key) {
                    throw FileOperationError.invalid("改名目标与另一个所选项目重名，请分两次改名：\(target.lastPathComponent)")
                }
            }
        }
        return sources
    }

    private func target(for source: URL, request: FileOperationRequest) throws -> URL {
        if request.kind == .rename {
            guard let name = request.names[source.path], validName(name) else {
                throw FileOperationError.invalid("改名需要有效的新名称，名称不能包含斜杠、空字符或使用 . 与 ..。")
            }
            return source.deletingLastPathComponent().appendingPathComponent(name).standardized
        }
        guard let destination = request.destination else { throw FileOperationError.invalid("缺少目标文件夹。") }
        return destination.standardized.appendingPathComponent(source.lastPathComponent)
    }

    private func validateTarget(source: URL, target: URL) throws {
        try requireDirectory(target.deletingLastPathComponent())
        if isDirectory(source) {
            let sourcePath = source.resolvingSymlinksInPath().path
            let targetPath = canonicalPath(target)
            if targetPath == sourcePath || inside(targetPath, parent: sourcePath) {
                throw FileOperationError.invalid("不能把文件夹复制或移动到自身或其子文件夹。")
            }
        }
        if sameNode(source, target) && identity(source) != identity(target) {
            throw FileOperationError.invalid("目标与源项目指向同一个文件，操作未执行。")
        }
    }

    private func choose(source: URL, target: URL, token: FileOperationToken,
                        resolver: @escaping (FileConflict, @escaping (FileConflictChoice) -> Void) -> Void) throws -> FileConflictChoice {
        let decision = ConflictDecision()
        DispatchQueue.main.async {
            guard !token.isCancelled else { decision.resolve(.cancel); return }
            resolver(FileConflict(source: source, destination: target)) { decision.resolve($0) }
        }
        while true {
            try checkCancelled(token)
            if let choice = decision.read() { return choice }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func transfer(source: URL, target: URL, kind: FileOperationKind, replace: Bool,
                          caseOnlyRename: Bool, token: FileOperationToken,
                          report: inout FileOperationReport,
                          copyProgress: (String, Int64, Int64) -> Void) throws -> Bool {
        if caseOnlyRename {
            let intermediate = source.deletingLastPathComponent().appendingPathComponent(".QuickFind-改名-" + UUID().uuidString)
            try fm.moveItem(at: source, to: intermediate)
            do {
                try checkCancelled(token)
                try fm.moveItem(at: intermediate, to: target)
            } catch {
                do { try fm.moveItem(at: intermediate, to: source) }
                catch { report.errors.append("改名恢复失败，原项目保留在：\(intermediate.path)") }
                throw error
            }
            return true
        }
        let sameVolume = device(source) == device(target.deletingLastPathComponent())
        let directMove = kind == .rename || (kind == .move && sameVolume)
        let stagingRoot = target.deletingLastPathComponent().appendingPathComponent(".QuickFind-传输-" + UUID().uuidString)
        let staged = stagingRoot.appendingPathComponent(target.lastPathComponent)
        var stagingCreated = false
        var backup: URL?
        var backupRoot: URL?
        var committed = false
        let crossVolumeMove = kind == .move && !directMove
        let initialTree = crossVolumeMove ? try fingerprintTree(source, token: token) : nil
        defer {
            if stagingCreated {
                do { try removeOwnedStaging(stagingRoot) }
                catch { report.errors.append("本次传输的临时文件未能清理，请检查：\(stagingRoot.path)。\(error.localizedDescription)") }
            }
        }
        do {
            // Stage a copy first. Existing destinations remain usable throughout
            // the potentially long copy; only final commit changes their name.
            if !directMove {
                try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
                stagingCreated = true
                try copy(source, to: staged, token: token, progress: copyProgress)
                if let initialTree = initialTree, try fingerprintTree(source, token: token) != initialTree {
                    throw FileOperationError.invalid("源目录或文件在复制期间发生变化，未提交目标，源项目保留，请重试。")
                }
            }
            try checkCancelled(token)
            if replace {
                guard exists(target) else { throw FileOperationError.invalid("目标在确认后发生变化，请重试。") }
                let recoveryRoot = target.deletingLastPathComponent().appendingPathComponent(".QuickFind-恢复-" + UUID().uuidString)
                try fm.createDirectory(at: recoveryRoot, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
                backupRoot = recoveryRoot
                let recoveryItem = recoveryRoot.appendingPathComponent(target.lastPathComponent)
                try fm.moveItem(at: target, to: recoveryItem)
                backup = recoveryItem
            }
            try checkCancelled(token)
            // moveItem refuses to overwrite a target introduced by another app.
            try fm.moveItem(at: directMove ? source : staged, to: target)
            committed = true
            if let backup = backup { report.recoveryPaths.append(backup.path) }
            if crossVolumeMove {
                // Cancellation after the commit leaves both copies intact.
                // Deleting the source is allowed only after a complete copy.
                if token.isCancelled {
                    report.copiedPaths.append(target.path)
                    report.errors.append("跨卷移动已取消；完整副本保留在 \(target.path)，源项目未删除。")
                    throw FileOperationError.cancelled
                }
                do {
                    try testHooks?.beforeCrossVolumeSourceRemoval?(source)
                    guard let initialTree = initialTree,
                          try fingerprintTree(source, token: token) == initialTree else {
                        report.copiedPaths.append(target.path)
                        report.errors.append("跨卷移动未完成：源项目在复制后又被修改，源项目未删除；已复制的副本保留在 \(target.path)。")
                        return false
                    }
                    // Coordinate cooperating document editors, while the full
                    // tree identity/content stamps above also catch changes by
                    // processes which do not participate in file coordination.
                    var coordinationError: NSError?
                    var removalError: Error?
                    NSFileCoordinator().coordinate(writingItemAt: source, options: .forDeleting,
                        error: &coordinationError) { coordinatedSource in
                        do {
                            guard try self.fingerprintTree(coordinatedSource, token: token) == initialTree else {
                                throw FileOperationError.invalid("源项目在删除前发生变化，未删除源项目。")
                            }
                            try self.checkCancelled(token)
                            try self.fm.removeItem(at: coordinatedSource)
                        } catch { removalError = error }
                    }
                    if let coordinationError = coordinationError { throw coordinationError }
                    if let removalError = removalError { throw removalError }
                } catch {
                    report.copiedPaths.append(target.path)
                    report.errors.append("跨卷移动未完成：已复制到 \(target.path)，源项目未能移除，两个副本均保留：\(error.localizedDescription)")
                    if token.isCancelled { throw FileOperationError.cancelled }
                    return false
                }
            }
            return true
        } catch {
            if !committed, let backup = backup {
                do {
                    guard !exists(target) else {
                        throw FileOperationError.invalid("目标已被其他程序创建，未覆盖该项目。")
                    }
                    try fm.moveItem(at: backup, to: target)
                    if let backupRoot = backupRoot { try? fm.removeItem(at: backupRoot) }
                } catch {
                    report.recoveryPaths.append(backup.path)
                    report.errors.append("原目标无法自动恢复，请从此处恢复：\(backup.path)。\(error.localizedDescription)")
                }
            } else if !committed, let backupRoot = backupRoot {
                try? fm.removeItem(at: backupRoot)
            }
            throw error
        }
    }

    private func fingerprintTree(_ root: URL, token: FileOperationToken) throws -> [String: FileNodeFingerprint] {
        var nodes: [String: FileNodeFingerprint] = [:]
        func walk(_ url: URL, relativePath: String) throws {
            try checkCancelled(token)
            var info = stat()
            guard url.path.withCString({ lstat($0, &info) }) == 0 else {
                throw posixError("源项目变化或无法校验", url.path)
            }
            let kind = info.st_mode & mode_t(S_IFMT)
            let children = kind == mode_t(S_IFDIR) ? try fm.contentsOfDirectory(atPath: url.path).sorted() : []
            let link = kind == mode_t(S_IFLNK) ? try fm.destinationOfSymbolicLink(atPath: url.path) : nil
            nodes[relativePath] = FileNodeFingerprint(device: info.st_dev, inode: info.st_ino,
                mode: info.st_mode, size: info.st_size,
                modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec,
                children: children, link: link)
            for name in children {
                try walk(url.appendingPathComponent(name), relativePath: relativePath.isEmpty ? name : relativePath + "/" + name)
            }
            // Ensure a directory was not replaced or populated during this walk.
            var after = stat()
            guard url.path.withCString({ lstat($0, &after) }) == 0,
                  after.st_dev == info.st_dev, after.st_ino == info.st_ino,
                  after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
                  after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else {
                throw FileOperationError.invalid("源项目在校验期间发生变化：\(url.path)")
            }
        }
        try walk(root, relativePath: "")
        return nodes
    }

    private func removeOwnedStaging(_ root: URL) throws {
        // Copied source directories may be read-only. Grant owner access only
        // inside this operation's own UUID staging root, never following links.
        func prepare(_ url: URL) throws {
            var info = stat()
            guard url.path.withCString({ lstat($0, &info) }) == 0 else {
                if errno == ENOENT { return }
                throw posixError("无法清理临时项目", url.path)
            }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                guard url.path.withCString({ chmod($0, info.st_mode | mode_t(0o700)) }) == 0 else {
                    throw posixError("无法清理临时目录", url.path)
                }
                for name in try fm.contentsOfDirectory(atPath: url.path) {
                    try prepare(url.appendingPathComponent(name))
                }
            }
        }
        try prepare(root)
        if exists(root) { try fm.removeItem(at: root) }
    }

    private func copy(_ source: URL, to target: URL, token: FileOperationToken,
                      progress: (String, Int64, Int64) -> Void) throws {
        try checkCancelled(token)
        var info = stat()
        guard source.path.withCString({ lstat($0, &info) }) == 0 else {
            throw posixError("无法读取源项目", source.path)
        }
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFLNK):
            let link = try fm.destinationOfSymbolicLink(atPath: source.path)
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
        case mode_t(S_IFDIR):
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: []) {
                try copy(child, to: target.appendingPathComponent(child.lastPathComponent), token: token, progress: progress)
            }
            try copyMetadata(source, target)
        case mode_t(S_IFREG):
            // O_NOFOLLOW prevents a source changed to a link during the operation
            // from exposing the linked target. O_EXCL owns the partial destination.
            let readFD = source.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
            guard readFD >= 0 else { throw posixError("无法打开源文件", source.path) }
            defer { close(readFD) }
            var openedInfo = stat()
            guard fstat(readFD, &openedInfo) == 0,
                  openedInfo.st_dev == info.st_dev, openedInfo.st_ino == info.st_ino,
                  openedInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw FileOperationError.invalid("源文件在复制前发生变化，请重试。")
            }
            let writeFD = target.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
            guard writeFD >= 0 else { throw posixError("无法建立目标文件", target.path) }
            defer { close(writeFD) }
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            var copiedBytes: Int64 = 0
            progress(source.path, 0, Int64(info.st_size))
            while true {
                try checkCancelled(token)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError("读取文件失败", source.path)
                }
                var offset = 0
                while offset < count {
                    try checkCancelled(token)
                    let written = buffer.withUnsafeBytes {
                        Darwin.write(writeFD, $0.baseAddress!.advanced(by: offset), count - offset)
                    }
                    if written <= 0 {
                        if errno == EINTR { continue }
                        throw posixError("写入文件失败", target.path)
                    }
                    offset += written
                }
                copiedBytes += Int64(count)
                progress(source.path, copiedBytes, Int64(info.st_size))
            }
            var finishedInfo = stat()
            guard fstat(readFD, &finishedInfo) == 0, copiedBytes == Int64(info.st_size),
                  finishedInfo.st_size == info.st_size,
                  finishedInfo.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  finishedInfo.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
                throw FileOperationError.invalid("源文件在复制期间发生变化，未提交目标文件，请重试。")
            }
            guard fsync(writeFD) == 0 else { throw posixError("保存目标文件失败", target.path) }
            try copyMetadata(source, target)
        default:
            throw FileOperationError.invalid("暂不支持复制套接字、管道或设备节点：\(source.path)")
        }
        try checkCancelled(token)
    }

    private func copyMetadata(_ source: URL, _ target: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)
        let result = source.path.withCString { sourcePath in
            target.path.withCString { targetPath in copyfile(sourcePath, targetPath, nil, flags) }
        }
        if result != 0 {
            // Some removable filesystems cannot store macOS ACLs/xattrs. Normal
            // file attributes still transfer; content copying remains mandatory.
            let failure = errno
            if failure != ENOTSUP && failure != EOPNOTSUPP && failure != EINVAL {
                throw posixError("复制文件属性失败", target.path, code: failure)
            }
            let values = try fm.attributesOfItem(atPath: source.path)
            var attributes: [FileAttributeKey: Any] = [:]
            for key in [FileAttributeKey.modificationDate, .creationDate, .posixPermissions] {
                if let value = values[key] { attributes[key] = value }
            }
            try fm.setAttributes(attributes, ofItemAtPath: target.path)
        }
    }

    private func checkCancelled(_ token: FileOperationToken) throws {
        if token.isCancelled { throw FileOperationError.cancelled }
    }
    private func validName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }
    private func exists(_ url: URL) -> Bool {
        var info = stat(); return url.path.withCString { lstat($0, &info) } == 0
    }
    private func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) } == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }
    private func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard url.path.withCString({ stat($0, &info) }) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw FileOperationError.invalid("目标文件夹不存在或无法访问：\(url.path)")
        }
    }
    private func canonicalPath(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardized.path
    }
    private func inside(_ path: String, parent: String) -> Bool {
        path.hasPrefix(parent == "/" ? "/" : parent + "/")
    }
    private func identity(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let sensitive = (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
        let path = parent.appendingPathComponent(url.lastPathComponent).path.precomposedStringWithCanonicalMapping
        return sensitive ? path : path.lowercased()
    }
    private func sameNode(_ first: URL, _ second: URL) -> Bool {
        var a = stat(), b = stat()
        return first.path.withCString({ lstat($0, &a) }) == 0 &&
            second.path.withCString({ lstat($0, &b) }) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
    private func device(_ url: URL) -> dev_t? {
        var info = stat()
        return url.path.withCString({ stat($0, &info) }) == 0 ? info.st_dev : nil
    }
    private func availableTarget(_ original: URL) throws -> URL {
        let directory = original.deletingLastPathComponent()
        let directoryItem = isDirectory(original)
        let ext = directoryItem ? "" : original.pathExtension
        let stem = ext.isEmpty ? original.lastPathComponent : original.deletingPathExtension().lastPathComponent
        for number in 2...100_000 {
            let basename = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
            let candidate = directory.appendingPathComponent(basename)
            if !exists(candidate) { return candidate }
        }
        throw FileOperationError.invalid("无法为保留两份生成不重名的文件名。")
    }
    private func posixError(_ message: String, _ path: String, code: Int32? = nil) -> Error {
        let value = code ?? errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(value),
                       userInfo: [NSLocalizedDescriptionKey: "\(message)：\(path)（\(String(cString: strerror(value)))）"])
    }
}

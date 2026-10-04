import Foundation
import Darwin

struct ScanReport {
    var count: Int
    var issues: [ScanIssue]
    /// False when cancelled or traversal itself could not reach the end.
    /// Permission issues are separately reported even if traversal finishes.
    var completed: Bool
    var elapsedMilliseconds: Double
    var totalIssueCount: Int = 0
}

enum FileScanner {
    static func scan(
        path: String,
        excludedPrefixes: [String],
        cancelled: () -> Bool,
        onEntry: (String, Bool) -> Void,
        onProgress: (Int, String) -> Void,
        onIOIntent: ((String) -> Void)? = nil,
        indexEntry: ((String, Bool) -> (changed: Bool, count: Int))? = nil
    ) -> ScanReport {
        ScanWorker.scan(path: path, excludedPrefixes: excludedPrefixes, cancelled: cancelled,
                        onEntry: onEntry, onProgress: onProgress, onIOIntent: onIOIntent, indexEntry: indexEntry)
    }

    /// A physical name-only walk. Directory descriptors anchor each descent;
    /// a name replaced by a symlink cannot redirect a later directory open.
    /// File contents are never opened, including FIFOs and other special nodes.
    static func walk(
        path: String,
        excludedPrefixes: [String],
        cancelled: () -> Bool,
        onEntry: (String, Bool) -> Void,
        onProgress: (Int, String) -> Void,
        onIOIntent: ((String) -> Void)? = nil
    ) -> ScanReport {
        let began = DispatchTime.now().uptimeNanoseconds
        let root = normalized(path)
        let exclusions = Array(Set(excludedPrefixes.map(normalized))).sorted()
        var count = 0
        var issues: [ScanIssue] = []
        var totalIssueCount = 0
        var completed = false
        var latestPath = root
        var lastProgress = began
        struct DirectoryFrame {
            var path: String
            var stream: UnsafeMutablePointer<DIR>
        }
        var stack: [DirectoryFrame] = []
        // fdopendir owns its descriptor on success; every active frame has one
        // owner, including cancellation and per-directory error paths.
        defer { for frame in stack.reversed() { closedir(frame.stream) } }

        func record(_ problemPath: String, _ message: String) {
            totalIssueCount += 1
            if issues.count < 1000 { issues.append(ScanIssue(path: problemPath, message: message)) }
        }
        func result() -> ScanReport {
            onProgress(count, latestPath)
            return ScanReport(count: count, issues: issues, completed: completed,
                              elapsedMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000,
                              totalIssueCount: totalIssueCount)
        }
        func isExcluded(_ fullPath: String) -> Bool {
            exclusions.contains { contains(fullPath, in: $0) }
        }
        func indexed(_ fullPath: String, directory: Bool) {
            latestPath = fullPath
            onEntry(fullPath, directory)
            count += 1
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastProgress >= 200_000_000 {
                lastProgress = now
                onProgress(count, fullPath)
            }
        }
        func directoryStream(parent: Int32, name: String, fullPath: String,
                             identity: (dev_t, ino_t)? = nil) -> UnsafeMutablePointer<DIR>? {
            onIOIntent?(fullPath)
            guard !cancelled() else { return nil }
            let descriptor = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                let code = errno
                record(fullPath, "目录无法读取：" + errorDescription(code))
                return nil
            }
            if let identity {
                onIOIntent?(fullPath)
                guard !cancelled() else { close(descriptor); return nil }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0 else {
                    let code = errno
                    close(descriptor)
                    record(fullPath, "目录属性无法读取：" + errorDescription(code))
                    return nil
                }
                guard opened.st_dev == identity.0 && opened.st_ino == identity.1 else {
                    close(descriptor)
                    record(fullPath, "扫描期间目录已变化：" + errorDescription(ENOENT))
                    return nil
                }
            }
            onIOIntent?(fullPath)
            guard !cancelled() else { close(descriptor); return nil }
            guard let stream = fdopendir(descriptor) else {
                let code = errno
                close(descriptor)
                record(fullPath, "目录无法读取：" + errorDescription(code))
                return nil
            }
            return stream
        }

        guard !cancelled() else { return result() }
        guard !root.isEmpty else {
            record(root, "无法准备扫描路径")
            return result()
        }
        if isExcluded(root) { completed = true; return result() }
        onIOIntent?(root)
        guard !cancelled() else { return result() }
        var rootAttributes = stat()
        let rootCode = root.withCString { fstatat(AT_FDCWD, $0, &rootAttributes, AT_SYMLINK_NOFOLLOW) }
        guard rootCode == 0 else {
            let code = errno
            record(root, "项目无法读取：" + errorDescription(code))
            // This is a reported node error, rather than an unfinished walk.
            completed = !cancelled()
            return result()
        }
        let rootIsDirectory = rootAttributes.st_mode & S_IFMT == S_IFDIR
        indexed(root, directory: rootIsDirectory)
        if !rootIsDirectory { completed = !cancelled(); return result() }
        guard let rootStream = directoryStream(parent: AT_FDCWD, name: root, fullPath: root,
                                               identity: (rootAttributes.st_dev, rootAttributes.st_ino)) else {
            completed = !cancelled()
            return result()
        }
        stack.append(DirectoryFrame(path: root, stream: rootStream))

        while !cancelled(), let frame = stack.last {
            // Unlike fts_read, no hidden path-based descent happens here.
            // Intent identifies the directory whose syscall may be waiting.
            onIOIntent?(frame.path)
            guard !cancelled() else { break }
            errno = 0
            guard let entry = readdir(frame.stream) else {
                let code = errno
                if code != 0 { record(frame.path, "目录读取中断：" + errorDescription(code)) }
                closedir(frame.stream)
                stack.removeLast()
                continue
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            let fullPath = frame.path == "/" ? "/" + name : frame.path + "/" + name
            if isExcluded(fullPath) { continue }
            let type = Int32(entry.pointee.d_type)
            var isDirectory = type == DT_DIR
            if type == DT_UNKNOWN {
                onIOIntent?(fullPath)
                guard !cancelled() else { break }
                var attributes = stat()
                let code = name.withCString { fstatat(dirfd(frame.stream), $0, &attributes, AT_SYMLINK_NOFOLLOW) }
                guard code == 0 else {
                    let number = errno
                    record(fullPath, "项目无法读取：" + errorDescription(number))
                    continue
                }
                isDirectory = attributes.st_mode & S_IFMT == S_IFDIR
            }
            indexed(fullPath, directory: isDirectory)
            guard !cancelled() else { break }
            if isDirectory, let child = directoryStream(parent: dirfd(frame.stream), name: name, fullPath: fullPath) {
                stack.append(DirectoryFrame(path: fullPath, stream: child))
            }
        }
        completed = !cancelled() && stack.isEmpty
        return result()
    }

    private static func normalized(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        // Keep physical roots and real filename whitespace intact.
        return URL(fileURLWithPath: path).standardized.path
    }

    private static func contains(_ path: String, in excluded: String) -> Bool {
        guard !excluded.isEmpty else { return false }
        return path == excluded || (excluded == "/" ? path.hasPrefix("/") : path.hasPrefix(excluded + "/"))
    }

    private static func errorDescription(_ number: Int32) -> String {
        switch number {
        case EACCES, EPERM: return "权限不足（\(number)）；可检查完全磁盘访问权限"
        case ENOENT: return "扫描期间路径已消失（\(number)）"
        case 0: return "系统未提供错误代码"
        default: return String(cString: strerror(number)) + "（\(number)）"
        }
    }
}

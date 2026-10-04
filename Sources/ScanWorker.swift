import Foundation
import Darwin

/// A scanner process has the same executable and permissions as the app. Its
/// filesystem waits cannot hold the application's index queue indefinitely.
enum ScanWorker {
    struct Options {
        var inactivityTimeout: TimeInterval = 10
        var maximumTimeoutRetries: Int = 3
        // Only tests explicitly supply these seams; the normal scan uses neither.
        var stallOnceAtPath: String? = nil
        var exitBeforeReport: Bool = false
        var wireFault: String? = nil
        var childStarted: ((pid_t) -> Void)? = nil
    }
    private struct Request: Codable {
        var path: String
        var excludedPrefixes: [String]
        var stallAtPath: String?
        var exitBeforeReport: Bool
        var wireFault: String?
    }
    private struct WireReport: Codable {
        struct Issue: Codable { var path: String; var message: String }
        var count: Int
        var issues: [Issue]
        var completed: Bool
        var totalIssueCount: Int
    }
    private static let maximumFrame = 2 * 1024 * 1024
    private static let childLock = NSLock()
    private static var children = Set<pid_t>()
    private static var quarantined = Set<pid_t>()
    private enum Failure { case cancelled, timeout(String), invalid(String) }
    private struct Attempt { var report: WireReport?; var failure: Failure? }

    static func scan(path: String, excludedPrefixes: [String], cancelled: () -> Bool,
                     onEntry: (String, Bool) -> Void, onProgress: (Int, String) -> Void,
                     onIOIntent: ((String) -> Void)? = nil,
                     indexEntry: ((String, Bool) -> (changed: Bool, count: Int))? = nil) -> ScanReport {
        scan(path: path, excludedPrefixes: excludedPrefixes, cancelled: cancelled,
             onEntry: onEntry, onProgress: onProgress, onIOIntent: onIOIntent, indexEntry: indexEntry, options: Options())
    }

    static func scan(path: String, excludedPrefixes: [String], cancelled: () -> Bool,
                     onEntry: (String, Bool) -> Void, onProgress: (Int, String) -> Void,
                     onIOIntent: ((String) -> Void)? = nil,
                     indexEntry: ((String, Bool) -> (changed: Bool, count: Int))? = nil,
                     options: Options) -> ScanReport {
        let start = now()
        let root = path.isEmpty ? "" : URL(fileURLWithPath: path).standardized.path
        var exclusions = excludedPrefixes.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).standardized.path }, issues: [ScanIssue] = [], totalIssues = 0
        // A hosted scan uses its fresh staging index as the exact path/type
        // ledger. Keeping another full-path dictionary here doubled scan memory.
        // Generic callbacks have no ledger: preserve their single-pass count,
        // and return incomplete on a timeout rather than replaying duplicates.
        let retries = indexEntry == nil ? 0 : max(0, min(3, options.maximumTimeoutRetries))
        var indexedCount = 0
        var latestPath = root
        func report(_ completed: Bool) -> ScanReport {
            ScanReport(count: indexedCount, issues: Array(issues.prefix(1000)), completed: completed,
                       elapsedMilliseconds: (now() - start) * 1000, totalIssueCount: totalIssues)
        }
        func issue(_ path: String, _ message: String) {
            totalIssues += 1
            if issues.count < 1000 { issues.append(ScanIssue(path: path, message: message)) }
        }
        guard !cancelled() else { return report(false) }
        guard validPath(root) else { issue(root, "无法准备扫描路径"); return report(false) }
        for attempt in 0...retries {
            guard !cancelled() else { return report(false) }
            let request = Request(path: root, excludedPrefixes: exclusions,
                                  stallAtPath: attempt == 0 ? options.stallOnceAtPath : nil,
                                  exitBeforeReport: options.exitBeforeReport, wireFault: options.wireFault)
            let result = run(request, timeout: max(0.05, options.inactivityTimeout), cancelled: cancelled,
                onEntry: { entry, directory in
                    guard !cancelled() else { return }
                    latestPath = entry
                    if let indexEntry {
                        let accepted = indexEntry(entry, directory)
                        indexedCount = max(0, accepted.count)
                        if accepted.changed { onEntry(entry, directory) }
                    } else {
                        indexedCount += 1
                        onEntry(entry, directory)
                    }
                }, onProgress: { _, path in
                    guard !cancelled() else { return }
                    latestPath = path; onProgress(indexedCount, path)
                }, onIOIntent: { path in
                    guard !cancelled() else { return }; onIOIntent?(path)
                }, childStarted: options.childStarted)
            guard !cancelled() else { return report(false) }
            if let failure = result.failure {
                switch failure {
                case .cancelled: return report(false)
                case .timeout(let pending):
                    issue(pending, "目录读取超过时限，已终止本次读取并保留旧索引；下次扫描会重新尝试。")
                    guard attempt < retries, pending != root,
                          !exclusions.contains(pending) else { return report(false) }
                    exclusions.append(pending)
                    continue
                case .invalid(let reason):
                    issue(root, "扫描进程未能完整结束，保留旧索引：" + reason)
                    return report(false)
                }
            }
            guard let childReport = result.report else {
                issue(root, "扫描进程未返回完整报告，保留旧索引。")
                return report(false)
            }
            totalIssues += max(childReport.totalIssueCount, childReport.issues.count)
            issues += childReport.issues.prefix(max(0, 1000 - issues.count)).map { ScanIssue(path: $0.path, message: $0.message) }
            if !cancelled() { onProgress(indexedCount, latestPath) }
            return report(childReport.completed)
        }
        return report(false)
    }

    /// AppMain must call this before any NSApplication/UI initialization. CLI
    /// test runners use the same entry point so they exercise actual isolation.
    static func runIfRequested(arguments: [String]) -> Int32? {
        guard let position = arguments.firstIndex(of: "--scan-worker") else { return nil }
        guard arguments.count > position + 1, arguments[position + 1].utf8.count <= 180_000,
              let data = Data(base64Encoded: arguments[position + 1]), data.count <= 131_072,
              let request = try? JSONDecoder().decode(Request.self, from: data),
              validPath(request.path), request.excludedPrefixes.count <= 4096,
              request.excludedPrefixes.allSatisfy(validPath) else { return 64 }
        let writer = Writer()
        if let fault = request.wireFault {
            var header = Data([1]); append32(fault == "oversized" ? UInt32(maximumFrame + 1) : 10, to: &header)
            header.withUnsafeBytes { _ = Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if fault == "truncated" { _ = Darwin.write(STDOUT_FILENO, "abc", 3) }
            return 70
        }
        var lastIntent: String?
        var lastIntentSent = -Double.infinity
        let result = FileScanner.walk(path: request.path, excludedPrefixes: request.excludedPrefixes,
            cancelled: { writer.failed }, onEntry: { writer.entry($0, $1) },
            onProgress: { writer.progress($0, $1) }, onIOIntent: { path in
                let current = now()
                // Readdir repeats an intent for the same parent. Preserve its
                // identity while limiting heartbeat IPC to five times a second.
                if path != lastIntent || current - lastIntentSent >= 0.2 {
                    writer.flush(); writer.frame(2, Data(path.utf8))
                    lastIntent = path; lastIntentSent = current
                }
                if request.stallAtPath == path {
                    // A child-only, explicit test seam parks at an owned fixture
                    // intent. No files are opened or modified to simulate it.
                    while true { pause() }
                }
            })
        writer.flush()
        if request.exitBeforeReport { return 70 }
        var wire = WireReport(count: result.count,
            issues: result.issues.map { WireReport.Issue(path: $0.path, message: $0.message) },
            completed: result.completed, totalIssueCount: result.totalIssueCount)
        var encoded = (try? JSONEncoder().encode(wire)) ?? Data()
        while encoded.count > maximumFrame, !wire.issues.isEmpty {
            wire.issues.removeLast(); encoded = (try? JSONEncoder().encode(wire)) ?? Data()
        }
        writer.frame(4, encoded)
        return writer.failed ? 74 : 0
    }

    private final class Writer {
        var failed = false
        var batch = Data()
        var entries: UInt32 = 0
        func entry(_ path: String, _ directory: Bool) {
            guard !failed else { return }
            let bytes = Data(path.utf8)
            if bytes.count > 65_536 { failed = true; return }
            append32(UInt32(bytes.count), to: &batch); batch.append(directory ? 1 : 0); batch.append(bytes)
            entries += 1
            if entries >= 256 || batch.count >= 128 * 1024 { flush() }
        }
        func flush() {
            guard entries > 0 else { return }
            var payload = Data(); append32(entries, to: &payload); payload.append(batch)
            frame(1, payload); entries = 0; batch.removeAll(keepingCapacity: true)
        }
        func progress(_ count: Int, _ path: String) {
            flush(); var payload = Data()
            var value = Int64(count).littleEndian
            withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) }
            payload.append(contentsOf: path.utf8); frame(3, payload)
        }
        func frame(_ kind: UInt8, _ payload: Data) {
            guard !failed, payload.count <= maximumFrame else { failed = true; return }
            var header = Data([kind]); append32(UInt32(payload.count), to: &header)
            for data in [header, payload] {
                var offset = 0
                data.withUnsafeBytes { buffer in
                    while offset < buffer.count {
                        let written = Darwin.write(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                        if written > 0 { offset += written }
                        else if written < 0 && errno == EINTR { continue }
                        else { failed = true; break }
                    }
                }
                if failed { return }
            }
        }
    }
    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func append32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 65_536
    }
    private static func inside(_ path: String, root: String) -> Bool {
        validPath(path) && (path == root || path.hasPrefix(root == "/" ? "/" : root + "/"))
    }

    private static func run(_ request: Request, timeout: TimeInterval, cancelled: () -> Bool,
                            onEntry: (String, Bool) -> Void, onProgress: (Int, String) -> Void,
                            onIOIntent: (String) -> Void, childStarted: ((pid_t) -> Void)?) -> Attempt {
        guard let encoded = try? JSONEncoder().encode(request), encoded.count <= 131_072 else {
            return Attempt(failure: .invalid("扫描请求超过长度限制"))
        }
        let executable = Bundle.main.executableURL?.path ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardized.path
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return Attempt(failure: .invalid("无法创建扫描管线")) }
        let readFD = descriptors[0], writeFD = descriptors[1]
        defer { close(readFD) }
        guard fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK) == 0 else {
            close(writeFD); return Attempt(failure: .invalid("无法设置扫描管线"))
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        if writeFD != STDOUT_FILENO { posix_spawn_file_actions_addclose(&actions, writeFD) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var empty = sigset_t(), defaults = sigset_t(); sigemptyset(&empty); sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigmask(&attributes, &empty); posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        let arguments = [executable, "--scan-worker", encoded.base64EncodedString()]
        var argv = arguments.map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + environment { if let pointer { free(pointer) } } }
        childLock.lock()
        for pid in Array(quarantined) {
            var status: Int32 = 0
            let code = waitpid(pid, &status, WNOHANG)
            if code == pid || (code < 0 && errno == ECHILD) { children.remove(pid); quarantined.remove(pid) }
        }
        guard children.count < 2 else {
            childLock.unlock(); close(writeFD)
            return Attempt(failure: .invalid("之前的扫描进程尚未退出；停止创建额外进程，旧索引仍可搜索"))
        }
        var pid: pid_t = 0
        let spawnCode = argv.withUnsafeMutableBufferPointer { args in environment.withUnsafeMutableBufferPointer { env in
            posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
        } }
        if spawnCode == 0 { children.insert(pid) }
        childLock.unlock(); close(writeFD)
        guard spawnCode == 0 else { return Attempt(failure: .invalid("无法启动扫描进程（\(spawnCode)）")) }
        childStarted?(pid)
        var reaped = false
        defer { if !reaped { terminate(pid) } }
        var input = Data(), lastActivity = now(), pending = request.path
        var wire: WireReport?, eof = false, exitStatus: Int32?
        var completedAt: TimeInterval?
        var buffer = [UInt8](repeating: 0, count: 65_536)
        func invalid(_ message: String) -> Attempt { Attempt(failure: .invalid(message)) }
        while true {
            if cancelled() { return Attempt(failure: .cancelled) }
            if now() - lastActivity > timeout { return Attempt(failure: .timeout(pending)) }
            if let completedAt, now() - completedAt > 1 { return invalid("报告返回后进程未及时退出") }
            var pollFD = pollfd(fd: readFD, events: Int16(POLLIN | POLLHUP), revents: 0)
            let pollCode = poll(&pollFD, 1, 50)
            if pollCode < 0 && errno != EINTR { return invalid("扫描管线读取失败") }
            while true {
                if cancelled() { return Attempt(failure: .cancelled) }
                let length = Darwin.read(readFD, &buffer, buffer.count)
                if length == 0 { eof = true; break }
                if length < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { break }
                    return invalid("扫描管线意外关闭")
                }
                lastActivity = now(); input.append(contentsOf: buffer.prefix(length))
                var consumed = 0
                while input.count - consumed >= 5 {
                    let kind = input[consumed], size = Int(uint32(input, consumed + 1))
                    if size > maximumFrame { return invalid("扫描数据帧超过长度限制") }
                    if input.count - consumed < size + 5 { break }
                    if cancelled() { return Attempt(failure: .cancelled) }
                    let payload = input.subdata(in: consumed + 5..<consumed + 5 + size)
                    consumed += size + 5
                    if wire != nil { return invalid("完整报告之后仍收到扫描数据") }
                    switch kind {
                    case 1:
                        guard payload.count >= 4 else { return invalid("条目帧不完整") }
                        let count = Int(uint32(payload, 0)); var offset = 4
                        guard count <= 256 else { return invalid("条目帧超过批次限制") }
                        for _ in 0..<count {
                            if cancelled() { return Attempt(failure: .cancelled) }
                            guard payload.count - offset >= 5 else { return invalid("条目长度无效") }
                            let length = Int(uint32(payload, offset)); let directory = payload[offset + 4]; offset += 5
                            guard length <= 65_536, directory <= 1, payload.count - offset >= length,
                                  let path = String(data: payload.subdata(in: offset..<offset + length), encoding: .utf8),
                                  inside(path, root: request.path) else { return invalid("扫描条目不在请求范围内") }
                            offset += length; onEntry(path, directory == 1)
                        }
                        guard offset == payload.count else { return invalid("条目帧有多余数据") }
                    case 2:
                        guard let path = String(data: payload, encoding: .utf8), inside(path, root: request.path) else { return invalid("目录读取位置无效") }
                        pending = path; onIOIntent(path)
                    case 3:
                        guard payload.count >= 8, let path = String(data: payload.dropFirst(8), encoding: .utf8), inside(path, root: request.path) else { return invalid("进度帧无效") }
                        onProgress(0, path)
                    case 4:
                        guard let report = try? JSONDecoder().decode(WireReport.self, from: payload), report.count >= 0,
                              report.totalIssueCount >= report.issues.count, report.issues.count <= 1000,
                              report.issues.allSatisfy({ inside($0.path, root: request.path) }) else { return invalid("最终扫描报告无效") }
                        wire = report; completedAt = now()
                    default: return invalid("未知扫描数据帧")
                    }
                }
                if consumed > 0 { input.removeSubrange(0..<consumed) }
                if input.count > maximumFrame + 5 { return invalid("扫描帧缓存超过限制") }
            }
            if !reaped {
                var status: Int32 = 0
                let code = waitpid(pid, &status, WNOHANG)
                if code == pid {
                    reaped = true; exitStatus = status
                    childLock.lock(); children.remove(pid); quarantined.remove(pid); childLock.unlock()
                } else if code < 0 && errno != EINTR { return invalid("无法确认扫描进程退出状态") }
            }
            if eof {
                guard input.isEmpty else { return invalid("扫描数据帧被截断") }
                if reaped {
                    guard exitStatus == 0, let wire else { return invalid("扫描进程异常退出或缺少完整报告") }
                    return Attempt(report: wire)
                }
            }
        }
    }

    private static func terminate(_ pid: pid_t) {
        kill(pid, SIGTERM)
        let deadline = now() + 0.15
        var status: Int32 = 0
        while now() < deadline {
            let code = waitpid(pid, &status, WNOHANG)
            if code == pid || (code < 0 && errno == ECHILD) {
                childLock.lock(); children.remove(pid); quarantined.remove(pid); childLock.unlock(); return
            }
            usleep(10_000)
        }
        kill(pid, SIGKILL)
        let finalDeadline = now() + 0.35
        while now() < finalDeadline {
            let code = waitpid(pid, &status, WNOHANG)
            if code == pid || (code < 0 && errno == ECHILD) {
                childLock.lock(); children.remove(pid); quarantined.remove(pid); childLock.unlock(); return
            }
            usleep(10_000)
        }
        childLock.lock(); quarantined.insert(pid); childLock.unlock()
    }
}

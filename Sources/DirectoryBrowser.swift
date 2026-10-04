import Foundation
import Darwin

struct DirectoryEntry {
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let isSymbolicLink: Bool
    var name: String { (path as NSString).lastPathComponent }
}

struct DirectoryBrowserTestHooks {
    var beforeEnumeration: ((String) -> Void)?
    var beforeEntryRead: ((String) -> Void)?
}

private enum DirectoryReadCancellation: Error { case cancelled }

private final class DirectoryReadToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func check() throws { if isCancelled { throw DirectoryReadCancellation.cancelled } }
}

/// Directory browsing is separate from the filename index. Only the current
/// directory is inspected, and symbolic links are never traversed while listing.
final class DirectoryBrowser {
    private struct Request {
        var path: String
        var showHidden: Bool
        var completion: (Result<[DirectoryEntry], Error>) -> Void
        let token = DirectoryReadToken()
    }

    /// The mailbox retains one active read and one latest request, never a
    /// separate directory array for every rapid tab/path change.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "cn.local.quickfind.directory-browser", qos: .userInitiated)
        private let hooks: DirectoryBrowserTestHooks?
        private var pending: Request?
        private var current: Request?
        private var running = false
        init(hooks: DirectoryBrowserTestHooks?) { self.hooks = hooks }

        func submit(_ request: Request) {
            lock.lock()
            current?.token.cancel(); pending?.token.cancel()
            pending = request
            let shouldStart = !running
            if shouldStart { running = true }
            lock.unlock()
            if shouldStart { startNext() }
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            current?.token.cancel(); pending?.token.cancel(); pending = nil
        }

        private func startNext() {
            queue.async {
                self.lock.lock()
                let request = self.pending; self.pending = nil; self.current = request
                if request == nil { self.running = false }
                self.lock.unlock()
                guard let request else { return }
                let result = Result { try DirectoryBrowser.read(request, hooks: self.hooks) }
                // Main-thread acknowledgement provides backpressure: only one
                // directory result can wait for the UI, including cancelled ones.
                DispatchQueue.main.async {
                    if !request.token.isCancelled { request.completion(result) }
                    self.lock.lock()
                    self.current = nil
                    let hasNext = self.pending != nil
                    if !hasNext { self.running = false }
                    self.lock.unlock()
                    if hasNext { self.startNext() }
                }
            }
        }
    }

    private let state: State
    init(testHooks: DirectoryBrowserTestHooks? = nil) { state = State(hooks: testHooks) }
    deinit { state.cancel() }

    func load(path: String, showHidden: Bool = false,
              completion: @escaping (Result<[DirectoryEntry], Error>) -> Void) {
        state.submit(Request(path: path, showHidden: showHidden, completion: completion))
    }

    func cancel() { state.cancel() }

    private static func read(_ request: Request, hooks: DirectoryBrowserTestHooks?) throws -> [DirectoryEntry] {
        try request.token.check()
        let path = request.path
        guard path.hasPrefix("/") else {
            throw NSError(domain: "QuickFind.DirectoryBrowser", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "目录必须使用完整路径。"])
        }
        hooks?.beforeEnumeration?(path)
        try request.token.check()
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardized
        let options: FileManager.DirectoryEnumerationOptions = request.showHidden ? [] : [.skipsHiddenFiles]
        let children = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isHiddenKey], options: options)
        try request.token.check()
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(children.count)
        for child in children {
            try request.token.check()
            // Foundation may return /private/var children for a /var directory.
            // Keep the pane's actual lexical path stable.
            let childPath = (directory.path == "/" ? "" : directory.path) + "/" + child.lastPathComponent
            hooks?.beforeEntryRead?(childPath)
            try request.token.check()
            var info = stat()
            let status = childPath.withCString { lstat($0, &info) }
            if status != 0 && errno == ENOENT { continue }
            if !request.showHidden && (child.lastPathComponent.hasPrefix(".") ||
                (try? child.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true) { continue }
            let kind = info.st_mode & mode_t(S_IFMT)
            let link = status == 0 && kind == mode_t(S_IFLNK)
            entries.append(DirectoryEntry(path: childPath,
                isDirectory: status == 0 && kind == mode_t(S_IFDIR),
                size: status == 0 && kind == mode_t(S_IFREG) ? Int64(info.st_size) : nil,
                modified: status == 0 ? Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) +
                    Double(info.st_mtimespec.tv_nsec) / 1_000_000_000) : nil,
                isSymbolicLink: link))
        }
        try request.token.check()
        var comparisons = 0
        let sorted = try entries.sorted {
            comparisons += 1
            if comparisons % 128 == 0 { try request.token.check() }
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        try request.token.check()
        return sorted
    }
}

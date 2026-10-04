// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct ResultMetadata {
    var size: Int64?
    var modified: Date?
}

struct ResultMetadataReadTestHooks {
    var beforeRead: ((String) -> Void)?
}

/// Read by the worker, cancelled by the main actor. No actor-isolated state is
/// touched while a filesystem read is in progress.
private final class ResultMetadataReadToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
}

/// Mutated by the owning main-actor cache, or during its exclusive teardown.
private final class ResultMetadataCacheEntry {
    let path: String
    var metadata: ResultMetadata
    var updated: Date
    weak var previous: ResultMetadataCacheEntry?
    var next: ResultMetadataCacheEntry?
    init(path: String, metadata: ResultMetadata, updated: Date) {
        self.path = path; self.metadata = metadata; self.updated = updated
    }
}

/// Only the visible result rows (or the loaded rows explicitly being sorted)
/// request attributes. The filename index never waits for these reads.
@MainActor
final class ResultMetadataCache {
    var onChange: (() -> Void)?
    static let dateFormatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "zh_CN")
        value.dateFormat = "yyyy-MM-dd HH:mm"
        return value
    }()
    static let defaultCapacity = 4_096
    static let maximumCapacity = 50_000
    private let queue = DispatchQueue(label: "cn.local.quickfind.result-attributes", qos: .utility)
    private let testHooks: ResultMetadataReadTestHooks?
    private var values: [String: ResultMetadataCacheEntry] = [:]
    private var oldest: ResultMetadataCacheEntry?
    private var newest: ResultMetadataCacheEntry?
    private var pending = Set<String>()
    private var waiting: [String?] = []
    private var waitingHead = 0
    private var readToken = ResultMetadataReadToken()
    private var isReading = false
    private(set) var cacheCapacity = defaultCapacity
    var cachedEntryCount: Int { values.count }
    var pendingEntryCount: Int { pending.count }

    init(testHooks: ResultMetadataReadTestHooks? = nil) { self.testHooks = testHooks }

    deinit {
        readToken.cancel()
        var entry = oldest
        while let current = entry {
            entry = current.next; current.next = nil; current.previous = nil
        }
    }

    func value(path: String) -> ResultMetadata? {
        guard let cached = values[path], Date().timeIntervalSince(cached.updated) < 10 else { return nil }
        touch(cached)
        return cached.metadata
    }
    func invalidate() {
        readToken.cancel(); readToken = ResultMetadataReadToken()
        // Unlink first, avoiding a long recursive ARC chain on a large sort.
        var entry = oldest
        while let current = entry {
            entry = current.next; current.next = nil; current.previous = nil
        }
        oldest = nil; newest = nil; values.removeAll()
        pending.removeAll(); waiting.removeAll(); waitingHead = 0
        cacheCapacity = Self.defaultCapacity
    }
    func load(paths: [String]) {
        // A normal visible-row request stays small. Explicit sorting of loaded
        // rows can retain their properties, up to the previous 50,000 limit.
        cacheCapacity = max(cacheCapacity, min(Self.maximumCapacity, paths.count))
        for path in paths {
            guard pending.count < Self.maximumCapacity else { break }
            if value(path: path) == nil && pending.insert(path).inserted { waiting.append(path) }
        }
        readNextBatch()
    }

    private func readNextBatch() {
        guard !isReading, waitingHead < waiting.count else { return }
        var targets: [String] = []
        targets.reserveCapacity(100)
        while targets.count < 100 && waitingHead < waiting.count {
            if let path = waiting[waitingHead] { targets.append(path) }
            waiting[waitingHead] = nil; waitingHead += 1
        }
        if waitingHead == waiting.count { waiting.removeAll(); waitingHead = 0 }
        else if waitingHead >= 1_024 && waitingHead * 2 >= waiting.count {
            waiting = Array(waiting.dropFirst(waitingHead)); waitingHead = 0
        }
        guard !targets.isEmpty else { return }
        isReading = true
        let token = readToken
        let hooks = testHooks
        queue.async { [weak self] in
            var batch: [(String, ResultMetadata)] = []
            batch.reserveCapacity(targets.count)
            for path in targets {
                guard !token.isCancelled else { break }
                hooks?.beforeRead?(path)
                guard !token.isCancelled else { break }
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                guard !token.isCancelled else { break }
                batch.append((path, ResultMetadata(size: (attributes?[.size] as? NSNumber)?.int64Value,
                                                   modified: attributes?[.modificationDate] as? Date)))
            }
            let snapshot = batch
            // Schedule the next read only after this batch is accepted on the
            // main actor: at most one result batch can wait for the UI.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isReading = false
                if self.readToken === token && !token.isCancelled {
                    let now = Date()
                    for (path, metadata) in snapshot {
                        if let entry = self.values[path] {
                            entry.metadata = metadata; entry.updated = now; self.touch(entry)
                        } else {
                            let entry = ResultMetadataCacheEntry(path: path, metadata: metadata, updated: now)
                            self.values[path] = entry; self.append(entry)
                        }
                        self.pending.remove(path)
                    }
                    self.trimCache()
                    if !snapshot.isEmpty { self.onChange?() }
                }
                self.readNextBatch()
            }
        }
    }

    private func trimCache() {
        while values.count > cacheCapacity, let entry = oldest {
            oldest = entry.next; oldest?.previous = nil
            entry.next = nil; values.removeValue(forKey: entry.path)
            if oldest == nil { newest = nil }
        }
    }

    private func touch(_ entry: ResultMetadataCacheEntry) {
        guard newest !== entry else { return }
        if let previous = entry.previous { previous.next = entry.next }
        else { oldest = entry.next }
        entry.next?.previous = entry.previous
        entry.previous = nil; entry.next = nil; append(entry)
    }

    private func append(_ entry: ResultMetadataCacheEntry) {
        entry.previous = newest; newest?.next = entry; newest = entry
        if oldest == nil { oldest = entry }
    }
}

struct SavedSearch: Codable, Equatable {
    var id: UUID
    var query: String
    var kind: String
    var extensionFilter: String
    var matchPath: Bool
    var rootID: String?
    var sizeFilter: String
    var modifiedFilter: String
    var filters: SearchFilters
    var name: String
    var isPinned: Bool

    init(query: String, kind: String, extensionFilter: String, matchPath: Bool,
         rootID: String?, sizeFilter: String, modifiedFilter: String,
         filters: SearchFilters = SearchFilters(), name: String = "", isPinned: Bool = false, id: UUID = UUID()) {
        self.id = id; self.query = query; self.kind = kind; self.extensionFilter = extensionFilter
        self.matchPath = matchPath; self.rootID = rootID; self.sizeFilter = sizeFilter
        self.modifiedFilter = modifiedFilter; self.filters = filters; self.name = name; self.isPinned = isPinned
    }
    private enum CodingKeys: String, CodingKey {
        case id, query, kind, extensionFilter, matchPath, rootID, sizeFilter, modifiedFilter, filters, name, isPinned
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        query = try values.decode(String.self, forKey: .query)
        kind = try values.decode(String.self, forKey: .kind)
        extensionFilter = try values.decode(String.self, forKey: .extensionFilter)
        matchPath = try values.decode(Bool.self, forKey: .matchPath)
        rootID = try values.decodeIfPresent(String.self, forKey: .rootID)
        sizeFilter = try values.decode(String.self, forKey: .sizeFilter)
        modifiedFilter = try values.decode(String.self, forKey: .modifiedFilter)
        filters = try values.decodeIfPresent(SearchFilters.self, forKey: .filters) ?? SearchFilters()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
    func sameConditions(as other: SavedSearch) -> Bool {
        query == other.query && kind == other.kind && extensionFilter == other.extensionFilter
            && matchPath == other.matchPath && rootID == other.rootID && sizeFilter == other.sizeFilter
            && modifiedFilter == other.modifiedFilter && filters.signature == other.filters.signature
    }
    var title: String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        func dateTitle(_ value: String) -> String {
            ["today": "今天", "yesterday": "昨天", "7days": "近7天", "30days": "近30天"][value.lowercased()] ?? value
        }
        var parts = [query.isEmpty ? "全部名称" : query]
        if !extensionFilter.isEmpty { parts.append("扩展名:" + extensionFilter) }
        if !sizeFilter.isEmpty { parts.append("大小:" + sizeFilter) }
        if !modifiedFilter.isEmpty { parts.append("日期:" + dateTitle(modifiedFilter)) }
        if kind != "全部" { parts.append(kind) }
        if filters.category != .all { parts.append(filters.category.rawValue) }
        if !filters.nameValue.isEmpty { parts.append(filters.nameMode.rawValue + ":" + filters.nameValue) }
        if !filters.includedPaths.isEmpty { parts.append("范围:\(filters.includedPaths.count) 个目录") }
        if !filters.excludedPaths.isEmpty { parts.append("排除:\(filters.excludedPaths.count) 个目录") }
        if !filters.createdFilter.isEmpty { parts.append("创建:" + dateTitle(filters.createdFilter)) }
        if !filters.conditionGroup.rules.isEmpty || !filters.conditionGroup.groups.isEmpty { parts.append("组合条件") }
        if filters.hidden != .all { parts.append(filters.hidden.rawValue) }
        if filters.connection != .all { parts.append(filters.connection.rawValue) }
        return parts.joined(separator: " · ")
    }
}

final class SearchWorkspacePreferences {
    private struct State: Codable {
        var history: [SavedSearch] = []
        var saved: [SavedSearch] = []
        var previewVisible = false
    }
    private let file: URL
    private var state: State
    var history: [SavedSearch] { state.history }
    var saved: [SavedSearch] {
        get { state.saved }
        set { state.saved = newValue }
    }
    var previewVisible: Bool {
        get { state.previewVisible }
        set { state.previewVisible = newValue }
    }
    init(directory: URL? = nil) {
        let base = directory ?? RuntimePaths.dataDirectory
        file = base.appendingPathComponent("search-workspace-v2.json")
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: file))) ?? State()
    }
    func remember(_ item: SavedSearch) {
        state.history.removeAll { $0.sameConditions(as: item) }
        state.history.insert(item, at: 0)
        state.history = Array(state.history.prefix(30))
        save()
    }
    func bookmark(_ item: SavedSearch) {
        if let index = state.saved.firstIndex(where: { $0.sameConditions(as: item) }) {
            // Adding the same conditions preserves the user's existing name and
            // pin unless this save explicitly supplies replacement metadata.
            if !item.name.isEmpty {
                state.saved[index].name = item.name
                state.saved[index].isPinned = item.isPinned || state.saved[index].isPinned
            }
        } else { state.saved.append(item) }
        save()
    }
    @discardableResult func updateSaved(id: UUID, with item: SavedSearch) -> Bool {
        guard let index = state.saved.firstIndex(where: { $0.id == id }) else { return false }
        var updated = item; updated.id = id
        updated.name = state.saved[index].name; updated.isPinned = state.saved[index].isPinned
        state.saved[index] = updated; save(); return true
    }
    @discardableResult func renameSaved(id: UUID, name: String) -> Bool {
        guard let index = state.saved.firstIndex(where: { $0.id == id }) else { return false }
        state.saved[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines); save(); return true
    }
    @discardableResult func togglePinned(id: UUID) -> Bool {
        guard let index = state.saved.firstIndex(where: { $0.id == id }) else { return false }
        state.saved[index].isPinned.toggle(); save(); return true
    }
    @discardableResult func removeSaved(id: UUID) -> Bool {
        guard let index = state.saved.firstIndex(where: { $0.id == id }) else { return false }
        state.saved.remove(at: index); save(); return true
    }
    func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
        } catch {
            fputs("保存搜索工作区失败：\(error.localizedDescription)\n", stderr)
        }
    }
}

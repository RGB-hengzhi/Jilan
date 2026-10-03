import AppKit

@MainActor
final class AppModel: NSObject {
    var onChange: (() -> Void)?
    var query = ""
    var kind: SearchKind = .all
    var extensionFilter = ""
    var sizeFilter = ""
    var modifiedFilter = ""
    var filters = SearchFilters()
    var matchPath = false
    var scopeID: String? = nil
    private(set) var results: [FileHit] = []
    private(set) var totalMatches = 0
    private(set) var queryMilliseconds = 0.0
    private(set) var isSearchPending = false
    private(set) var searchStatusDetail = ""
    private(set) var isInspectingMetadata = false
    private(set) var hasMetadataConditions = false
    var hasMetadataFilter: Bool { hasMetadataConditions }
    private var metadataHasMore = false
    private var inspectAllMetadata = false
    var canLoadMoreResults: Bool { resultsAreCurrent && !isInspectingMetadata && (results.count < totalMatches || metadataHasMore) }
    var canInspectAllMetadataCandidates: Bool { hasMetadataConditions && metadataHasMore && !isInspectingMetadata }
    var resultsAreCurrent: Bool { !isSearchPending && completedQueryKey == searchSignature }
    var searchSignature: String {
        [query, kind.rawValue, extensionFilter, sizeFilter, modifiedFilter, String(matchPath), scopeID ?? "", filters.signature].joined(separator: "\u{0000}")
    }
    private(set) var roots: [RootStatus] = []
    private(set) var isScanning = false
    private(set) var scannedCount = 0
    private(set) var issues: [ScanIssue] = []
    private(set) var message = "正在准备索引…"
    let store: IndexStore
    // A cancelled filesystem property read can briefly wait on a slow disk.
    // Concurrent scheduling allows a newer name-only query to run immediately.
    private let searchQueue = DispatchQueue(label: "cn.local.quickfind.search", qos: .userInitiated, attributes: .concurrent)
    private let metadataQuery = MetadataQuery()
    private var metadataIndexVersion = ""
    private(set) var searchGeneration = 0
    private var searchWork: DispatchWorkItem?
    private var searchCancellation = CancellationFlag()
    private var pendingQueryKey: String?
    private var pendingLimit: Int?
    private var completedQueryKey: String?
    private var refreshAfterPending = false
    private var stopped = false
    private var lastSearchScheduled = Date.distantPast
    private(set) var latestSearchRevision: UInt64 = 0
    private var searchedRevision: UInt64?
    private var resultLimit = 2000
    private var previousQueryKey = ""

    init(store: IndexStore = IndexStore()) {
        self.store = store
        super.init()
    }

    var isBrowsingAllIndexedItems: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && kind == .all
            && extensionFilter.isEmpty && sizeFilter.isEmpty && modifiedFilter.isEmpty && filters.isEmpty
    }

    func start() {
        store.onUpdate = { [weak self] state in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                let metadataVersion = String(state.searchRevision)
                if metadataVersion != self.metadataIndexVersion {
                    self.metadataIndexVersion = metadataVersion
                    self.metadataQuery.invalidate()
                }
                self.roots = state.roots
                self.isScanning = state.isScanning
                self.scannedCount = state.scannedCount
                self.issues = state.issues
                self.message = state.message
                self.latestSearchRevision = state.searchRevision
                self.onChange?()
                if self.searchedRevision != state.searchRevision,
                   !state.isScanning || Date().timeIntervalSince(self.lastSearchScheduled) > 1.5 {
                    self.searchForIndexUpdate()
                }
            }
        }
        store.start()
    }

    private func searchForIndexUpdate() {
        // Keep an in-flight user search alive. A final index update still needs
        // one fresh query after that search completes, even without more events.
        guard searchedRevision != latestSearchRevision else { return }
        if pendingQueryKey == searchSignature {
            refreshAfterPending = true
            return
        }
        search(background: true)
    }

    func search(immediate: Bool = false, background: Bool = false) {
        guard !stopped else { return }
        let key = searchSignature
        let conditionsChanged = key != previousQueryKey
        if conditionsChanged { resultLimit = 2000; previousQueryKey = key; inspectAllMetadata = false }
        // The action and editing delegate can both report the same keystroke.
        // Coalesce them instead of repeatedly cancelling the same request.
        if pendingQueryKey == key && pendingLimit == resultLimit { return }
        let backgroundRefresh = background && completedQueryKey == key
        searchGeneration += 1
        let generation = searchGeneration
        lastSearchScheduled = Date()
        searchedRevision = latestSearchRevision
        searchWork?.cancel()
        searchCancellation.cancel()
        let cancellation = CancellationFlag()
        searchCancellation = cancellation
        pendingQueryKey = key
        pendingLimit = resultLimit
        refreshAfterPending = false
        // A fresh user query invalidates old results. An index refresh keeps
        // the current query usable and does not flash its selection/preview.
        isSearchPending = !backgroundRefresh
        if conditionsChanged {
            results = []
            totalMatches = 0
            queryMilliseconds = 0
            completedQueryKey = nil
            metadataHasMore = false
        }
        var request = SearchRequest(query: query, kind: kind, extensionFilter: extensionFilter,
            matchPath: matchPath, rootID: scopeID, sizeFilter: sizeFilter, modifiedFilter: modifiedFilter,
            filters: filters, cancellation: cancellation)
        let plan = AdvancedSearchPlan.parse(request)
        request.parsedPlan = plan
        hasMetadataConditions = plan.usesMetadata
        isInspectingMetadata = plan.usesMetadata && plan.error == nil
        searchStatusDetail = plan.usesMetadata ? "正在检查候选文件属性…" : ""
        if let error = plan.error {
            results = []; totalMatches = 0; queryMilliseconds = 0
            searchStatusDetail = error; isSearchPending = false; isInspectingMetadata = false
            pendingQueryKey = nil; pendingLimit = nil; completedQueryKey = key; metadataHasMore = false
            onChange?(); return
        }
        if !backgroundRefresh || plan.usesMetadata { onChange?() }
        let store = self.store
        let limit = resultLimit
        let metadata = metadataQuery
        let inspectAll = inspectAllMetadata
        let candidateLimit = inspectAll ? Int.max : max(20_000, limit * 10)
        let work = DispatchWorkItem { [weak self] in
            guard !cancellation.isCancelled else { return }
            let start = Date()
            var result = store.search(request, limit: plan.usesMetadata ? candidateLimit : limit)
            guard !cancellation.isCancelled else { return }
            var propertyProgress: MetadataQuery.Progress?
            if plan.usesMetadata {
                propertyProgress = metadata.filter(result.hits, totalCandidates: result.totalMatches, plan: plan,
                    matchPath: request.matchPath, limit: limit, cancellation: cancellation, onProgress: { progress in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.searchGeneration == generation, !self.stopped,
                                  !cancellation.isCancelled, self.searchSignature == key else { return }
                            self.results = progress.hits
                            self.totalMatches = progress.totalMatches
                            if !backgroundRefresh { self.queryMilliseconds = Date().timeIntervalSince(start) * 1000 }
                            self.metadataHasMore = progress.hasMore
                            self.searchStatusDetail = "正在检查 · " + progress.detail
                            self.completedQueryKey = key
                            self.isSearchPending = false
                            self.onChange?()
                        }
                    })
                guard !cancellation.isCancelled, let progress = propertyProgress, !progress.cancelled else { return }
                result = SearchBatch(hits: progress.hits, totalMatches: progress.totalMatches,
                                     elapsedMilliseconds: Date().timeIntervalSince(start) * 1000)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.searchGeneration == generation, !self.stopped,
                    !cancellation.isCancelled, self.searchSignature == key else { return }
                self.results = result.hits
                self.totalMatches = result.totalMatches
                if !backgroundRefresh { self.queryMilliseconds = result.elapsedMilliseconds }
                self.isInspectingMetadata = false
                self.metadataHasMore = propertyProgress?.hasMore ?? false
                self.searchStatusDetail = propertyProgress?.detail ?? ""
                self.completedQueryKey = key
                self.pendingQueryKey = nil
                self.pendingLimit = nil
                self.isSearchPending = false
                let needsRefresh = self.refreshAfterPending
                self.refreshAfterPending = false
                self.onChange?()
                if needsRefresh && self.searchSignature == key && self.searchedRevision != self.latestSearchRevision {
                    self.search(immediate: true, background: true)
                }
            }
        }
        searchWork = work
        if immediate { searchQueue.async(execute: work) }
        else { searchQueue.asyncAfter(deadline: .now() + 0.04, execute: work) }
    }

    func loadMoreResults() {
        guard canLoadMoreResults else { return }
        resultLimit = metadataHasMore ? resultLimit + 5000 : min(totalMatches, resultLimit + 5000)
        search()
    }

    /// Explicit opt-in for a potentially lengthy metadata sweep. Progress rows
    /// remain usable while the background pass runs; typing cancels the pass.
    func inspectAllMetadataCandidates() {
        guard hasMetadataConditions, !stopped else { return }
        inspectAllMetadata = true
        searchCancellation.cancel(); searchWork?.cancel(); pendingQueryKey = nil
        search(immediate: true)
    }

    func cancelMetadataInspection() {
        guard isInspectingMetadata else { return }
        searchCancellation.cancel(); searchWork?.cancel(); searchGeneration += 1
        isInspectingMetadata = false; isSearchPending = false
        pendingQueryKey = nil; pendingLimit = nil; refreshAfterPending = false
        metadataHasMore = true; inspectAllMetadata = false
        searchStatusDetail = "属性检查已取消；当前显示已确认的部分结果。"
        onChange?()
    }

    func invalidateMetadata() { metadataQuery.invalidate() }

    func fileOperationDidChange(paths: [String]) {
        metadataQuery.invalidate()
        store.refreshChangedPaths(paths)
        search(immediate: true)
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "添加索引位置"
        panel.message = "选择文件夹或外置磁盘。仅记录名称与路径，原文件不会被改动。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加并扫描"
        if panel.runModal() == .OK {
            store.addRoots(panel.urls.map { IndexStore.makeRoot(path: $0.path) })
        }
    }

    func addWholeDisks() { store.addRoots(IndexStore.wholeDisks()) }
    func refreshAll() { store.refreshAll() }
    func cancelScan() { store.cancelScan() }
    func removeRoot(id: String) {
        if scopeID == id { scopeID = nil }
        store.removeRoot(id: id)
        search()
    }

    private func isAvailable(_ hit: FileHit) -> Bool {
        guard hit.isOnline else {
            showMessage("磁盘当前离线", text: "这是上次索引中的文件。请连接原磁盘后再打开或定位。")
            return false
        }
        guard FileManager.default.fileExists(atPath: hit.path) else {
            showMessage("文件已移动或无法访问", text: "该结果可能尚未校准，或当前没有访问权限。可以重新扫描索引。\n\n\(hit.path)")
            return false
        }
        return true
    }

    func open(_ hit: FileHit) {
        guard hit.isOnline else {
            showMessage("磁盘当前离线", text: "请连接原磁盘后再打开。")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: hit.path), configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async { [weak self] in
                self?.showMessage("无法打开", text: error.localizedDescription + "\n\n" + hit.path)
            }
        }
    }

    func reveal(_ hit: FileHit) {
        guard isAvailable(hit) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)])
    }

    func copyPath(_ hit: FileHit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.path, forType: .string)
        message = "已复制完整路径：\(hit.path)"
        onChange?()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showMessage(_ title: String, text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text
        alert.addButton(withTitle: "知道了"); alert.runModal()
    }

    func shutdown() {
        stopped = true; searchWork?.cancel(); searchCancellation.cancel()
        store.shutdown()
    }
}

import AppKit
import Quartz
import Darwin

enum PreviewMetadataScope {
    static func shouldRefresh(path: String, physicalPath: String?, changedPaths: [String]?) -> Bool {
        guard let changedPaths else { return true }
        let changed = Set(changedPaths)
        guard !changed.isEmpty else { return false }
        if MetadataPathScope.contains(path, changedPaths: changed) { return true }
        // The initial background read may not have resolved a symlink/alias
        // yet. Conservatively inspect the one selected item in that interval.
        guard let physicalPath else { return true }
        return MetadataPathScope.contains(physicalPath, changedPaths: changed)
    }

    /// Filesystem resolution belongs on the existing preview utility queue.
    static func resolvePhysicalPath(_ path: String) -> String? {
        path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}

/// A native workspace beside the global index. Its directory reads and file jobs
/// never run on the index's query queue.
@MainActor
final class WorkspaceController: NSViewController {
    var onFilesChanged: (([String]) -> Void)?
    var onMessage: ((String) -> Void)?
    var onOperationStateChanged: (() -> Void)?
    var onSearchFocusRequested: (() -> Void)?
    var hasActiveOperations: Bool { runningJob != nil || !jobs.isEmpty }
    var hasSelection: Bool { isViewLoaded && panes.count == 2 && !panes[activePane].selectedPaths.isEmpty }

    private let fileService = FileOperationService()
    private var panes: [WorkspacePaneController] = []
    private var activePane = 0
    private var favorites: [String] = []
    private var showHidden = false
    private var dualPane = true
    private var previewVisible = true
    private let paneSplit = WorkspaceSplitView()
    private let contentSplit = WorkspaceSplitView()
    private var preferredPaneWidth: NSLayoutConstraint?
    private var preferredPreviewWidth: NSLayoutConstraint?
    private let previewContainer = NSView()
    private var quickLook: QLPreviewView?
    private let previewName = NSTextField(labelWithString: "选择文件以预览")
    private let previewInfo = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "双栏整理 · 拖入文件会复制到目标目录")
    private let taskLabel = NSTextField(labelWithString: "没有正在执行的文件任务")
    private let taskProgress = NSProgressIndicator()
    private let cancelTaskButton = NSButton(title: "取消任务", target: nil, action: nil)
    private let recoveryButton = NSButton(title: "查看恢复备份", target: nil, action: nil)
    private var recoveryPaths: [String] = []
    private let dualButton = NSButton(checkboxWithTitle: "双栏", target: nil, action: nil)
    private let previewButton = NSButton(checkboxWithTitle: "预览", target: nil, action: nil)
    private let hiddenButton = NSButton(checkboxWithTitle: "隐藏文件", target: nil, action: nil)
    private var activeToken: FileOperationToken?
    private struct QueuedJob { let request: FileOperationRequest; let title: String }
    private var jobs: [QueuedJob] = []
    private var runningJob: QueuedJob?
    private var cutPasteboardChangeCount: Int?
    private var currentPreviewKey: String?
    private var visibilityKey: String?
    private var currentPreviewPath: String?
    private var currentPreviewPhysicalPath: String?
    private var previewGeneration = 0
    private struct PreviewStamp: Equatable {
        var size: Int64?
        var modified: Date?
        var created: Date?
        var fileID: UInt64?
        var deviceID: UInt64?
        var type: String?
    }
    private var previewStamp: PreviewStamp?

    /// The index keeps ownership of its table, query state and selection. Only
    /// its view is hosted here, so a search never creates a second result model.
    func installSearchView(_ searchView: NSView, selectionProvider: @escaping () -> [FileHit]) {
        loadViewIfNeeded()
        panes[0].installSearchView(searchView, selectionProvider: selectionProvider)
        showSearchResults()
    }

    var isSearchSelectionActive: Bool {
        isViewLoaded && panes.count == 2 && activePane == 0 && panes[0].isSearchTabSelected
    }

    /// Scope shortcuts inspect the retained real directory; the search slot
    /// itself is never converted into a directory or an operation destination.
    var activeDirectoryPath: String {
        loadViewIfNeeded()
        return sourcePane.actualDirectoryPath
    }

    func showSearchResults() {
        loadViewIfNeeded()
        panes[0].showSearchResults()
        dualPane = true; dualButton.state = .on; updateVisibility()
        setActivePane(0)
    }

    func showDirectoryWorkspace() {
        loadViewIfNeeded()
        panes[0].showDirectoryTab()
        setActivePane(0)
    }

    /// Query refreshes pass activate=false. They can clear an outdated preview
    /// without changing a chosen target directory or stealing right-pane focus.
    func searchSelectionDidChange(activate: Bool = true) {
        loadViewIfNeeded()
        if activate { panes[0].showSearchResults(); setActivePane(0) }
        else if isSearchSelectionActive { selectPreview(path: panes[0].selectedPaths.first) }
    }

    func copySelectionToClipboard(cutting: Bool = false) {
        loadViewIfNeeded(); putSelectionOnClipboard(cutting: cutting)
    }

    func pasteClipboardIntoCurrentDirectory() {
        loadViewIfNeeded(); pasteIntoCurrentDirectory()
    }

    func performCurrentAction(_ action: WorkspacePaneAction) {
        loadViewIfNeeded(); performPaneAction(action)
    }

    func browseSearchDirectory(_ path: String, selecting: [String] = []) {
        loadViewIfNeeded()
        panes[0].navigateInDirectoryTab(to: path, selecting: selecting)
        setActivePane(0)
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root
        let saved = WorkspaceSessionStore.load()
        favorites = saved?.favorites ?? WorkspaceSessionStore.defaultFavorites
        showHidden = saved?.showHidden ?? false
        dualPane = saved?.dualPane ?? true
        previewVisible = saved?.previewVisible ?? true
        activePane = min(max(saved?.activePane ?? 0, 0), 1)
        if !dualPane { activePane = 0 }

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 7
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        bar.addArrangedSubview(button("复制到另一栏", #selector(copyToOther(_:))))
        bar.addArrangedSubview(button("移动到另一栏", #selector(moveToOther(_:))))
        bar.addArrangedSubview(button("改名", #selector(renameSelected(_:))))
        bar.addArrangedSubview(button("批量改名", #selector(batchRename(_:))))
        bar.addArrangedSubview(button("新建文件夹", #selector(createFolder(_:))))
        bar.addArrangedSubview(button("废纸篓", #selector(trashSelected(_:))))
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(spacer)
        for control in [dualButton, previewButton, hiddenButton] {
            control.target = self; control.action = #selector(toggleOptions(_:))
            control.setContentHuggingPriority(.required, for: .horizontal)
            bar.addArrangedSubview(control)
        }
        dualButton.state = dualPane ? .on : .off
        previewButton.state = previewVisible ? .on : .off
        hiddenButton.state = showHidden ? .on : .off

        paneSplit.isVertical = true; paneSplit.dividerStyle = .thin
        paneSplit.autosaveName = "QuickFindWorkspacePanes"
        for index in 0..<2 {
            let pane = WorkspacePaneController()
            pane.paneIndex = index
            pane.showHidden = showHidden
            pane.onFocus = { [weak self] in self?.setActivePane(index) }
            pane.onSelection = { [weak self] path in
                guard let self, self.activePane == index else { return }
                self.selectPreview(path: path)
            }
            pane.onMessage = { [weak self] message in self?.message(message) }
            pane.onStateChange = { [weak self] in self?.saveSession() }
            pane.onFavorites = { [weak self, weak pane] sender in
                guard let self, let pane else { return }; self.showFavorites(sender: sender, pane: pane)
            }
            pane.onDrop = { [weak self] paths, destination in
                self?.enqueue(.init(kind: .copy, sources: paths.map { URL(fileURLWithPath: $0) }, destination: URL(fileURLWithPath: destination)), title: "复制拖入的文件")
            }
            pane.onAction = { [weak self] action in self?.performPaneAction(action) }
            pane.onSearchFocusRequested = { [weak self] in self?.onSearchFocusRequested?() }
            pane.view.translatesAutoresizingMaskIntoConstraints = false
            pane.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
            addChild(pane); panes.append(pane); paneSplit.addArrangedSubview(pane.view)
            if let state = saved?.panes[index], !state.paths.isEmpty {
                pane.restore(state)
            } else {
                let start = FileManager.default.homeDirectoryForCurrentUser.path
                pane.restore(.init(paths: [start], selectedTab: 0))
            }
        }
        contentSplit.isVertical = true; contentSplit.dividerStyle = .thin
        contentSplit.autosaveName = "QuickFindWorkspacePreview"
        paneSplit.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        contentSplit.addArrangedSubview(paneSplit)
        makePreview()
        contentSplit.addArrangedSubview(previewContainer)

        let footer = NSStackView()
        footer.orientation = .horizontal; footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 7, right: 10)
        taskProgress.style = .bar; taskProgress.isIndeterminate = false
        taskProgress.minValue = 0; taskProgress.maxValue = 1
        taskProgress.translatesAutoresizingMaskIntoConstraints = false
        taskProgress.widthAnchor.constraint(equalToConstant: 120).isActive = true
        taskLabel.lineBreakMode = .byTruncatingMiddle
        taskLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancelTaskButton.target = self; cancelTaskButton.action = #selector(cancelTask(_:)); cancelTaskButton.isEnabled = false
        recoveryButton.target = self; recoveryButton.action = #selector(showRecovery(_:)); recoveryButton.isHidden = true
        footer.addArrangedSubview(taskLabel); footer.addArrangedSubview(taskProgress); footer.addArrangedSubview(cancelTaskButton); footer.addArrangedSubview(recoveryButton)
        let messages = NSStackView(views: [messageLabel])
        messages.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 5, right: 10)
        messageLabel.font = .systemFont(ofSize: 11); messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingMiddle

        [bar, contentSplit, footer, messages].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor), bar.topAnchor.constraint(equalTo: root.topAnchor),
            contentSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8), contentSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8), contentSplit.topAnchor.constraint(equalTo: bar.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor), footer.topAnchor.constraint(equalTo: contentSplit.bottomAnchor),
            messages.leadingAnchor.constraint(equalTo: root.leadingAnchor), messages.trailingAnchor.constraint(equalTo: root.trailingAnchor), messages.topAnchor.constraint(equalTo: footer.bottomAnchor), messages.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        paneSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        contentSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        contentSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        previewContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        previewContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        let paneWidth = panes[0].view.widthAnchor.constraint(equalTo: paneSplit.widthAnchor, multiplier: 0.55, constant: -0.5)
        paneWidth.priority = NSLayoutConstraint.Priority(900); preferredPaneWidth = paneWidth
        let previewWidth = previewContainer.widthAnchor.constraint(equalToConstant: 260)
        previewWidth.priority = NSLayoutConstraint.Priority(900); preferredPreviewWidth = previewWidth
        // These initial preferences yield to an explicit divider drag. Ordinary
        // refreshes keep the chosen widths rather than resetting the workspace.
        paneSplit.onDividerInteraction = { [weak self] in self?.preferredPaneWidth?.isActive = false }
        contentSplit.onDividerInteraction = { [weak self] in self?.preferredPreviewWidth?.isActive = false }
        updateVisibility(); setActivePane(activePane)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        prepareInitialLayout()
    }

    /// The workspace is embedded in an AppKit window rather than installed as
    /// its contentViewController, so the host calls this after its first layout.
    func prepareInitialLayout() {
        loadViewIfNeeded()
        preferredPreviewWidth?.isActive = previewVisible
        preferredPaneWidth?.isActive = dualPane
        view.layoutSubtreeIfNeeded()
    }

    private var sourcePane: WorkspacePaneController { panes[activePane] }
    private var targetPane: WorkspacePaneController { panes[1 - activePane] }

    func open(paths: [String], inOtherPane: Bool = false) {
        loadViewIfNeeded()
        let unique = Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }
        guard !unique.isEmpty else { return }
        let index = inOtherPane ? 1 - activePane : activePane
        if inOtherPane { dualPane = true; dualButton.state = .on; updateVisibility() }
        setActivePane(index)
        if unique.count > 1 {
            panes[index].openCollection(unique)
            message("已导入 \(unique.count) 个搜索选中项，可多选整理到另一栏。")
        } else {
            let path = unique[0]
            var directory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue {
                panes[index].navigate(to: path)
            } else {
                panes[index].navigate(to: (path as NSString).deletingLastPathComponent, selecting: [path])
            }
        }
    }

    func reveal(path: String, inOtherPane: Bool = true) {
        loadViewIfNeeded()
        let index = inOtherPane ? 1 - activePane : activePane
        if inOtherPane { dualPane = true; dualButton.state = .on; updateVisibility() }
        panes[index].navigate(to: (path as NSString).deletingLastPathComponent, selecting: [path])
        setActivePane(index)
    }

    func preview(path: String) { selectPreview(path: path) }

    func openCurrentSelection() { loadViewIfNeeded(); sourcePane.openCurrentSelection() }
    func revealCurrentSelection() { loadViewIfNeeded(); performPaneAction(.reveal) }
    func copyCurrentPaths() { loadViewIfNeeded(); performPaneAction(.copyPaths) }
    func toggleCurrentPreview() {
        loadViewIfNeeded(); previewVisible.toggle(); previewButton.state = previewVisible ? .on : .off
        updateVisibility(); selectPreview(path: sourcePane.selectedPaths.first); saveSession()
    }
    func newWorkspaceTab() { loadViewIfNeeded(); sourcePane.createNewTab() }
    func closeCurrentTab() { loadViewIfNeeded(); sourcePane.closeCurrentTab() }

    func selectPreview(path: String?) {
        loadViewIfNeeded()
        let key = String(previewVisible) + "\u{0000}" + (path ?? "")
        guard currentPreviewKey != key else { return }
        currentPreviewKey = key
        currentPreviewPath = path; currentPreviewPhysicalPath = nil; previewStamp = nil
        previewGeneration += 1
        guard let path else {
            quickLook?.previewItem = nil; previewName.stringValue = "选择文件以预览"; previewInfo.stringValue = ""; return
        }
        previewName.stringValue = (path as NSString).lastPathComponent
        previewInfo.stringValue = path
        if previewVisible { quickLook?.previewItem = NSURL(fileURLWithPath: path) }
        readPreviewMetadata(path: path, reloadIfChanged: false)
    }

    /// A real index change may refer to this file being edited in another app.
    /// Check its identity/attributes without restarting an unchanged preview.
    func refreshSelectedPreview(changedPaths: [String]? = nil) {
        guard let path = currentPreviewPath else { return }
        guard PreviewMetadataScope.shouldRefresh(path: path, physicalPath: currentPreviewPhysicalPath,
                                                changedPaths: changedPaths) else { return }
        readPreviewMetadata(path: path, reloadIfChanged: true)
    }

    private func readPreviewMetadata(path: String, reloadIfChanged: Bool) {
        let requestedPath = path
        previewGeneration += 1; let generation = previewGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let physicalPath = PreviewMetadataScope.resolvePhysicalPath(requestedPath)
            let attributes = try? FileManager.default.attributesOfItem(atPath: requestedPath)
            let stamp = PreviewStamp(size: (attributes?[.size] as? NSNumber)?.int64Value,
                modified: attributes?[.modificationDate] as? Date, created: attributes?[.creationDate] as? Date,
                fileID: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
                deviceID: (attributes?[.systemNumber] as? NSNumber)?.uint64Value,
                type: (attributes?[.type] as? FileAttributeType)?.rawValue)
            DispatchQueue.main.async {
                guard let self, self.previewGeneration == generation, self.currentPreviewPath == requestedPath else { return }
                self.currentPreviewPhysicalPath = physicalPath
                if reloadIfChanged && self.previewStamp != stamp && self.previewVisible {
                    self.quickLook?.previewItem = nil
                    self.quickLook?.previewItem = NSURL(fileURLWithPath: requestedPath)
                }
                self.previewStamp = stamp
                let size = stamp.type == FileAttributeType.typeDirectory.rawValue ? "文件夹" : stamp.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小未知"
                let date = stamp.modified.map { Self.dateFormatter.string(from: $0) } ?? ""
                self.previewInfo.stringValue = requestedPath + "\n\n" + size + (date.isEmpty ? "" : " · 修改于 " + date)
            }
        }
    }

    func refresh() {
        loadViewIfNeeded(); currentPreviewKey = nil
        panes.forEach { $0.reload() }
    }

    func cancelOperations() {
        jobs.removeAll(); activeToken?.cancel()
        if runningJob == nil { onOperationStateChanged?() }
    }

    func saveSession() {
        guard isViewLoaded, panes.count == 2 else { return }
        let state = WorkspaceSession(panes: panes.map { $0.sessionState }, activePane: activePane, favorites: favorites, showHidden: showHidden, previewVisible: previewVisible, dualPane: dualPane)
        do { try WorkspaceSessionStore.save(state) } catch { onMessage?("无法保存工作区：" + error.localizedDescription) }
    }

    private func makePreview() {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        previewName.font = .boldSystemFont(ofSize: 13); previewName.lineBreakMode = .byTruncatingMiddle
        previewName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewInfo.font = .systemFont(ofSize: 11); previewInfo.textColor = .secondaryLabelColor
        previewInfo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewInfo.preferredMaxLayoutWidth = 296
        previewInfo.maximumNumberOfLines = 8
        quickLook = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 260, height: 300), style: .compact)
        quickLook?.shouldCloseWithWindow = false
        quickLook?.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(previewName)
        if let quickLook { stack.addArrangedSubview(quickLook); quickLook.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true; quickLook.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true }
        stack.addArrangedSubview(previewInfo)
        stack.translatesAutoresizingMaskIntoConstraints = false; previewContainer.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor), stack.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor), stack.topAnchor.constraint(equalTo: previewContainer.topAnchor), stack.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor)])
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; b.controlSize = .small; b.font = .systemFont(ofSize: 11); return b
    }

    private func setActivePane(_ index: Int) {
        activePane = min(max(index, 0), 1)
        for (i, pane) in panes.enumerated() { pane.setActive(i == activePane) }
        if isViewLoaded { updateVisibility(); selectPreview(path: panes[activePane].selectedPaths.first) }
    }

    @objc private func toggleOptions(_ sender: NSButton) {
        let expandingPreview = !previewVisible && previewButton.state == .on
        let expandingPanes = !dualPane && dualButton.state == .on
        dualPane = dualButton.state == .on; previewVisible = previewButton.state == .on; showHidden = hiddenButton.state == .on
        if !dualPane { setActivePane(0) }
        panes.forEach { if $0.showHidden != showHidden { $0.showHidden = showHidden; $0.reload() } }
        updateVisibility(); saveSession()
        if expandingPreview || expandingPanes { prepareInitialLayout() }
        selectPreview(path: sourcePane.selectedPaths.first)
    }

    private func updateVisibility() {
        guard panes.count == 2 else { return }
        if panes[0].isSearchTabSelected {
            if !dualPane { preferredPaneWidth?.isActive = true }
            dualPane = true; dualButton.state = .on
        }
        let key = [String(dualPane), String(previewVisible), String(panes[0].isSearchTabSelected)].joined(separator: "|")
        guard visibilityKey != key else { return }
        visibilityKey = key
        if !dualPane { preferredPaneWidth?.isActive = false }
        if !previewVisible { preferredPreviewWidth?.isActive = false }
        dualButton.isEnabled = !panes[0].isSearchTabSelected
        panes[1].view.isHidden = !dualPane
        previewContainer.isHidden = !previewVisible
        if !previewVisible { quickLook?.previewItem = nil }
        paneSplit.adjustSubviews(); contentSplit.adjustSubviews()
    }

    private func showFavorites(sender: NSButton, pane: WorkspacePaneController) {
        let menu = NSMenu(title: "常用目录")
        let add = NSMenuItem(title: "收藏当前目录", action: #selector(addFavorite(_:)), keyEquivalent: "")
        add.target = self; add.representedObject = pane; add.isEnabled = !pane.isCollection
        menu.addItem(add)
        let remove = NSMenuItem(title: "取消收藏当前目录", action: #selector(removeFavorite(_:)), keyEquivalent: "")
        remove.target = self; remove.representedObject = pane; remove.isEnabled = favorites.contains(pane.currentPath)
        menu.addItem(remove); menu.addItem(.separator())
        for path in favorites {
            let item = NSMenuItem(title: displayPath(path), action: #selector(openFavorite(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = ["path": path, "pane": String(pane.paneIndex)]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 3), in: sender)
    }

    @objc private func addFavorite(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? WorkspacePaneController else { return }
        if !favorites.contains(pane.currentPath) { favorites.append(pane.currentPath); saveSession(); message("已收藏：" + pane.currentPath) }
    }
    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? WorkspacePaneController else { return }
        favorites.removeAll { $0 == pane.currentPath }; saveSession()
    }
    @objc private func openFavorite(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String], let path = info["path"], let index = Int(info["pane"] ?? "0") else { return }
        panes[index].navigate(to: path); setActivePane(index)
    }
    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "个人文件夹" }
        return (path as NSString).lastPathComponent + " — " + (path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path)
    }

    private func performPaneAction(_ action: WorkspacePaneAction) {
        switch action {
        case .copy: copyToOther(nil)
        case .move: moveToOther(nil)
        case .rename: renameSelected(nil)
        case .batchRename: batchRename(nil)
        case .trash: trashSelected(nil)
        case .newFolder: createFolder(nil)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(sourcePane.selectedPaths.map { URL(fileURLWithPath: $0) })
        case .copyPaths: let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(sourcePane.selectedPaths.joined(separator: "\n"), forType: .string)
        case .copyClipboard: putSelectionOnClipboard(cutting: false)
        case .cutClipboard: putSelectionOnClipboard(cutting: true)
        case .pasteClipboard: pasteIntoCurrentDirectory()
        case .preview:
            guard !sourcePane.selectedPaths.isEmpty else { return }
            toggleCurrentPreview()
        }
    }

    private func putSelectionOnClipboard(cutting: Bool) {
        let paths = sourcePane.selectedPaths
        guard !paths.isEmpty else { message("请先选择文件或文件夹。"); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(paths.map { NSURL(fileURLWithPath: $0) })
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        cutPasteboardChangeCount = cutting ? pasteboard.changeCount : nil
        message("已\(cutting ? "剪切" : "复制") \(paths.count) 项，进入目标目录后按 ⌘V 粘贴。")
    }

    private func pasteIntoCurrentDirectory() {
        guard !sourcePane.isCollection else { message("请先打开要粘贴到的目标目录。"); return }
        guard sourcePane.isUsableDirectoryDestination else { message("当前目录尚未读取成功，请等待读取完成或打开其它目标目录。"); return }
        let pasteboard = NSPasteboard.general
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { message("剪贴板没有可粘贴的文件。"); return }
        let moving = cutPasteboardChangeCount == pasteboard.changeCount
        let target = sourcePane.currentPath
        let request = FileOperationRequest(kind: moving ? .move : .copy, sources: urls, destination: URL(fileURLWithPath: target))
        if moving {
            confirm(title: "移动剪切的 \(urls.count) 项？", detail: "目标：" + target + "\n移动完成后，项目会从原位置移走。", button: "移动") { [weak self] accepted in
                if accepted { self?.cutPasteboardChangeCount = nil; self?.enqueue(request, title: "粘贴并移动") }
            }
        } else { enqueue(request, title: "粘贴并复制") }
    }

    @objc private func copyToOther(_ sender: Any?) { transfer(.copy) }
    @objc private func moveToOther(_ sender: Any?) { transfer(.move) }
    private func transfer(_ kind: FileOperationKind) {
        let paths = sourcePane.selectedPaths
        guard !paths.isEmpty else { message("请先选择要整理的文件或文件夹。"); return }
        guard !targetPane.isCollection else { message("另一栏是搜索结果，请先在另一栏打开一个目标文件夹。"); return }
        guard targetPane.isUsableDirectoryDestination else { message("另一栏目录尚未读取成功，请等待读取完成或选择其它目标目录。"); return }
        dualPane = true; dualButton.state = .on; updateVisibility()
        let title = kind == .copy ? "复制" : "移动"
        let request = FileOperationRequest(kind: kind, sources: paths.map { URL(fileURLWithPath: $0) }, destination: URL(fileURLWithPath: targetPane.currentPath))
        if kind == .move {
            confirm(title: "移动 \(paths.count) 项？", detail: "目标：\(targetPane.currentPath)\n移动完成后，项目会从原位置移走。", button: "移动") { [weak self] accepted in if accepted { self?.enqueue(request, title: title) } }
        } else { enqueue(request, title: title) }
    }

    @objc private func renameSelected(_ sender: Any?) {
        let paths = sourcePane.selectedPaths
        guard paths.count == 1 else { message("改名请选择一项；多项请使用「批量改名」。"); return }
        let path = paths[0]
        prompt(title: "重命名", detail: path, value: (path as NSString).lastPathComponent, button: "改名") { [weak self] name in
            guard let self, let name, self.validName(name) else { return }
            self.enqueue(.init(kind: .rename, sources: [URL(fileURLWithPath: path)], names: [path: name]), title: "重命名")
        }
    }

    @objc private func batchRename(_ sender: Any?) {
        let paths = sourcePane.selectedPaths
        let directoryFlags = Dictionary(uniqueKeysWithValues: sourcePane.selectedDirectoryFlags)
        guard !paths.isEmpty else { message("请先选择要批量改名的项目。"); return }
        let alert = NSAlert(); alert.messageText = "批量改名规则"; alert.informativeText = "先预览名称，确认后再执行。替换仅作用于文件名，扩展名会保留。"
        alert.addButton(withTitle: "预览改名"); alert.addButton(withTitle: "取消")
        let prefix = NSTextField(string: ""), suffix = NSTextField(string: ""), find = NSTextField(string: ""), replace = NSTextField(string: "")
        let numbering = NSButton(checkboxWithTitle: "添加序号（001、002…）", target: nil, action: nil)
        let fields = NSStackView(); fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 8
        for (label, field) in [("前缀", prefix), ("后缀", suffix), ("查找文字", find), ("替换为", replace)] {
            field.placeholderString = label; field.widthAnchor.constraint(equalToConstant: 360).isActive = true
            fields.addArrangedSubview(field)
        }
        fields.addArrangedSubview(numbering); fields.frame = NSRect(x: 0, y: 0, width: 360, height: 158); alert.accessoryView = fields
        present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var names: [String: String] = [:]
            var lines: [String] = []
            for (index, path) in paths.enumerated() {
                let oldName = (path as NSString).lastPathComponent
                let ext = directoryFlags[path] == true ? "" : (oldName as NSString).pathExtension
                var base = ext.isEmpty ? oldName : (oldName as NSString).deletingPathExtension
                if !find.stringValue.isEmpty { base = base.replacingOccurrences(of: find.stringValue, with: replace.stringValue) }
                let seq = numbering.state == .on ? String(format: "%03d", index + 1) : ""
                let newName = prefix.stringValue + base + seq + suffix.stringValue + (ext.isEmpty ? "" : "." + ext)
                guard self.validName(newName) else { return }
                if newName != oldName { names[path] = newName; lines.append(oldName + " → " + newName) }
            }
            guard !names.isEmpty else { self.message("名称没有变化，请修改规则。"); return }
            let destinations = names.map { (path, name) in ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name).lowercased() }
            guard Set(destinations).count == destinations.count else { self.message("预览发现同一目录存在重复的新名称，请修改规则。"); return }
            let preview = NSAlert(); preview.messageText = "确认批量改名 \(names.count) 项"; preview.informativeText = "下面是实际将执行的名称变化。已存在的名称会另行询问。"
            preview.addButton(withTitle: "确认改名"); preview.addButton(withTitle: "取消")
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 530, height: 270)); scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.font = .monospacedSystemFont(ofSize: 11, weight: .regular); text.string = lines.joined(separator: "\n"); text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true
            scroll.documentView = text; preview.accessoryView = scroll
            self.present(preview) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.enqueue(.init(kind: .rename, sources: paths.filter { names[$0] != nil }.map { URL(fileURLWithPath: $0) }, names: names), title: "批量改名") }
            }
        }
    }

    @objc private func createFolder(_ sender: Any?) {
        guard !sourcePane.isCollection else { message("请先打开要创建文件夹的目标目录。"); return }
        guard sourcePane.isUsableDirectoryDestination else { message("当前目录尚未读取成功，请等待读取完成或打开其它目标目录。"); return }
        let parent = sourcePane.currentPath
        prompt(title: "新建文件夹", detail: "位置：" + parent, value: "新建文件夹", button: "创建") { [weak self] name in
            guard let self, let name, self.validName(name) else { return }
            self.enqueue(.init(kind: .createFolder, sources: [], destination: URL(fileURLWithPath: parent).appendingPathComponent(name)), title: "新建文件夹")
        }
    }

    @objc private func trashSelected(_ sender: Any?) {
        let paths = sourcePane.selectedPaths
        guard !paths.isEmpty else { message("请先选择要移至废纸篓的项目。"); return }
        confirm(title: "将 \(paths.count) 项移至废纸篓？", detail: paths.prefix(8).joined(separator: "\n") + (paths.count > 8 ? "\n……" : "") + "\n\n可以在 Finder 的废纸篓中恢复。", button: "移至废纸篓") { [weak self] accepted in
            if accepted { self?.enqueue(.init(kind: .trash, sources: paths.map { URL(fileURLWithPath: $0) }), title: "移至废纸篓") }
        }
    }

    private func validName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else { message("名称不能为空，也不能包含 / 或 :。"); return false }
        return true
    }

    private func enqueue(_ request: FileOperationRequest, title: String) {
        jobs.append(QueuedJob(request: request, title: title)); runNextJob()
    }

    private func runNextJob() {
        guard runningJob == nil, !jobs.isEmpty else { return }
        let job = jobs.removeFirst(); runningJob = job
        onOperationStateChanged?()
        cancelTaskButton.isEnabled = true; taskProgress.doubleValue = 0
        taskLabel.stringValue = job.title + " · 正在准备" + (jobs.isEmpty ? "" : " · 排队 \(jobs.count) 项任务")
        activeToken = fileService.start(request: job.request, resolveConflict: { [weak self] conflict, resolve in
            guard let self else { resolve(.cancel); return }
            let alert = NSAlert(); alert.messageText = "目标已存在：" + conflict.destination.lastPathComponent
            alert.informativeText = "来源：\(conflict.source.path)\n目标：\(conflict.destination.path)\n\n复制或移动时，替换会先保留现有目标的恢复备份；改名不允许覆盖现有项目。"
            alert.addButton(withTitle: "保留两份"); alert.addButton(withTitle: "跳过"); alert.addButton(withTitle: "替换"); alert.addButton(withTitle: "取消任务")
            alert.buttons[2].isEnabled = job.request.kind != .rename
            self.present(alert) { response in
                switch response {
                case .alertFirstButtonReturn: resolve(.keepBoth)
                case .alertSecondButtonReturn: resolve(.skip)
                case .alertThirdButtonReturn: resolve(.replace)
                default: resolve(.cancel)
                }
            }
        }, progress: { [weak self] progress in
            guard let self else { return }
            self.taskProgress.maxValue = Double(max(progress.total, 1)); self.taskProgress.doubleValue = Double(progress.completed)
            self.taskLabel.stringValue = "\(job.title) \(progress.completed)/\(progress.total) · \((progress.currentPath as NSString).lastPathComponent)" + (self.jobs.isEmpty ? "" : " · 排队 \(self.jobs.count)")
            if let bytes = progress.currentBytes, let total = progress.totalBytes {
                self.taskLabel.stringValue += " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            }
            self.taskLabel.toolTip = self.taskLabel.stringValue
        }, completion: { [weak self] report in
            guard let self else { return }
            self.activeToken = nil; self.runningJob = nil; self.cancelTaskButton.isEnabled = false
            self.taskProgress.doubleValue = self.taskProgress.maxValue
            let summary = "\(job.title)：完成 \(report.completedPaths.count) 项" + (report.copiedPaths.isEmpty ? "" : "，仅复制 \(report.copiedPaths.count) 项（移动未完成）") + (report.skipped > 0 ? "，跳过 \(report.skipped) 项" : "") + (report.cancelled ? "，已取消" : "") + (report.errors.isEmpty ? "" : "，失败 \(report.errors.count) 项")
            self.taskLabel.stringValue = summary; self.message(summary); self.refresh()
            let actualPaths = report.completedPaths + report.copiedPaths + report.recoveryPaths
            let changedPaths = actualPaths.isEmpty ? [] : job.request.sources.map(\.path) + actualPaths
            self.onFilesChanged?(Array(Set(changedPaths)))
            if !report.recoveryPaths.isEmpty {
                self.recoveryPaths.append(contentsOf: report.recoveryPaths)
                self.recoveryButton.isHidden = false
                self.message(summary + " · 原目标保留在恢复备份，可点「查看恢复备份」。")
            }
            self.onOperationStateChanged?()
            if !report.errors.isEmpty {
                let alert = NSAlert(); alert.messageText = "部分操作未完成"; alert.informativeText = report.errors.prefix(12).joined(separator: "\n"); alert.addButton(withTitle: "知道了"); self.present(alert) { _ in self.runNextJob() }
            } else { self.runNextJob() }
        })
    }

    @objc private func cancelTask(_ sender: Any?) { activeToken?.cancel(); message("正在取消当前任务；已完成的项目会保留。") }
    @objc private func showRecovery(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(recoveryPaths.map { URL(fileURLWithPath: $0) })
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }
    private func confirm(title: String, detail: String, button: String, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.addButton(withTitle: button); alert.addButton(withTitle: "取消")
        present(alert) { completion($0 == .alertFirstButtonReturn) }
    }
    private func prompt(title: String, detail: String, value: String, button: String, completion: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.addButton(withTitle: button); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 390, height: 25); alert.accessoryView = field
        present(alert) { response in completion(response == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
    private func message(_ value: String) { messageLabel.stringValue = value; onMessage?(value) }
}

enum WorkspacePaneAction { case copy, move, rename, batchRename, trash, newFolder, reveal, copyPaths, copyClipboard, cutClipboard, pasteClipboard, preview }

private final class WorkspaceTab {
    var path: String
    var collection: [String]?
    var history: [String]
    var historyIndex = 0
    var selection: Set<String> = []
    init(path: String, collection: [String]? = nil) { self.path = path; self.collection = collection; history = [path] }
    var title: String { collection == nil ? ((path as NSString).lastPathComponent.isEmpty ? "磁盘根目录" : (path as NSString).lastPathComponent) : "搜索选中项" }
}

@MainActor
private final class WorkspacePaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var paneIndex = 0
    var showHidden = false
    var onFocus: (() -> Void)?
    var onSelection: ((String?) -> Void)?
    var onMessage: ((String) -> Void)?
    var onStateChange: (() -> Void)?
    var onFavorites: ((NSButton) -> Void)?
    var onDrop: (([String], String) -> Void)?
    var onAction: ((WorkspacePaneAction) -> Void)?
    var onSearchFocusRequested: (() -> Void)?
    private let browser = DirectoryBrowser()
    private var tabs: [WorkspaceTab] = []
    private var selectedTab = 0
    private var entries: [DirectoryEntry] = []
    private var loadGeneration = 0
    private var loading = false
    private var directoryLoadSucceeded = false
    private let table = WorkspaceTableView()
    private let pathField = NSTextField()
    private let tabsStack = NSStackView()
    private let tabsScroll = NSScrollView()
    private let tabsRow = NSStackView()
    private let searchTabButton = NSButton(title: "搜索结果", target: nil, action: nil)
    private let crumbs = NSStackView()
    private let countLabel = NSTextField(labelWithString: "正在读取目录…")
    private let paneLabel = NSTextField(labelWithString: "")
    private let backButton = NSButton(title: "‹", target: nil, action: nil)
    private let forwardButton = NSButton(title: "›", target: nil, action: nil)
    private let upButton = NSButton(title: "↑", target: nil, action: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let directoryContainer = NSView()
    private let bodyContainer = NSView()
    private var searchView: NSView?
    private var searchSelectionProvider: (() -> [FileHit])?
    private(set) var isSearchTabSelected = false
    private var pendingSelection: Set<String> = []
    private var isRestoringSelection = false
    private var currentTab: WorkspaceTab? { tabs.indices.contains(selectedTab) ? tabs[selectedTab] : nil }
    var currentPath: String { currentTab?.path ?? FileManager.default.homeDirectoryForCurrentUser.path }
    var actualDirectoryPath: String { (currentTab?.collection == nil ? currentTab?.path : tabs.first(where: { $0.collection == nil })?.path) ?? FileManager.default.homeDirectoryForCurrentUser.path }
    var isCollection: Bool { isSearchTabSelected || currentTab?.collection != nil }
    var isUsableDirectoryDestination: Bool { !isCollection && !loading && directoryLoadSucceeded }
    private var searchSelection: [FileHit] { searchSelectionProvider?().filter(\.isOnline) ?? [] }
    var selectedPaths: [String] {
        if isSearchTabSelected { return searchSelection.map(\.path) }
        guard !loading else { return [] }
        return table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].path : nil }
    }
    var selectedDirectoryFlags: [(String, Bool)] {
        if isSearchTabSelected { return searchSelection.map { ($0.path, $0.isDirectory) } }
        guard !loading else { return [] }
        return table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? (entries[$0].path, entries[$0].isDirectory) : nil }
    }
    var sessionState: WorkspacePaneState {
        let actual = tabs.filter { $0.collection == nil }
        let paths = actual.map(\.path)
        let current = actual.firstIndex { $0 === currentTab } ?? 0
        return .init(paths: paths.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser.path] : paths, selectedTab: current)
    }

    override func loadView() {
        let root = NSView(); root.wantsLayer = true; root.layer?.cornerRadius = 6; root.layer?.borderWidth = 1; root.layer?.borderColor = NSColor.separatorColor.cgColor; view = root
        let vertical = NSStackView(); vertical.orientation = .vertical; vertical.alignment = .leading; vertical.spacing = 6
        vertical.edgeInsets = NSEdgeInsets(top: 7, left: 7, bottom: 7, right: 7)
        tabsRow.spacing = 4; tabsRow.alignment = .centerY
        paneLabel.font = .boldSystemFont(ofSize: 10)
        let labelHost = TabControlHost(paneLabel); tabsRow.addArrangedSubview(labelHost)
        tabsScroll.hasHorizontalScroller = true; tabsScroll.hasVerticalScroller = false; tabsScroll.autohidesScrollers = true; tabsScroll.drawsBackground = false; tabsScroll.horizontalScroller?.controlSize = .mini
        tabsScroll.frame.size = NSSize(width: 80, height: 36)
        tabsStack.orientation = .horizontal; tabsStack.alignment = .centerY; tabsStack.spacing = 3
        tabsStack.autoresizingMask = [.height]
        tabsScroll.contentView.autoresizesSubviews = true
        tabsScroll.documentView = tabsStack
        tabsRow.addArrangedSubview(tabsScroll)
        labelHost.alignControl(to: tabsScroll.contentView)
        let plus = actionButton("＋", #selector(newTab(_:))); plus.toolTip = "在当前目录新建标签"
        let plusHost = TabControlHost(plus); tabsRow.addArrangedSubview(plusHost); plusHost.alignControl(to: tabsScroll.contentView)
        let close = actionButton("×", #selector(closeTab(_:))); close.toolTip = "关闭当前标签"
        let closeHost = TabControlHost(close); tabsRow.addArrangedSubview(closeHost); closeHost.alignControl(to: tabsScroll.contentView)
        tabsScroll.heightAnchor.constraint(equalToConstant: 36).isActive = true
        tabsScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        tabsRow.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let navigation = NSStackView(); navigation.spacing = 4
        for (b, action, tooltip) in [(backButton, #selector(back(_:)), "后退"), (forwardButton, #selector(forward(_:)), "前进"), (upButton, #selector(up(_:)), "上级目录")] {
            b.target = self; b.action = action; b.bezelStyle = .rounded; b.controlSize = .small; b.widthAnchor.constraint(equalToConstant: 26).isActive = true; b.toolTip = tooltip; navigation.addArrangedSubview(b)
        }
        pathField.delegate = self; pathField.placeholderString = "输入目录路径，按回车打开"; pathField.target = self; pathField.action = #selector(pathEntered(_:)); pathField.font = .systemFont(ofSize: 11); pathField.lineBreakMode = .byTruncatingMiddle; pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.setAccessibilityLabel("第\(paneIndex + 1)栏路径")
        navigation.addArrangedSubview(pathField)
        let star = actionButton("☆", #selector(favorites(_:))); star.toolTip = "常用目录与收藏"; navigation.addArrangedSubview(star)
        let refresh = actionButton("↻", #selector(refreshAction(_:))); refresh.toolTip = "刷新当前目录"; navigation.addArrangedSubview(refresh)
        let crumbScroll = NSScrollView(); crumbScroll.hasHorizontalScroller = false; crumbScroll.hasVerticalScroller = false; crumbScroll.drawsBackground = false
        crumbs.orientation = .horizontal; crumbs.spacing = 2; crumbScroll.documentView = crumbs; crumbScroll.heightAnchor.constraint(equalToConstant: 24).isActive = true
        configureTable()
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        emptyLabel.font = .systemFont(ofSize: 12); emptyLabel.textColor = .secondaryLabelColor; emptyLabel.alignment = .center; emptyLabel.isHidden = true; emptyLabel.maximumNumberOfLines = 6
        countLabel.font = .systemFont(ofSize: 11); countLabel.textColor = .secondaryLabelColor; countLabel.lineBreakMode = .byTruncatingMiddle
        let directoryStack = NSStackView(); directoryStack.orientation = .vertical; directoryStack.alignment = .leading; directoryStack.spacing = 6
        for subview in [navigation, crumbScroll, scroll, countLabel] { directoryStack.addArrangedSubview(subview); subview.widthAnchor.constraint(equalTo: directoryStack.widthAnchor).isActive = true }
        directoryStack.translatesAutoresizingMaskIntoConstraints = false; directoryContainer.addSubview(directoryStack)
        NSLayoutConstraint.activate([directoryStack.leadingAnchor.constraint(equalTo: directoryContainer.leadingAnchor), directoryStack.trailingAnchor.constraint(equalTo: directoryContainer.trailingAnchor), directoryStack.topAnchor.constraint(equalTo: directoryContainer.topAnchor), directoryStack.bottomAnchor.constraint(equalTo: directoryContainer.bottomAnchor)])
        directoryContainer.translatesAutoresizingMaskIntoConstraints = false; bodyContainer.addSubview(directoryContainer)
        NSLayoutConstraint.activate([directoryContainer.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor), directoryContainer.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor), directoryContainer.topAnchor.constraint(equalTo: bodyContainer.topAnchor), directoryContainer.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)])
        for subview in [tabsRow, bodyContainer] { vertical.addArrangedSubview(subview); subview.widthAnchor.constraint(equalTo: vertical.widthAnchor, constant: -14).isActive = true }
        vertical.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(vertical)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false; directoryContainer.addSubview(emptyLabel)
        NSLayoutConstraint.activate([vertical.leadingAnchor.constraint(equalTo: root.leadingAnchor), vertical.trailingAnchor.constraint(equalTo: root.trailingAnchor), vertical.topAnchor.constraint(equalTo: root.topAnchor), vertical.bottomAnchor.constraint(equalTo: root.bottomAnchor), emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor), emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -36)])
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    }

    func installSearchView(_ externalView: NSView, selectionProvider: @escaping () -> [FileHit]) {
        loadViewIfNeeded()
        searchView?.removeFromSuperview()
        searchView = externalView; searchSelectionProvider = selectionProvider
        externalView.removeFromSuperview(); externalView.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(externalView)
        NSLayoutConstraint.activate([externalView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor), externalView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor), externalView.topAnchor.constraint(equalTo: bodyContainer.topAnchor), externalView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)])
        searchTabButton.target = self; searchTabButton.action = #selector(selectSearchTab(_:))
        searchTabButton.bezelStyle = .rounded; searchTabButton.controlSize = .small; searchTabButton.setButtonType(.toggle)
        searchTabButton.toolTip = "全盘搜索结果，选中后可直接整理到另一栏"
        if searchTabButton.superview == nil {
            let host = TabControlHost(searchTabButton)
            tabsRow.insertArrangedSubview(host, at: 1)
            host.alignControl(to: tabsScroll.contentView)
        }
        externalView.isHidden = !isSearchTabSelected
        rebuildTabs()
    }

    func showSearchResults() {
        loadViewIfNeeded(); guard searchView != nil, !isSearchTabSelected else { return }
        currentTab?.selection = Set(selectedPaths)
        isSearchTabSelected = true
        directoryContainer.isHidden = true; searchView?.isHidden = false
        rebuildTabs()
    }

    func showDirectoryTab() {
        loadViewIfNeeded()
        if isSearchTabSelected {
            isSearchTabSelected = false
            directoryContainer.isHidden = false; searchView?.isHidden = true
            pendingSelection = currentTab?.selection ?? []
            rebuildTabs(); reload()
        }
        onFocus?(); focusList()
    }

    /// Only explicit navigation transfers the keyboard responder. Background
    /// directory and index refreshes preserve the user's current editing focus.
    private func focusList() {
        if isSearchTabSelected { onSearchFocusRequested?() }
        else { view.window?.makeFirstResponder(table) }
    }

    private func configureTable() {
        table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = true; table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 28; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self; table.doubleAction = #selector(openSelected(_:))
        table.focused = { [weak self] in self?.onFocus?() }
        table.openSelected = { [weak self] in self?.openSelected(nil) }
        table.previewSelected = { [weak self] in self?.onAction?(.preview) }
        table.goUp = { [weak self] in self?.up(nil) }
        table.deleteSelected = { [weak self] in self?.onAction?(.trash) }
        table.renameSelected = { [weak self] in self?.onAction?(.rename) }
        table.copySelected = { [weak self] in self?.onFocus?(); self?.onAction?(.copyClipboard) }
        table.cutSelected = { [weak self] in self?.onFocus?(); self?.onAction?(.cutClipboard) }
        table.pasteSelected = { [weak self] in self?.onFocus?(); self?.onAction?(.pasteClipboard) }
        table.newTab = { [weak self] in self?.newTab(nil) }
        table.closeTab = { [weak self] in self?.closeTab(nil) }
        for (id, title, width) in [("name", "名称", 220.0), ("size", "大小", 85.0), ("modified", "修改时间", 140.0), ("type", "类型", 75.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; column.minWidth = id == "name" ? 100 : 60
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.registerForDraggedTypes([.fileURL]); table.setDraggingSourceOperationMask(.copy, forLocal: false); table.setDraggingSourceOperationMask(.copy, forLocal: true)
        let menu = NSMenu()
        for (title, action) in [("打开", #selector(openSelected(_:))), ("在 Finder 中显示", #selector(revealAction(_:))), ("复制到另一栏", #selector(copyAction(_:))), ("移动到另一栏", #selector(moveAction(_:))), ("复制", #selector(copyClipboardAction(_:))), ("剪切", #selector(cutClipboardAction(_:))), ("粘贴到当前目录", #selector(pasteClipboardAction(_:))), ("重命名…", #selector(renameAction(_:))), ("批量改名…", #selector(batchRenameAction(_:))), ("复制完整路径", #selector(copyPathsAction(_:))), ("新建文件夹…", #selector(newFolderAction(_:))), ("移至废纸篓…", #selector(trashAction(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        table.menu = menu; table.setAccessibilityLabel("第\(paneIndex + 1)栏文件列表")
    }

    private func actionButton(_ title: String, _ selector: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: selector); b.bezelStyle = .rounded; b.controlSize = .small; return b }

    func restore(_ state: WorkspacePaneState) {
        loadViewIfNeeded(); tabs = state.paths.map { WorkspaceTab(path: $0) }
        if tabs.isEmpty { tabs = [WorkspaceTab(path: FileManager.default.homeDirectoryForCurrentUser.path)] }
        selectedTab = min(max(state.selectedTab, 0), tabs.count - 1); rebuildTabs(); reload()
    }

    func setActive(_ active: Bool) {
        loadViewIfNeeded(); paneLabel.stringValue = "\(paneIndex == 0 ? "左栏" : "右栏")\(active ? " ●" : "")"
        paneLabel.superview?.invalidateIntrinsicContentSize()
        view.layer?.borderColor = (active ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        view.layer?.borderWidth = active ? 2 : 1
    }

    func navigate(to path: String, selecting: [String] = [], recordHistory: Bool = true) {
        loadViewIfNeeded(); onFocus?()
        isSearchTabSelected = false; directoryContainer.isHidden = false; searchView?.isHidden = true
        let normalized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        if tabs.isEmpty { tabs = [WorkspaceTab(path: normalized)]; selectedTab = 0 }
        guard let tab = currentTab else { return }
        tab.collection = nil
        if recordHistory, normalized != tab.path {
            tab.history = Array(tab.history.prefix(tab.historyIndex + 1)); tab.history.append(normalized); tab.historyIndex = tab.history.count - 1
        }
        tab.path = normalized; tab.selection = Set(selecting); pendingSelection = Set(selecting)
        rebuildTabs(); reload(); focusList(); onStateChange?()
    }

    /// Search browsing opens or reuses a real directory tab. The pinned search
    /// slot and the opposite destination directory remain intact.
    func navigateInDirectoryTab(to path: String, selecting: [String] = []) {
        loadViewIfNeeded()
        let normalized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        if !isSearchTabSelected { currentTab?.selection = Set(selectedPaths) }
        if let index = tabs.firstIndex(where: { $0.collection == nil && $0.path == normalized }) { selectedTab = index }
        else { tabs.append(WorkspaceTab(path: normalized)); selectedTab = tabs.count - 1 }
        navigate(to: normalized, selecting: selecting)
    }

    func openCollection(_ paths: [String]) {
        loadViewIfNeeded()
        isSearchTabSelected = false; directoryContainer.isHidden = false; searchView?.isHidden = true
        if let existing = tabs.firstIndex(where: { $0.collection != nil }) { tabs.remove(at: existing) }
        let tab = WorkspaceTab(path: (paths[0] as NSString).deletingLastPathComponent, collection: paths)
        tab.selection = Set(paths); tabs.append(tab); selectedTab = tabs.count - 1; pendingSelection = Set(paths)
        rebuildTabs(); reload(); focusList(); onStateChange?()
    }

    func reload() {
        loadViewIfNeeded(); guard let tab = currentTab else { return }
        // The external search table owns refreshes and selection. Directory
        // refreshes never repurpose it or deliver a stale directory selection.
        guard !isSearchTabSelected else { return }
        loadGeneration += 1; let generation = loadGeneration; loading = true; directoryLoadSucceeded = false
        pathField.stringValue = tab.collection == nil ? tab.path : "搜索选中项（\(tab.collection!.count) 项，来自多个目录）"
        pathField.isEditable = true
        countLabel.stringValue = "正在读取…"; emptyLabel.isHidden = true
        if pendingSelection.isEmpty { pendingSelection = tab.selection }
        // Navigation changes the path before the asynchronous listing arrives.
        // Remove the previous listing immediately so its selection can never
        // become an operation source under the new directory or tab.
        isRestoringSelection = true
        entries.removeAll(keepingCapacity: true)
        table.deselectAll(nil); table.reloadData()
        isRestoringSelection = false
        onSelection?(nil)
        rebuildCrumbs(); updateNavigation()
        if let paths = tab.collection {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var rows: [DirectoryEntry] = []
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]) else { continue }
                    rows.append(DirectoryEntry(path: path, isDirectory: values.isDirectory ?? false, size: values.fileSize.map { Int64($0) }, modified: values.contentModificationDate, isSymbolicLink: values.isSymbolicLink ?? false))
                }
                let loaded = rows
                DispatchQueue.main.async { self?.accept(.success(loaded), generation: generation) }
            }
        } else { browser.load(path: tab.path, showHidden: showHidden) { [weak self] result in self?.accept(result, generation: generation) } }
    }

    private func accept(_ result: Result<[DirectoryEntry], Error>, generation: Int) {
        guard generation == loadGeneration else { return }; loading = false
        switch result {
        case .success(let rows):
            directoryLoadSucceeded = currentTab?.collection == nil
            entries = rows; sortEntries(); table.reloadData(); restoreSelection()
            emptyLabel.stringValue = "此目录为空"; emptyLabel.isHidden = !entries.isEmpty
            if currentTab?.collection != nil { currentTab?.collection = entries.map(\.path) }
            updateCount()
        case .failure(let error):
            directoryLoadSucceeded = false
            entries = []; table.reloadData(); emptyLabel.stringValue = "无法读取此目录\n\(error.localizedDescription)\n\n可在路径栏输入其它目录，或使用常用目录。"; emptyLabel.isHidden = false
            countLabel.stringValue = "读取失败"; onMessage?("读取目录失败：" + currentPath + " · " + error.localizedDescription)
        }
    }

    private func restoreSelection() {
        let selection = IndexSet(entries.indices.filter { pendingSelection.contains(entries[$0].path) })
        isRestoringSelection = true; table.selectRowIndexes(selection, byExtendingSelection: false); isRestoringSelection = false
        if let first = selection.first { table.scrollRowToVisible(first) }
        pendingSelection = []
        let directorySelection = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].path : nil }
        currentTab?.selection = Set(directorySelection)
        if !isSearchTabSelected { onSelection?(directorySelection.first) }
    }
    private func updateCount() {
        countLabel.stringValue = "\(entries.count) 项" + (selectedPaths.isEmpty ? "" : " · 已选 \(selectedPaths.count) 项") + (isCollection ? " · 目标请使用另一栏目录" : " · 文件夹大小不递归统计")
    }

    private func rebuildTabs() {
        tabsStack.arrangedSubviews.forEach { tabsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        searchTabButton.state = isSearchTabSelected ? .on : .off
        for (index, tab) in tabs.enumerated() {
            let button = NSButton(title: tab.title, target: self, action: #selector(selectTab(_:))); button.tag = index; button.bezelStyle = .rounded; button.controlSize = .small; button.state = !isSearchTabSelected && index == selectedTab ? .on : .off; button.toolTip = tab.collection == nil ? "目录标签：" + tab.path + "\n点击浏览此文件夹；与全盘搜索条件无关。" : "从全盘搜索导入的文件与文件夹"; button.setButtonType(.toggle)
            button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "目录标签")
            button.imagePosition = .imageLeading
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true; tabsStack.addArrangedSubview(button)
        }
        tabsStack.layoutSubtreeIfNeeded()
        tabsStack.frame.size = NSSize(width: tabsStack.fittingSize.width,
                                     height: max(1, tabsScroll.contentView.bounds.height))
    }

    private func rebuildCrumbs() {
        crumbs.arrangedSubviews.forEach { crumbs.removeArrangedSubview($0); $0.removeFromSuperview() }
        if isCollection { let label = NSTextField(labelWithString: "搜索选中项 · 双击目录打开，双击文件使用默认应用"); label.font = .systemFont(ofSize: 10); crumbs.addArrangedSubview(label) }
        else {
            let parts = (currentPath as NSString).pathComponents
            var accumulated = ""
            for (index, part) in parts.enumerated() {
                if index == 0 { accumulated = part } else { accumulated = (accumulated as NSString).appendingPathComponent(part) }
                let button = NSButton(title: part == "/" ? "磁盘" : part, target: self, action: #selector(crumbSelected(_:))); button.bezelStyle = .recessed; button.controlSize = .small; button.identifier = NSUserInterfaceItemIdentifier(accumulated); button.toolTip = accumulated
                crumbs.addArrangedSubview(button)
                if index < parts.count - 1 { let arrow = NSTextField(labelWithString: "›"); arrow.textColor = .tertiaryLabelColor; crumbs.addArrangedSubview(arrow) }
            }
        }
        crumbs.layoutSubtreeIfNeeded(); crumbs.frame.size = crumbs.fittingSize
    }
    private func updateNavigation() { backButton.isEnabled = (currentTab?.historyIndex ?? 0) > 0; forwardButton.isEnabled = (currentTab?.historyIndex ?? 0) < (currentTab?.history.count ?? 1) - 1; upButton.isEnabled = !isCollection && currentPath != "/" }

    @objc private func selectTab(_ sender: NSButton) {
        guard tabs.indices.contains(sender.tag) else { return }
        if !isSearchTabSelected { currentTab?.selection = Set(selectedPaths) }
        isSearchTabSelected = false; directoryContainer.isHidden = false; searchView?.isHidden = true
        selectedTab = sender.tag; pendingSelection = currentTab?.selection ?? []; onFocus?(); rebuildTabs(); reload(); focusList(); onStateChange?()
    }
    @objc private func selectSearchTab(_ sender: NSButton) { showSearchResults(); onFocus?(); focusList(); onSelection?(selectedPaths.first) }
    func createNewTab() { newTab(nil) }
    func closeCurrentTab() { closeTab(nil) }
    func openCurrentSelection() { openSelected(nil) }
    @objc private func newTab(_ sender: Any?) {
        if !isSearchTabSelected { currentTab?.selection = Set(selectedPaths) }
        isSearchTabSelected = false; directoryContainer.isHidden = false; searchView?.isHidden = true
        tabs.append(WorkspaceTab(path: currentPath)); selectedTab = tabs.count - 1; onFocus?(); rebuildTabs(); reload(); focusList(); onStateChange?()
    }
    @objc private func closeTab(_ sender: Any?) {
        if isSearchTabSelected { showDirectoryTab(); onFocus?(); return }
        guard tabs.count > 1 else { onMessage?("至少保留一个目录标签。"); return }; tabs.remove(at: selectedTab); selectedTab = min(selectedTab, tabs.count - 1); pendingSelection = currentTab?.selection ?? []; onFocus?(); rebuildTabs(); reload(); focusList(); onStateChange?()
    }
    @objc private func pathEntered(_ sender: Any?) { navigate(to: pathField.stringValue) }
    @objc private func crumbSelected(_ sender: NSButton) { if let path = sender.identifier?.rawValue { navigate(to: path) } }
    @objc private func back(_ sender: Any?) { guard let tab = currentTab, tab.historyIndex > 0 else { return }; tab.historyIndex -= 1; navigate(to: tab.history[tab.historyIndex], recordHistory: false) }
    @objc private func forward(_ sender: Any?) { guard let tab = currentTab, tab.historyIndex < tab.history.count - 1 else { return }; tab.historyIndex += 1; navigate(to: tab.history[tab.historyIndex], recordHistory: false) }
    @objc private func up(_ sender: Any?) { guard !isCollection else { return }; let previous = currentPath; navigate(to: (currentPath as NSString).deletingLastPathComponent, selecting: [previous]) }
    @objc private func favorites(_ sender: NSButton) { onFocus?(); onFavorites?(sender) }
    @objc private func refreshAction(_ sender: Any?) { onFocus?(); reload() }
    @objc private func openSelected(_ sender: Any?) {
        let paths = selectedPaths; guard !paths.isEmpty else { return }; onFocus?()
        let isDirectory = isSearchTabSelected ? searchSelection.first(where: { $0.path == paths[0] })?.isDirectory : entries.first(where: { $0.path == paths[0] })?.isDirectory
        if paths.count == 1, isDirectory == true { navigate(to: paths[0]) }
        else {
            if paths.count > 10 { onMessage?("一次打开最多 10 个文件，请缩小选择。"); return }
            for path in paths { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        }
    }
    @objc private func copyAction(_ sender: Any?) { onFocus?(); onAction?(.copy) }
    @objc private func moveAction(_ sender: Any?) { onFocus?(); onAction?(.move) }
    @objc private func renameAction(_ sender: Any?) { onFocus?(); onAction?(.rename) }
    @objc private func batchRenameAction(_ sender: Any?) { onFocus?(); onAction?(.batchRename) }
    @objc private func trashAction(_ sender: Any?) { onFocus?(); onAction?(.trash) }
    @objc private func newFolderAction(_ sender: Any?) { onFocus?(); onAction?(.newFolder) }
    @objc private func revealAction(_ sender: Any?) { onFocus?(); onAction?(.reveal) }
    @objc private func copyPathsAction(_ sender: Any?) { onFocus?(); onAction?(.copyPaths) }
    @objc private func copyClipboardAction(_ sender: Any?) { onFocus?(); onAction?(.copyClipboard) }
    @objc private func cutClipboardAction(_ sender: Any?) { onFocus?(); onAction?(.cutClipboard) }
    @objc private func pasteClipboardAction(_ sender: Any?) { onFocus?(); onAction?(.pasteClipboard) }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let tableColumn else { return nil }
        let entry = entries[row]; let id = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id: id)
        switch id.rawValue {
        case "name": cell.textField?.stringValue = entry.name; cell.imageView?.image = NSImage(systemSymbolName: entry.isDirectory ? "folder.fill" : (entry.isSymbolicLink ? "doc.badge.arrow.up" : "doc"), accessibilityDescription: entry.isDirectory ? "文件夹" : "文件"); cell.imageView?.contentTintColor = entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
        case "size": cell.textField?.stringValue = entry.isDirectory ? "—" : entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        case "modified": cell.textField?.stringValue = entry.modified.map { Self.dateFormatter.string(from: $0) } ?? "—"
        default: cell.textField?.stringValue = entry.isDirectory ? "文件夹" : ((entry.name as NSString).pathExtension.isEmpty ? "文件" : (entry.name as NSString).pathExtension.uppercased())
        }
        cell.toolTip = entry.path; return cell
    }
    private func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(); cell.identifier = id
        let text = NSTextField(labelWithString: ""); text.font = .systemFont(ofSize: 12); text.lineBreakMode = .byTruncatingMiddle; text.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(text); cell.textField = text
        if id.rawValue == "name" {
            let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(icon); cell.imageView = icon
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 17), icon.heightAnchor.constraint(equalToConstant: 17), text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)])
        } else { text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5).isActive = true }
        NSLayoutConstraint.activate([text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    private static let dateFormatter: DateFormatter = { let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.locale = Locale(identifier: "zh_CN"); return formatter }()
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSearchTabSelected, !isRestoringSelection, !loading else { return }; currentTab?.selection = Set(selectedPaths); updateCount(); onSelection?(selectedPaths.first)
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { guard !loading else { return }; pendingSelection = Set(selectedPaths); sortEntries(); table.reloadData(); restoreSelection() }
    private func sortEntries() {
        let descriptor = table.sortDescriptors.first; let key = descriptor?.key ?? "name"; let ascending = descriptor?.ascending ?? true
        entries.sort { a, b in
            var result: ComparisonResult
            if key == "size" { let lhs = a.size ?? -1, rhs = b.size ?? -1; result = lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending }
            else if key == "modified" { result = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast) }
            else if key == "type" { let lhs = a.isDirectory ? "" : (a.name as NSString).pathExtension; let rhs = b.isDirectory ? "" : (b.name as NSString).pathExtension; result = lhs.localizedStandardCompare(rhs) }
            else { if a.isDirectory != b.isDirectory { return a.isDirectory }; result = a.name.localizedStandardCompare(b.name) }
            if result == .orderedSame { result = a.path.localizedStandardCompare(b.path) }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { entries.indices.contains(row) ? NSURL(fileURLWithPath: entries[row].path) : nil }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation { guard isUsableDirectoryDestination, info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }; tableView.setDropRow(-1, dropOperation: .on); return .copy }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard isUsableDirectoryDestination, let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onFocus?(); onDrop?(urls.map(\.path), currentPath); return true
    }
    func controlTextDidBeginEditing(_ obj: Notification) { onFocus?() }
}

@MainActor
private final class TabControlHost: NSView {
    private let control: NSView
    init(_ control: NSView) {
        self.control = control
        super.init(frame: .zero)
        control.translatesAutoresizingMaskIntoConstraints = false; addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 36)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: max(0, control.intrinsicContentSize.width), height: 36) }
    // Legacy scrollbars can reduce the viewport. Every pinned control shares
    // the directory tab content's center, without moving inside its scroller.
    func alignControl(to viewport: NSView) { control.centerYAnchor.constraint(equalTo: viewport.centerYAnchor).isActive = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class WorkspaceSplitView: NSSplitView {
    var onDividerInteraction: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onDividerInteraction?(); super.mouseDown(with: event) }
}

@MainActor
private final class WorkspaceTableView: NSTableView {
    var focused: (() -> Void)?
    var openSelected: (() -> Void)?
    var previewSelected: (() -> Void)?
    var goUp: (() -> Void)?
    var deleteSelected: (() -> Void)?
    var renameSelected: (() -> Void)?
    var copySelected: (() -> Void)?
    var cutSelected: (() -> Void)?
    var pasteSelected: (() -> Void)?
    var newTab: (() -> Void)?
    var closeTab: (() -> Void)?
    @objc func copy(_ sender: Any?) { copySelected?() }
    @objc func cut(_ sender: Any?) { cutSelected?() }
    @objc func paste(_ sender: Any?) { pasteSelected?() }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); if accepted { focused?() }; return accepted }
    override func mouseDown(with event: NSEvent) { focused?(); super.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) {
        focused?(); let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        super.rightMouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        focused?()
        if event.modifierFlags.contains(.command), event.keyCode == 17 { newTab?(); return }
        if event.modifierFlags.contains(.command), event.keyCode == 13 { closeTab?(); return }
        if event.keyCode == 36 || event.keyCode == 76 { openSelected?(); return }
        if event.keyCode == 49, !event.modifierFlags.contains(.command) { previewSelected?(); return }
        if event.keyCode == 126, event.modifierFlags.contains(.command) { goUp?(); return }
        if event.keyCode == 51, event.modifierFlags.contains(.command) { deleteSelected?(); return }
        if event.keyCode == 120 { renameSelected?(); return }
        super.keyDown(with: event)
    }
}

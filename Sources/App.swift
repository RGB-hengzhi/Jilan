import AppKit
import Quartz
import Carbon

@main
struct AppMain {
    static func main() {
        let arguments = CommandLine.arguments
        if let status = ScanWorker.runIfRequested(arguments: arguments) { exit(status) }
        if arguments.contains("--self-test") || arguments.contains("--benchmark") || arguments.contains("--scan-diagnostic") || arguments.contains("--cache-diagnostic") {
            exit(Diagnostic.run(arguments: arguments))
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var mainController: MainWindowController!
    private var statusItem: NSStatusItem?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var waitingForFileJobs = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        mainController = MainWindowController(model: model)
        mainController.onOperationStateChanged = { [weak self] in
            guard let self, self.waitingForFileJobs, !self.mainController.hasActiveOperations else { return }
            self.waitingForFileJobs = false
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        installMenus()
        installStatusItem()
        if !RuntimePaths.isTestingInstance { registerHotKey() }
        showMainWindow(nil)
        model.start()
        if CommandLine.arguments.contains("--ui-smoke-test") {
            fputs("UI_SMOKE_READY\n", stderr)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mainController.hasActiveOperations else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "还有文件任务正在执行"
        alert.informativeText = "退出前需要等待取消收尾，以保留源文件并清理未完成的复制。已经完成的操作会保留。"
        alert.addButton(withTitle: "取消任务后退出")
        alert.addButton(withTitle: "继续运行")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        waitingForFileJobs = true
        mainController.cancelFileOperations()
        if !mainController.hasActiveOperations { waitingForFileJobs = false; return .terminateNow }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainController.saveWorkspace()
        model.onChange = nil
        model.shutdown()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    @objc func showMainWindow(_ sender: Any?) {
        mainController.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        mainController.window?.makeKeyAndOrderFront(sender)
        mainController.showSearch()
        mainController.focusSearch()
    }

    @objc private func addFolder(_ sender: Any?) { showMainWindow(sender); model.addFolder() }
    @objc private func addWholeDisks(_ sender: Any?) { showMainWindow(sender); model.addWholeDisks() }
    @objc private func refreshAll(_ sender: Any?) { model.refreshAll() }
    @objc private func privacy(_ sender: Any?) { model.openPrivacySettings() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(sender) }
    @objc private func about(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "疾览 · Jilan",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.2.1",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
            .credits: NSAttributedString(string: "by 塔贰舅\n\n全盘即时搜索与双栏文件管理\n\n搜索索引保存在这台 Mac 上。\n移植并改造 Cling 的 SIMD 与独立索引核心。\n开源声明和许可证见「开源声明」。"),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 塔贰舅 · GPL-3.0 开源许可"
        ])
    }
    @objc private func openNotices(_ sender: Any?) {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("docs/开源声明.md"))
            candidates.append(resourceURL.appendingPathComponent("OPEN_SOURCE_NOTICES.md"))
        }
        candidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("docs/开源声明.md"))
        if let url = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/FuzzyIdeas/Cling")!)
        }
    }

    private func installMenus() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "疾览")
        appItem.submenu = appMenu
        append("关于疾览", action: #selector(about(_:)), to: appMenu)
        append("开源声明", action: #selector(openNotices(_:)), to: appMenu)
        appMenu.addItem(.separator())
        append("完全磁盘访问权限…", action: #selector(privacy(_:)), to: appMenu)
        appMenu.addItem(.separator())
        append("隐藏疾览", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp, to: appMenu)
        append("退出疾览", action: #selector(quit(_:)), key: "q", to: appMenu)

        let fileItem = NSMenuItem()
        fileItem.title = "文件"
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        append("添加索引文件夹…", action: #selector(addFolder(_:)), key: "o", to: fileMenu)
        append("索引全部磁盘", action: #selector(addWholeDisks(_:)), to: fileMenu)
        append("重新扫描所有位置", action: #selector(refreshAll(_:)), key: "r", to: fileMenu)
        fileMenu.addItem(.separator())
        append("新建文件管理标签", action: #selector(MainWindowController.newWorkspaceTab(_:)), key: "t", target: mainController, to: fileMenu)
        append("关闭当前标签", action: #selector(MainWindowController.closeWorkspaceTab(_:)), key: "w", target: mainController, to: fileMenu)
        fileMenu.addItem(.separator())
        append("打开选中项", action: #selector(MainWindowController.openSelection(_:)), target: mainController, to: fileMenu)
        let reveal = append("在 Finder 中显示", action: #selector(MainWindowController.revealSelection(_:)), key: "\r", target: mainController, to: fileMenu)
        reveal.keyEquivalentModifierMask = [.command]
        let copy = append("复制完整路径", action: #selector(MainWindowController.copySelection(_:)), key: "c", target: mainController, to: fileMenu)
        copy.keyEquivalentModifierMask = [.command, .shift]
        append("快速预览", action: #selector(MainWindowController.previewSelection(_:)), target: mainController, to: fileMenu)
        append("在应用内浏览所在目录", action: #selector(MainWindowController.browseSelection(_:)), target: mainController, to: fileMenu)

        let editItem = NSMenuItem()
        editItem.title = "编辑"
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        append("撤销", action: Selector(("undo:")), key: "z", target: nil, to: editMenu)
        append("剪切", action: #selector(NSText.cut(_:)), key: "x", target: nil, to: editMenu)
        append("复制", action: #selector(NSText.copy(_:)), key: "c", target: nil, to: editMenu)
        append("粘贴", action: #selector(NSText.paste(_:)), key: "v", target: nil, to: editMenu)
        append("全选", action: #selector(NSText.selectAll(_:)), key: "a", target: nil, to: editMenu)

        let windowItem = NSMenuItem()
        windowItem.title = "窗口"
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        append("显示主窗口", action: #selector(showMainWindow(_:)), key: "0", to: windowMenu)
        append("文件管理工作区", action: #selector(MainWindowController.showWorkspaceAction(_:)), key: "1", target: mainController, to: windowMenu)
        append("聚焦搜索", action: #selector(MainWindowController.focusSearchAction(_:)), key: "f", target: mainController, to: windowMenu)
        append("最小化", action: #selector(NSWindow.performMiniaturize(_:)), key: "m", target: nil, to: windowMenu)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @discardableResult
    private func append(_ title: String, action: Selector, key: String = "", target: AnyObject? = nil, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        // Standard Edit and Window commands follow the active responder.
        if action == #selector(NSText.cut(_:)) || action == #selector(NSText.copy(_:)) || action == #selector(NSText.paste(_:)) || action == #selector(NSText.selectAll(_:)) || action == Selector(("undo:")) || action == #selector(NSWindow.performMiniaturize(_:)) { item.target = nil }
        menu.addItem(item)
        return item
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "疾览 · Jilan")
        item.button?.toolTip = "疾览 · Jilan · Control + Option + 空格"
        let menu = NSMenu()
        append("打开疾览  ⌃⌥空格", action: #selector(showMainWindow(_:)), to: menu)
        menu.addItem(.separator())
        append("添加索引文件夹…", action: #selector(addFolder(_:)), to: menu)
        append("重新扫描所有位置", action: #selector(refreshAll(_:)), to: menu)
        menu.addItem(.separator())
        append("退出疾览", action: #selector(quit(_:)), to: menu)
        item.menu = menu
        statusItem = item
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in delegate.showMainWindow(nil) }
            return noErr
        }
        let result = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        guard result == noErr else { return }
        let identifier = EventHotKeyID(signature: OSType(0x51464E44), id: 1)
        let registration = RegisterEventHotKey(49, UInt32(controlKey | optionKey), identifier, GetApplicationEventTarget(), 0, &hotKey)
        if registration != noErr { mainController.showHotKeyUnavailable() }
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    private let model: AppModel
    var onOperationStateChanged: (() -> Void)?
    var hasActiveOperations: Bool { workspace?.hasActiveOperations ?? false }
    func cancelFileOperations() { workspace?.cancelOperations() }
    private let searchField = NSSearchField()
    private let extensionField = NSTextField()
    private let sizeField = NSTextField()
    private let modifiedField = NSTextField()
    private let sidebarToggle = NSButton(checkboxWithTitle: "索引位置", target: nil, action: nil)
    private var sidebarView: NSView!
    private let historyPopup = NSPopUpButton()
    private let savedPopup = NSPopUpButton()
    private let advancedToggle = NSButton(title: "更多筛选", target: nil, action: nil)
    private let categoryControl = NSSegmentedControl(labels: SearchFilterCategory.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
    private let filterChips = NSStackView()
    private let filterChipScroll = NSScrollView()
    private var filterChipRow: NSStackView!
    private var filterPanel: SearchFilterPanelController?
    private var favoritesPanel: SearchFavoritesPanelController?
    private var displayedSavedIDs: [UUID] = []
    private var filterChipSignature = ""
    private var workspace: WorkspaceController!
    private let selectionLabel = NSTextField(labelWithString: "")
    private let resultMetadata = ResultMetadataCache()
    private let preferences = SearchWorkspacePreferences()
    private var resultSortColumn = ""
    private var resultSortAscending = true
    private let kindControl = NSSegmentedControl(labels: SearchKind.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
    private let matchPathButton = NSButton(checkboxWithTitle: "同时匹配路径", target: nil, action: nil)
    private let rootsTable = NSTableView()
    private let resultsTable = ResultTableView()
    private let resultLabel = NSTextField(labelWithString: "正在载入索引…")
    private let scopeLabel = NSTextField(labelWithString: "全部索引位置")
    private let searchDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let loadMoreButton = NSButton(title: "显示更多", target: nil, action: nil)
    private let inspectAllButton = NSButton(title: "检查全部候选", target: nil, action: nil)
    private let cancelMetadataButton = NSButton(title: "停止属性筛选", target: nil, action: nil)
    private let footerLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let scanIndicator = NSProgressIndicator()
    private let cancelButton = NSButton(title: "停止扫描", target: nil, action: nil)
    private let removeButton = NSButton(title: "移除索引", target: nil, action: nil)
    private let issuesButton = NSButton(title: "查看扫描问题", target: nil, action: nil)
    private let previewPath = NSTextField(labelWithString: "选择结果后：回车打开 · ⌘回车定位 · 空格预览 · ⌘⇧C 复制路径")
    private var displayedResults: [FileHit] = []
    private var displayedQuerySignature: String?
    private var displayedRoots: [RootStatus] = []
    private var displayedSortKey = ""
    private var displayedResultsAreCurrent = false
    private var displayedSearchRevision: UInt64?
    private var issuesController: NSWindowController?
    private var hotKeyUnavailable = false
    private var updating = false

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "疾览 · Jilan"
        window.minSize = NSSize(width: 1100, height: 700)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        makeInterface()
        resultMetadata.onChange = { [weak self] in self?.refreshResultMetadata() }
        model.onChange = { [weak self] in self?.update() }
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        saveWorkspace()
        sender.orderOut(nil)
        return false
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }
    @objc func focusSearchAction(_ sender: Any?) { showSearch(); focusSearch() }
    func showSearch() { workspace.showSearchResults() }
    @objc func showWorkspaceAction(_ sender: Any?) { workspace.showDirectoryWorkspace() }
    @objc private func toggleSidebar(_ sender: Any?) {
        sidebarView.isHidden = sidebarToggle.state != .on
    }
    func saveWorkspace() { workspace?.saveSession(); preferences.save() }
    @objc func newWorkspaceTab(_ sender: Any?) { workspace.newWorkspaceTab() }
    @objc func closeWorkspaceTab(_ sender: Any?) { workspace.closeCurrentTab() }
    func showHotKeyUnavailable() { hotKeyUnavailable = true; update() }

    private func makeInterface() {
        guard let content = window?.contentView else { return }
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.topAnchor.constraint(equalTo: content.topAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let title = NSTextField(labelWithString: "疾览 · Jilan")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "全盘即时搜索 · 双栏文件管理")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        let titleBlock = NSStackView(views: [title, subtitle])
        titleBlock.orientation = .vertical
        titleBlock.alignment = .leading
        titleBlock.spacing = 4
        let shortcut = NSTextField(labelWithString: "⌃⌥空格 呼出")
        shortcut.textColor = .secondaryLabelColor
        shortcut.font = .systemFont(ofSize: 12)
        let searchShortcut = NSButton(title: "全盘搜索", target: self, action: #selector(focusSearchAction(_:)))
        searchShortcut.bezelStyle = .rounded
        sidebarToggle.target = self; sidebarToggle.action = #selector(toggleSidebar(_:))
        let header = NSStackView(views: [titleBlock, NSView(), searchShortcut, sidebarToggle, shortcut])
        header.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        header.alignment = .centerY
        container.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        container.addArrangedSubview(separator())

        workspace = WorkspaceController()
        workspace.onOperationStateChanged = { [weak self] in self?.onOperationStateChanged?() }
        workspace.onFilesChanged = { [weak self] paths in
            self?.resultMetadata.invalidate()
            self?.model.fileOperationDidChange(paths: paths)
        }
        workspace.onMessage = { [weak self] message in self?.footerLabel.stringValue = message }
        workspace.onSearchFocusRequested = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.resultsTable)
        }
        let controls = makeSearchControls()
        container.addArrangedSubview(controls)
        controls.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        workspace.installSearchView(makeSearchArea(), selectionProvider: { [weak self] in self?.selectedHits() ?? [] })
        sidebarView = makeSidebar(); sidebarView.isHidden = true
        let centerHost = NSStackView(views: [sidebarView, workspace.view])
        centerHost.orientation = .horizontal; centerHost.alignment = .top; centerHost.spacing = 0
        centerHost.detachesHiddenViews = true
        container.addArrangedSubview(centerHost)
        centerHost.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        centerHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        sidebarView.heightAnchor.constraint(equalTo: centerHost.heightAnchor).isActive = true
        workspace.view.heightAnchor.constraint(equalTo: centerHost.heightAnchor).isActive = true
        workspace.view.trailingAnchor.constraint(equalTo: centerHost.trailingAnchor).isActive = true
        container.addArrangedSubview(separator())

        scanIndicator.style = .spinning
        scanIndicator.controlSize = .small
        scanIndicator.isDisplayedWhenStopped = false
        scanIndicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancelButton.controlSize = .small
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelScan(_:))
        issuesButton.controlSize = .small
        issuesButton.bezelStyle = .rounded
        issuesButton.target = self
        issuesButton.action = #selector(showIssues(_:))
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let authorLabel = NSTextField(labelWithString: "by 塔贰舅")
        authorLabel.font = .systemFont(ofSize: 11)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.alignment = .right
        authorLabel.toolTip = "作者：塔贰舅"
        authorLabel.setAccessibilityIdentifier("jilan.authorCredit")
        authorLabel.setContentHuggingPriority(.required, for: .horizontal)
        authorLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = NSStackView(views: [scanIndicator, footerLabel, cancelButton, issuesButton, footerSpacer, authorLabel])
        footer.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        footer.spacing = 10
        footer.alignment = .centerY
        container.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        content.layoutSubtreeIfNeeded()
        workspace.prepareInitialLayout()
    }

    private func makeSidebar() -> NSView {
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 10
        sidebar.edgeInsets = NSEdgeInsets(top: 15, left: 10, bottom: 12, right: 10)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 205).isActive = true
        sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 205).isActive = true
        let heading = NSTextField(labelWithString: "索引位置")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        sidebar.addArrangedSubview(heading)

        rootsTable.headerView = nil
        rootsTable.rowHeight = 58
        rootsTable.intercellSpacing = NSSize(width: 0, height: 2)
        rootsTable.selectionHighlightStyle = .regular
        rootsTable.style = .sourceList
        rootsTable.dataSource = self
        rootsTable.delegate = self
        rootsTable.allowsEmptySelection = false
        rootsTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("root")))
        let scroll = NSScrollView()
        scroll.documentView = rootsTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        sidebar.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -20).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let add = NSButton(title: "添加文件夹…", target: self, action: #selector(addFolder(_:)))
        add.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        add.bezelStyle = .rounded
        let full = NSButton(title: "索引全部磁盘", target: self, action: #selector(addWholeDisks(_:)))
        full.bezelStyle = .rounded
        let refresh = NSButton(title: "重新扫描", target: self, action: #selector(refreshAll(_:)))
        refresh.bezelStyle = .rounded
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeRoot(_:))
        for button in [add, full, refresh, removeButton] {
            sidebar.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -20).isActive = true
        }
        let hint = NSTextField(wrappingLabelWithString: "移除仅清理索引，不删除文件。\n关闭窗口后，菜单栏继续运行。")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        sidebar.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -20).isActive = true
        return sidebar
    }

    private func makeSearchControls() -> NSView {
        let area = NSStackView()
        area.orientation = .vertical
        area.alignment = .leading
        area.spacing = 8
        area.edgeInsets = NSEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)

        searchField.placeholderString = "输入即搜索，如 合同 *.pdf !草稿"
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 16)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchInputChanged(_:))
        searchField.heightAnchor.constraint(equalToConstant: 38).isActive = true
        area.addArrangedSubview(searchField)
        searchField.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -36).isActive = true

        kindControl.selectedSegment = 0
        kindControl.target = self
        kindControl.action = #selector(filtersChanged(_:))
        kindControl.segmentStyle = .rounded
        matchPathButton.target = self
        matchPathButton.action = #selector(filtersChanged(_:))
        matchPathButton.font = .systemFont(ofSize: 12)
        extensionField.placeholderString = "扩展名，如 pdf"
        extensionField.delegate = self
        extensionField.widthAnchor.constraint(equalToConstant: 145).isActive = true
        advancedToggle.bezelStyle = .rounded
        advancedToggle.target = self
        advancedToggle.action = #selector(toggleAdvanced(_:))
        categoryControl.selectedSegment = 0; categoryControl.target = self; categoryControl.action = #selector(categoryChanged(_:)); categoryControl.segmentStyle = .rounded
        let filters = NSStackView(views: [kindControl, FilterUI.label("常用类型"), categoryControl, NSView(), advancedToggle])
        filters.alignment = .centerY
        filters.spacing = 12
        area.addArrangedSubview(filters)
        filters.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -36).isActive = true

        filterChips.orientation = .horizontal; filterChips.spacing = 5
        filterChipScroll.documentView = filterChips; filterChipScroll.hasHorizontalScroller = true; filterChipScroll.hasVerticalScroller = false; filterChipScroll.autohidesScrollers = true; filterChipScroll.drawsBackground = false
        filterChipScroll.horizontalScroller?.controlSize = .mini
        filterChipScroll.heightAnchor.constraint(equalToConstant: 32).isActive = true
        filterChipScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        let clear = NSButton(title: "清空筛选", target: self, action: #selector(clearFilters(_:))); clear.bezelStyle = .rounded; clear.controlSize = .small
        filterChipRow = FilterUI.row([FilterUI.label("当前筛选"), filterChipScroll, clear])
        area.addArrangedSubview(filterChipRow); filterChipRow.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -36).isActive = true
        filterChipRow.isHidden = true
        historyPopup.target = self; historyPopup.action = #selector(restoreHistory(_:))
        savedPopup.target = self; savedPopup.action = #selector(restoreSaved(_:))
        historyPopup.widthAnchor.constraint(equalToConstant: 125).isActive = true
        savedPopup.widthAnchor.constraint(equalToConstant: 125).isActive = true
        let saveSearch = NSButton(title: "收藏当前搜索", target: self, action: #selector(saveCurrentSearch(_:)))
        saveSearch.bezelStyle = .rounded
        let manageSaved = NSButton(title: "管理收藏", target: self, action: #selector(manageSavedSearches(_:))); manageSaved.bezelStyle = .rounded
        let currentScope = NSButton(title: "当前目录及子目录", target: self, action: #selector(scopeToWorkspaceDirectory(_:))); currentScope.bezelStyle = .rounded
        let syntax = NSButton(title: "搜索语法", target: self, action: #selector(showSearchHelp(_:)))
        syntax.bezelStyle = .rounded
        let actions = NSStackView(views: [extensionField, matchPathButton, historyPopup, savedPopup, saveSearch, manageSaved, NSView(), currentScope, syntax])
        actions.spacing = 8
        area.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -36).isActive = true
        rebuildSavedMenus()

        return area
    }

    private func makeSearchArea() -> NSView {
        let area = NSStackView()
        area.orientation = .vertical; area.alignment = .leading; area.spacing = 6
        area.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        resultLabel.font = .systemFont(ofSize: 12, weight: .medium)
        resultLabel.textColor = .secondaryLabelColor
        scopeLabel.font = .systemFont(ofSize: 11)
        scopeLabel.textColor = .tertiaryLabelColor
        scopeLabel.lineBreakMode = .byTruncatingMiddle
        loadMoreButton.controlSize = .small
        loadMoreButton.bezelStyle = .rounded
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMoreResults(_:))
        loadMoreButton.toolTip = "加载下一批搜索结果"
        resultLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        scopeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inspectAllButton.bezelStyle = .rounded; inspectAllButton.controlSize = .small
        inspectAllButton.target = self; inspectAllButton.action = #selector(inspectAllCandidates(_:))
        inspectAllButton.toolTip = "在后台检查当前名称候选的大小和日期；输入新条件即可取消。"
        cancelMetadataButton.bezelStyle = .rounded; cancelMetadataButton.controlSize = .small
        cancelMetadataButton.target = self; cancelMetadataButton.action = #selector(stopMetadataInspection(_:))
        resultLabel.lineBreakMode = .byTruncatingTail
        area.addArrangedSubview(resultLabel)
        resultLabel.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -12).isActive = true
        let summary = NSStackView(views: [scopeLabel, NSView(), cancelMetadataButton, inspectAllButton, loadMoreButton])
        summary.alignment = .centerY
        area.addArrangedSubview(summary)
        summary.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -12).isActive = true
        searchDetailLabel.font = .systemFont(ofSize: 11); searchDetailLabel.textColor = .secondaryLabelColor
        searchDetailLabel.maximumNumberOfLines = 3
        area.addArrangedSubview(searchDetailLabel)
        searchDetailLabel.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -12).isActive = true

        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.rowHeight = 28
        resultsTable.usesAlternatingRowBackgroundColors = true
        resultsTable.allowsMultipleSelection = true
        resultsTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        resultsTable.target = self
        resultsTable.doubleAction = #selector(openSelection(_:))
        resultsTable.onFocus = { [weak self] in self?.workspace.searchSelectionDidChange(activate: true) }
        resultsTable.onCopyFiles = { [weak self] in self?.performResultAction(.copyClipboard) }
        resultsTable.onCutFiles = { [weak self] in self?.performResultAction(.cutClipboard) }
        resultsTable.onPasteFiles = { [weak self] in self?.performResultAction(.pasteClipboard) }
        resultsTable.onDeleteFiles = { [weak self] in self?.performResultAction(.trash) }
        resultsTable.onRenameFile = { [weak self] in self?.performResultAction(.rename) }
        resultsTable.onOpen = { [weak self] in self?.openSelection(nil) }
        resultsTable.onReveal = { [weak self] in self?.revealSelection(nil) }
        resultsTable.onPreview = { [weak self] in self?.previewSelection(nil) }
        resultsTable.onCopyPath = { [weak self] in self?.copySelection(nil) }
        for (id, title, width) in [("name", "名称", 220.0), ("path", "所在位置", 320.0), ("kind", "类型", 70.0), ("size", "大小", 88.0), ("modified", "修改时间", 140.0), ("online", "磁盘状态", 82.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "path" ? 140 : 60
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            resultsTable.addTableColumn(column)
        }
        let context = NSMenu()
        for (title, selector) in [("打开", #selector(openSelection(_:))), ("在 Finder 中显示", #selector(revealSelection(_:))), ("复制完整路径", #selector(copySelection(_:))), ("快速预览", #selector(previewSelection(_:))), ("在应用内浏览所在目录", #selector(browseSelection(_:)))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            context.addItem(item)
        }
        for (title, selector) in [("复制", #selector(copyResultFiles(_:))), ("剪切", #selector(cutResultFiles(_:))), ("复制到另一栏", #selector(copyResultToOther(_:))), ("移动到另一栏", #selector(moveResultToOther(_:))), ("改名…", #selector(renameResult(_:))), ("批量改名…", #selector(batchRenameResult(_:))), ("移至废纸篓…", #selector(trashResult(_:)))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; context.addItem(item)
        }
        resultsTable.menu = context
        resultsTable.setAccessibilityLabel("全盘搜索结果")
        let scroll = NSScrollView()
        scroll.documentView = resultsTable
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(resultScrollChanged(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let resultsContainer = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        resultsContainer.addSubview(scroll)
        resultsContainer.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: resultsContainer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: resultsContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: resultsContainer.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: resultsContainer.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: resultsContainer.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: resultsContainer.widthAnchor, constant: -60)
        ])
        area.addArrangedSubview(resultsContainer)
        resultsContainer.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -12).isActive = true
        resultsContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        previewPath.font = .systemFont(ofSize: 11)
        previewPath.textColor = .secondaryLabelColor
        previewPath.lineBreakMode = .byTruncatingMiddle
        area.addArrangedSubview(previewPath)
        previewPath.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -12).isActive = true
        return area
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    private func update() {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        let selectedPaths = displayedQuerySignature == model.searchSignature ? Set(resultsTable.selectedRowIndexes.compactMap { displayedResults.indices.contains($0) ? displayedResults[$0].path : nil }) : []
        let indexChanged = displayedSearchRevision != model.latestSearchRevision
        displayedSearchRevision = model.latestSearchRevision
        if indexChanged { resultMetadata.invalidate() }
        if displayedRoots != model.roots {
            displayedRoots = model.roots
            rootsTable.reloadData()
        }
        let scopeRow = model.scopeID.flatMap { id in model.roots.firstIndex(where: { $0.id == id }).map { $0 + 1 } } ?? 0
        rootsTable.selectRowIndexes(IndexSet(integer: scopeRow), byExtendingSelection: false)
        removeButton.isEnabled = scopeRow > 0
        // Input controls are the source of text. Background snapshots never
        // write text back, including between field-editor action notifications.
        kindControl.selectedSegment = SearchKind.allCases.firstIndex(of: model.kind) ?? 0
        categoryControl.selectedSegment = SearchFilterCategory.allCases.firstIndex(of: model.filters.category) ?? 0
        matchPathButton.state = model.matchPath ? .on : .off
        rebuildFilterChips()
        let sortKey = resultSortColumn + String(resultSortAscending)
        let nextResults = sortedResults(model.results)
        let resultsChanged = displayedQuerySignature != model.searchSignature
            || displayedResults != nextResults || displayedSortKey != sortKey
        let availabilityChanged = displayedResultsAreCurrent != model.resultsAreCurrent
        displayedQuerySignature = model.searchSignature
        displayedResultsAreCurrent = model.resultsAreCurrent
        displayedSortKey = sortKey
        if resultsChanged {
            displayedResults = nextResults
            resultsTable.reloadData()
            let selectedIndexes = IndexSet(displayedResults.indices.filter { selectedPaths.contains(displayedResults[$0].path) })
            resultsTable.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
            loadVisibleMetadata()
        }
        if indexChanged {
            if resultSortColumn == "size" || resultSortColumn == "modified" { resultMetadata.load(paths: displayedResults.filter(\.isOnline).map(\.path)) }
            else { loadVisibleMetadata() }
            workspace?.refreshSelectedPreview()
        }
        let count = NumberFormatter.localizedString(from: NSNumber(value: model.totalMatches), number: .decimal)
        let shown = model.results.count
        resultLabel.stringValue = model.isSearchPending ? "正在搜索…" : "已显示 \(formatted(shown)) / 总计 \(count) 项 · 搜索 \(String(format: "%.1f", model.queryMilliseconds)) 毫秒"
        searchDetailLabel.stringValue = model.searchStatusDetail
        searchDetailLabel.isHidden = model.searchStatusDetail.isEmpty
        searchDetailLabel.toolTip = model.searchStatusDetail
        if model.hasMetadataFilter && !model.isSearchPending {
            resultLabel.stringValue = "已显示 \(formatted(shown)) / 已确认 \(count) 项 · 筛选 \(String(format: "%.1f", model.queryMilliseconds)) 毫秒"
        }
        if model.isBrowsingAllIndexedItems && !model.isSearchPending {
            resultLabel.stringValue = "已显示 \(formatted(shown)) / 总计 \(count) 项 · 浏览全部已索引项目"
        }
        if !resultSortColumn.isEmpty { resultLabel.stringValue += " · 排序适用于已加载结果" }
        loadMoreButton.isEnabled = model.canLoadMoreResults
        loadMoreButton.isHidden = !model.canLoadMoreResults
        inspectAllButton.isHidden = !model.hasMetadataFilter
        inspectAllButton.isEnabled = model.canInspectAllMetadataCandidates
        cancelMetadataButton.isHidden = !model.isInspectingMetadata
        scopeLabel.stringValue = model.scopeID.flatMap { id in model.roots.first(where: { $0.id == id })?.name } ?? "全部索引位置"
        emptyLabel.isHidden = !model.results.isEmpty
        if model.isSearchPending {
            emptyLabel.stringValue = "正在搜索…"
        } else if model.roots.isEmpty {
            emptyLabel.stringValue = "添加文件夹或索引全部磁盘\n首次扫描完成后，即可快速检索文件和文件夹。"
        } else if model.isScanning && model.results.isEmpty {
            emptyLabel.stringValue = "正在建立索引…\n扫描期间也可以搜索已收录的文件。"
        } else if model.query.isEmpty && model.results.isEmpty {
            emptyLabel.stringValue = "这个位置暂时没有已收录的文件\n可重新扫描，并查看扫描问题。"
        } else {
            emptyLabel.stringValue = "没有找到匹配项\n试试更短的关键词，或调整类型、扩展名和索引位置。"
        }
        if model.isScanning { scanIndicator.startAnimation(nil) } else { scanIndicator.stopAnimation(nil) }
        cancelButton.isHidden = !model.isScanning
        let scanned = NumberFormatter.localizedString(from: NSNumber(value: model.scannedCount), number: .decimal)
        footerLabel.stringValue = model.isScanning ? "\(model.message) · 已发现 \(scanned) 项" : model.message
        if hotKeyUnavailable { footerLabel.stringValue += " · 呼出快捷键被占用，可使用菜单栏打开" }
        footerLabel.toolTip = footerLabel.stringValue
        issuesButton.isHidden = model.issues.isEmpty
        issuesButton.title = "查看未覆盖路径（\(model.issues.count)）"
        if resultsChanged || availabilityChanged { updateSelectionDescription() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === rootsTable ? model.roots.count + 1 : displayedResults.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === rootsTable {
            let identifier = NSUserInterfaceItemIdentifier("RootCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? RootCellView) ?? RootCellView()
            cell.identifier = identifier
            if row == 0 {
                let total = model.roots.reduce(0) { $0 + $1.count }
                cell.set(title: "全部索引位置", subtitle: "\(model.roots.count) 个位置 · \(formatted(total)) 项", symbol: "tray.full.fill", offline: false)
            } else if model.roots.indices.contains(row - 1) {
                let root = model.roots[row - 1]
                cell.set(title: root.name, subtitle: "\(root.state) · \(formatted(root.count)) 项" + (root.issueCount > 0 ? " · \(root.issueCount) 个问题" : ""), symbol: root.isOnline ? "externaldrive.fill" : "externaldrive.badge.xmark", offline: !root.isOnline)
                cell.toolTip = root.path + "\n" + root.state
            }
            return cell
        }
        guard displayedResults.indices.contains(row), let tableColumn else { return nil }
        let hit = displayedResults[row]
        let id = tableColumn.identifier.rawValue
        let identifier = NSUserInterfaceItemIdentifier("Result_" + id)
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ResultCellView) ?? ResultCellView(hasIcon: id == "name")
        cell.identifier = identifier
        switch id {
        case "name": cell.set(hit.name, icon: NSImage(systemSymbolName: hit.isDirectory ? "folder.fill" : "doc", accessibilityDescription: nil), online: hit.isOnline)
        case "path": cell.set(hit.parentPath, icon: nil, online: hit.isOnline)
        case "size": cell.set(metadata(hit).size.map { hit.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? (hit.isDirectory ? "—" : "…"), icon: nil, online: hit.isOnline)
        case "modified": cell.set(metadata(hit).modified.map { ResultMetadataCache.dateFormatter.string(from: $0) } ?? "…", icon: nil, online: hit.isOnline)
        case "kind": cell.set(hit.isDirectory ? "文件夹" : ((hit.name as NSString).pathExtension.isEmpty ? "文件" : (hit.name as NSString).pathExtension.uppercased()), icon: nil, online: hit.isOnline)
        default: cell.set(hit.isOnline ? "已连接" : "离线", icon: nil, online: hit.isOnline)
        }
        cell.toolTip = hit.path
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === rootsTable {
            guard !updating else { return }
            let row = rootsTable.selectedRow
            model.scopeID = row > 0 && model.roots.indices.contains(row - 1) ? model.roots[row - 1].id : nil
            showSearch(); model.search()
        } else {
            guard !updating else { return }
            updateSelectionDescription()
        }
    }

    private func currentInput(_ field: NSTextField) -> String {
        (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
    }
    private func synchronizeSearchInput(immediate: Bool = false) {
        if let editor = searchField.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        if let editor = extensionField.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        if let editor = sizeField.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        if let editor = modifiedField.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        let previous = model.searchSignature
        model.query = currentInput(searchField)
        model.extensionFilter = currentInput(extensionField)
        model.sizeFilter = currentInput(sizeField)
        model.modifiedFilter = currentInput(modifiedField)
        if previous != model.searchSignature { showSearch() }
        if !model.resultsAreCurrent { model.search(immediate: immediate) }
    }
    @objc private func searchInputChanged(_ sender: Any?) {
        synchronizeSearchInput()
    }
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, [searchField, extensionField, sizeField, modifiedField].contains(where: { $0 === field }) else { return }
        synchronizeSearchInput()
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, [searchField, extensionField, sizeField, modifiedField].contains(where: { $0 === field }) else { return }
        synchronizeSearchInput()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        // Return confirms an IME candidate before it can open a search result.
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            showSearch(); synchronizeSearchInput(immediate: true)
            guard model.resultsAreCurrent, !displayedResults.isEmpty else { return true }
            if resultsTable.selectedRow < 0 { resultsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            window?.makeFirstResponder(resultsTable)
            resultsTable.scrollRowToVisible(max(0, resultsTable.selectedRow))
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Only open results belonging to the current, committed query.
            // A pending query must never launch a previously selected item.
            showSearch(); synchronizeSearchInput(immediate: true)
            guard model.resultsAreCurrent, !displayedResults.isEmpty else { return true }
            if resultsTable.selectedRow < 0 { resultsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            openSelection(nil)
            return true
        }
        return false
    }
    @objc private func filtersChanged(_ sender: Any?) {
        showSearch()
        model.kind = SearchKind.allCases[max(0, kindControl.selectedSegment)]
        model.matchPath = matchPathButton.state == .on
        synchronizeSearchInput(immediate: true)
    }
    @objc private func categoryChanged(_ sender: Any?) {
        let index = max(0, categoryControl.selectedSegment)
        guard SearchFilterCategory.allCases.indices.contains(index) else { return }
        changeFilters { $0.category = SearchFilterCategory.allCases[index] }
    }
    @objc private func scopeToWorkspaceDirectory(_ sender: Any?) {
        let path = workspace.activeDirectoryPath
        changeFilters { $0.includedPaths = [path]; $0.includeSubfolders = true }
    }
    private func changeFilters(_ change: (inout SearchFilters) -> Void) {
        synchronizeSearchInput()
        var filters = model.filters; change(&filters); model.filters = filters
        showSearch(); rebuildFilterChips(); model.search(immediate: true)
    }
    private func changeLegacyFilter(_ change: () -> Void) {
        synchronizeSearchInput(); change(); showSearch(); rebuildFilterChips(); model.search(immediate: true)
    }
    @objc private func clearFilters(_ sender: Any?) {
        changeLegacyFilter {
            model.filters = SearchFilters(); model.kind = .all; model.matchPath = false; model.scopeID = nil
            model.extensionFilter = ""; model.sizeFilter = ""; model.modifiedFilter = ""
            extensionField.stringValue = ""; sizeField.stringValue = ""; modifiedField.stringValue = ""
        }
    }
    private func rebuildFilterChips() {
        guard filterChipRow != nil else { return }
        let signature = [model.filters.signature, model.kind.rawValue, model.extensionFilter, model.sizeFilter, model.modifiedFilter, String(model.matchPath), model.scopeID ?? ""].joined(separator: "\u{0000}")
        guard signature != filterChipSignature else { return }; filterChipSignature = signature
        filterChips.arrangedSubviews.forEach { filterChips.removeArrangedSubview($0); $0.removeFromSuperview() }
        func chip(_ title: String, remove: @escaping () -> Void) {
            let button = FilterActionButton(title + " ×", action: remove); button.toolTip = title + "\n点击移除这个筛选条件"
            button.font = .systemFont(ofSize: 11); button.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); filterChips.addArrangedSubview(button)
        }
        if model.kind != .all { chip(model.kind.rawValue) { [weak self] in self?.changeLegacyFilter { self?.model.kind = .all } } }
        if !model.extensionFilter.isEmpty { chip("扩展名：" + model.extensionFilter) { [weak self] in self?.changeLegacyFilter { self?.model.extensionFilter = ""; self?.extensionField.stringValue = "" } } }
        if !model.sizeFilter.isEmpty { chip("大小：" + model.sizeFilter) { [weak self] in self?.changeLegacyFilter { self?.model.sizeFilter = ""; self?.sizeField.stringValue = "" } } }
        if !model.modifiedFilter.isEmpty { chip("修改：" + FilterUI.dateExpressionTitle(model.modifiedFilter)) { [weak self] in self?.changeLegacyFilter { self?.model.modifiedFilter = ""; self?.modifiedField.stringValue = "" } } }
        if model.matchPath { chip("关键词匹配路径") { [weak self] in self?.changeLegacyFilter { self?.model.matchPath = false } } }
        if let id = model.scopeID { chip("索引：" + (model.roots.first { $0.id == id }?.name ?? "所选位置")) { [weak self] in self?.changeLegacyFilter { self?.model.scopeID = nil } } }
        let filters = model.filters
        if filters.category != .all { chip("类型：" + filters.category.rawValue) { [weak self] in self?.changeFilters { $0.category = .all } } }
        if !filters.nameValue.isEmpty { chip("名称" + filters.nameMode.rawValue + "：" + filters.nameValue) { [weak self] in self?.changeFilters { $0.nameValue = "" } } }
        for path in filters.includedPaths { chip("包含：" + path) { [weak self] in self?.changeFilters { $0.includedPaths.removeAll { $0 == path } } } }
        for path in filters.excludedPaths { chip("排除：" + path) { [weak self] in self?.changeFilters { $0.excludedPaths.removeAll { $0 == path } } } }
        if !filters.includedPaths.isEmpty && !filters.includeSubfolders { chip("不含子目录") { [weak self] in self?.changeFilters { $0.includeSubfolders = true } } }
        if filters.hidden != .all { chip("隐藏：" + filters.hidden.rawValue) { [weak self] in self?.changeFilters { $0.hidden = .all } } }
        if filters.connection != .all { chip("磁盘：" + filters.connection.rawValue) { [weak self] in self?.changeFilters { $0.connection = .all } } }
        if !filters.createdFilter.isEmpty { chip("创建：" + FilterUI.dateExpressionTitle(filters.createdFilter)) { [weak self] in self?.changeFilters { $0.createdFilter = "" } } }
        if !filters.conditionGroup.isEmpty {
            func count(_ group: SearchConditionGroup) -> Int { group.rules.filter { !$0.isEmpty }.count + group.groups.reduce(0) { $0 + count($1) } }
            chip("组合：\(filters.conditionGroup.mode.rawValue) · \(count(filters.conditionGroup)) 条") { [weak self] in self?.changeFilters { $0.conditionGroup = SearchConditionGroup() } }
        }
        filterChipRow.isHidden = filterChips.arrangedSubviews.isEmpty
        filterChips.layoutSubtreeIfNeeded(); filterChips.frame.size = filterChips.fittingSize
    }
    @objc private func loadMoreResults(_ sender: Any?) { model.loadMoreResults() }
    @objc private func inspectAllCandidates(_ sender: Any?) { model.inspectAllMetadataCandidates() }
    @objc private func stopMetadataInspection(_ sender: Any?) { model.cancelMetadataInspection() }
    @objc private func addFolder(_ sender: Any?) { model.addFolder() }
    @objc private func addWholeDisks(_ sender: Any?) { model.addWholeDisks() }
    @objc private func refreshAll(_ sender: Any?) { model.refreshAll() }
    @objc private func cancelScan(_ sender: Any?) { model.cancelScan() }
    @objc private func removeRoot(_ sender: Any?) {
        let row = rootsTable.selectedRow
        guard row > 0, model.roots.indices.contains(row - 1) else { return }
        model.removeRoot(id: model.roots[row - 1].id)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let actions: [Selector] = [#selector(openSelection(_:)), #selector(revealSelection(_:)), #selector(copySelection(_:)), #selector(previewSelection(_:)), #selector(browseSelection(_:))]
        if !workspace.isSearchSelectionActive {
            if menuItem.action == #selector(browseSelection(_:)) { return false }
            return !actions.contains(where: { $0 == menuItem.action }) || workspace.hasSelection
        }
        return !actions.contains(where: { $0 == menuItem.action }) || selectedHit() != nil
    }
    @objc func openSelection(_ sender: Any?) {
        if !workspace.isSearchSelectionActive { workspace.openCurrentSelection(); return }
        guard let hit = selectedHit() else { return }
        rememberCurrentSearch()
        if hit.isDirectory && hit.isOnline {
            workspace.browseSearchDirectory(hit.path)
        } else { model.open(hit) }
    }
    @objc func browseSelection(_ sender: Any?) {
        guard let hit = selectedHit(), hit.isOnline else { return }
        rememberCurrentSearch()
        workspace.browseSearchDirectory(hit.parentPath, selecting: [hit.path])
    }
    private func performResultAction(_ action: WorkspacePaneAction) {
        workspace.searchSelectionDidChange(activate: true)
        if !selectedHits().isEmpty { rememberCurrentSearch() }
        workspace.performCurrentAction(action)
    }
    @objc private func copyResultFiles(_ sender: Any?) { performResultAction(.copyClipboard) }
    @objc private func cutResultFiles(_ sender: Any?) { performResultAction(.cutClipboard) }
    @objc private func copyResultToOther(_ sender: Any?) { performResultAction(.copy) }
    @objc private func moveResultToOther(_ sender: Any?) { performResultAction(.move) }
    @objc private func renameResult(_ sender: Any?) { performResultAction(.rename) }
    @objc private func batchRenameResult(_ sender: Any?) { performResultAction(.batchRename) }
    @objc private func trashResult(_ sender: Any?) { performResultAction(.trash) }
    @objc func revealSelection(_ sender: Any?) {
        if !workspace.isSearchSelectionActive { workspace.revealCurrentSelection(); return }
        if let hit = selectedHit() { model.reveal(hit) }
    }
    @objc func copySelection(_ sender: Any?) {
        if !workspace.isSearchSelectionActive { workspace.copyCurrentPaths(); return }
        let paths = selectedHits().map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        footerLabel.stringValue = "已复制 \(paths.count) 个完整路径"
    }
    private func selectedHits() -> [FileHit] {
        guard model.resultsAreCurrent else { return [] }
        return resultsTable.selectedRowIndexes.compactMap { displayedResults.indices.contains($0) ? displayedResults[$0] : nil }
    }
    private func selectedHit() -> FileHit? {
        guard model.resultsAreCurrent else { return nil }
        let row = resultsTable.selectedRow
        return displayedResults.indices.contains(row) ? displayedResults[row] : nil
    }
    private func updateSelectionDescription() {
        let hits = selectedHits()
        previewPath.stringValue = hits.count > 1 ? "已选择 \(hits.count) 项 · 可直接复制、移动或批量整理到另一栏" : (hits.first?.path ?? "回车打开 · ⌘回车定位 · 空格预览 · ⌘⇧C 复制路径")
        previewPath.toolTip = previewPath.stringValue
        workspace?.searchSelectionDidChange(activate: false)
    }
    private func formatted(_ value: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal) }

    @objc private func showSearchHelp(_ sender: Any?) {
        let alert = NSAlert(); alert.messageText = "组合搜索条件"
        alert.informativeText = "合同 2026：两个关键词都匹配\n合同 | 协议：匹配任意一组\n合同 !草稿：排除包含“草稿”的名称\n*.pdf：按通配符匹配\next:pdf;docx：限定扩展名\nfile: / folder:：限定文件或文件夹\nsize:>100mb：文件大于 100 MB\ndm:7days：最近七天修改\ndm:2026-01-01..2026-12-31：日期范围\n\n“更多筛选”提供名称、大小、日期日历、目录范围、隐藏状态和可嵌套的条件组，无需记语法。属性筛选会显示已检查范围；点击“检查全部候选”获取完整候选统计。文件夹大小不递归计算。"
        alert.addButton(withTitle: "知道了")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    @objc private func toggleAdvanced(_ sender: Any?) {
        guard filterPanel == nil, let window else { return }
        synchronizeSearchInput()
        let values = SearchFilterPanelValues(filters: model.filters, kind: model.kind, extensionFilter: model.extensionFilter, matchPath: model.matchPath, sizeFilter: model.sizeFilter, modifiedFilter: model.modifiedFilter)
        let panel = SearchFilterPanelController(values: values, currentDirectory: workspace.activeDirectoryPath)
        filterPanel = panel
        panel.presentSheet(for: window) { [weak self] values in
            guard let self else { return }; self.filterPanel = nil
            guard let values else { return }
            self.model.filters = values.filters; self.model.kind = values.kind; self.model.matchPath = values.matchPath
            self.model.extensionFilter = values.extensionFilter; self.model.sizeFilter = values.sizeFilter; self.model.modifiedFilter = values.modifiedFilter
            self.extensionField.stringValue = values.extensionFilter; self.sizeField.stringValue = values.sizeFilter; self.modifiedField.stringValue = values.modifiedFilter
            self.showSearch(); self.rebuildFilterChips(); self.model.search(immediate: true)
        }
    }
    private func currentSavedSearch() -> SavedSearch {
        SavedSearch(query: model.query, kind: model.kind.rawValue, extensionFilter: model.extensionFilter,
            matchPath: model.matchPath, rootID: model.scopeID, sizeFilter: model.sizeFilter, modifiedFilter: model.modifiedFilter, filters: model.filters)
    }
    private func rememberCurrentSearch() {
        preferences.remember(currentSavedSearch()); rebuildSavedMenus()
    }
    private func rebuildSavedMenus() {
        historyPopup.removeAllItems(); historyPopup.addItem(withTitle: "最近搜索")
        for item in preferences.history { historyPopup.addItem(withTitle: String(item.title.prefix(70))); historyPopup.lastItem?.toolTip = item.title }
        savedPopup.removeAllItems(); savedPopup.addItem(withTitle: "收藏搜索")
        let sorted = preferences.saved.enumerated().sorted { a, b in a.element.isPinned == b.element.isPinned ? a.offset < b.offset : a.element.isPinned }.map(\.element)
        displayedSavedIDs = sorted.map(\.id)
        for item in sorted { savedPopup.addItem(withTitle: (item.isPinned ? "★ " : "") + String(item.title.prefix(70))); savedPopup.lastItem?.toolTip = item.title }
        savedPopup.addItem(withTitle: "管理收藏搜索…")
    }
    private func applySavedSearch(_ item: SavedSearch) {
        showSearch()
        searchField.stringValue = item.query; extensionField.stringValue = item.extensionFilter
        sizeField.stringValue = item.sizeFilter; modifiedField.stringValue = item.modifiedFilter
        model.query = item.query; model.extensionFilter = item.extensionFilter
        model.sizeFilter = item.sizeFilter; model.modifiedFilter = item.modifiedFilter
        model.filters = item.filters
        model.kind = SearchKind(rawValue: item.kind) ?? .all
        model.matchPath = item.matchPath
        model.scopeID = model.roots.contains(where: { $0.id == item.rootID }) ? item.rootID : nil
        rebuildFilterChips()
        model.search(immediate: true); focusSearch()
    }
    @objc private func restoreHistory(_ sender: Any?) {
        let index = historyPopup.indexOfSelectedItem - 1
        if preferences.history.indices.contains(index) { applySavedSearch(preferences.history[index]) }
        historyPopup.selectItem(at: 0)
    }
    @objc private func restoreSaved(_ sender: Any?) {
        let index = savedPopup.indexOfSelectedItem - 1
        if displayedSavedIDs.indices.contains(index), let item = preferences.saved.first(where: { $0.id == displayedSavedIDs[index] }) { applySavedSearch(item) }
        else if index == displayedSavedIDs.count { manageSavedSearches(sender) }
        savedPopup.selectItem(at: 0)
    }
    @objc private func saveCurrentSearch(_ sender: Any?) {
        synchronizeSearchInput(immediate: true)
        let current = currentSavedSearch()
        let alert = NSAlert(); alert.messageText = "收藏当前搜索"; alert.informativeText = "名称便于再次查找，完整条件会一并保存。"; alert.addButton(withTitle: "收藏"); alert.addButton(withTitle: "取消")
        let name = NSTextField(string: String(current.title.prefix(45))); name.frame = NSRect(x: 0, y: 0, width: 380, height: 26); alert.accessoryView = name
        let pin = NSButton(checkboxWithTitle: "固定在收藏菜单前面", target: nil, action: nil)
        let accessory = FilterUI.column([name, pin]); accessory.frame = NSRect(x: 0, y: 0, width: 380, height: 60); name.widthAnchor.constraint(equalToConstant: 380).isActive = true; alert.accessoryView = accessory
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var item = current; item.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); item.isPinned = pin.state == .on
            self.preferences.bookmark(item); self.rebuildSavedMenus(); self.footerLabel.stringValue = "已收藏当前完整搜索条件"
        }
    }
    @objc private func manageSavedSearches(_ sender: Any?) {
        guard favoritesPanel == nil, let window else { return }
        synchronizeSearchInput()
        let panel = SearchFavoritesPanelController(items: { [weak self] in self?.preferences.saved ?? [] }, apply: { [weak self] id in
            guard let self, let item = self.preferences.saved.first(where: { $0.id == id }) else { return }; self.applySavedSearch(item)
        }, rename: { [weak self] id, name in self?.preferences.renameSaved(id: id, name: name); self?.rebuildSavedMenus() }, replace: { [weak self] id in
            guard let self else { return }; self.preferences.updateSaved(id: id, with: self.currentSavedSearch()); self.rebuildSavedMenus()
        }, pin: { [weak self] id in self?.preferences.togglePinned(id: id); self?.rebuildSavedMenus() }, delete: { [weak self] id in self?.preferences.removeSaved(id: id); self?.rebuildSavedMenus() })
        favoritesPanel = panel; panel.presentSheet(for: window) { [weak self] in self?.favoritesPanel = nil }
    }
    private func metadata(_ hit: FileHit) -> ResultMetadata {
        let cached = resultMetadata.value(path: hit.path)
        return ResultMetadata(size: hit.size ?? cached?.size, modified: hit.modifiedDate ?? cached?.modified)
    }
    @objc private func resultScrollChanged(_ notification: Notification) { loadVisibleMetadata() }
    private func loadVisibleMetadata() {
        let range = resultsTable.rows(in: resultsTable.visibleRect)
        guard range.location != NSNotFound else { return }
        let indices = range.location..<min(displayedResults.count, range.location + range.length + 8)
        let hits = indices.compactMap { displayedResults.indices.contains($0) ? displayedResults[$0] : nil }.filter(\.isOnline)
        resultMetadata.load(paths: hits.map(\.path))
    }
    private func refreshResultMetadata() {
        guard !updating, !displayedResults.isEmpty else { return }
        updating = true
        defer { updating = false; updateSelectionDescription() }
        if resultSortColumn == "size" || resultSortColumn == "modified" {
            let selected = Set(selectedHits().map(\.path))
            displayedResults = sortedResults(displayedResults)
            resultsTable.reloadData()
            resultsTable.selectRowIndexes(IndexSet(displayedResults.indices.filter { selected.contains(displayedResults[$0].path) }), byExtendingSelection: false)
        } else {
            let rows = resultsTable.rows(in: resultsTable.visibleRect)
            if rows.location != NSNotFound { resultsTable.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<min(displayedResults.count, rows.location + rows.length)), columnIndexes: IndexSet(integersIn: 0..<resultsTable.tableColumns.count)) }
        }
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === resultsTable, let sort = tableView.sortDescriptors.first else { return }
        resultSortColumn = sort.key ?? ""; resultSortAscending = sort.ascending
        if resultSortColumn == "size" || resultSortColumn == "modified" { resultMetadata.load(paths: displayedResults.filter(\.isOnline).map(\.path)) }
        update()
    }
    private func sortedResults(_ hits: [FileHit]) -> [FileHit] {
        guard !resultSortColumn.isEmpty else { return hits }
        return hits.sorted { a, b in
            let comparison: ComparisonResult
            switch resultSortColumn {
            case "size":
                let x = metadata(a).size ?? -1, y = metadata(b).size ?? -1
                comparison = x == y ? a.path.localizedStandardCompare(b.path) : (x < y ? .orderedAscending : .orderedDescending)
            case "modified":
                let x = metadata(a).modified ?? .distantPast, y = metadata(b).modified ?? .distantPast
                comparison = x == y ? a.path.localizedStandardCompare(b.path) : (x < y ? .orderedAscending : .orderedDescending)
            case "path": comparison = a.parentPath.localizedStandardCompare(b.parentPath)
            case "kind": comparison = (a.isDirectory ? "文件夹" : (a.name as NSString).pathExtension).localizedStandardCompare(b.isDirectory ? "文件夹" : (b.name as NSString).pathExtension)
            case "online": comparison = a.isOnline == b.isOnline ? a.path.localizedStandardCompare(b.path) : (a.isOnline ? .orderedAscending : .orderedDescending)
            default: comparison = a.name.localizedStandardCompare(b.name)
            }
            return resultSortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    @objc func previewSelection(_ sender: Any?) {
        if workspace.isSearchSelectionActive, selectedHit() == nil { return }
        workspace.toggleCurrentPreview()
    }

    @objc private func showIssues(_ sender: Any?) {
        if let issuesController { issuesController.close() }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "扫描未覆盖的路径"
        panel.minSize = NSSize(width: 580, height: 340)
        panel.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let explanation = NSTextField(wrappingLabelWithString: "以下路径未能完整扫描，相关文件可能不在搜索结果中。权限受限时，可在系统设置中授予「完全磁盘访问权限」，再重新扫描。")
        explanation.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(explanation)
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.minSize = NSSize(width: 0, height: 200)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.string = model.issues.enumerated().map { index, issue in "\(index + 1). \(issue.path)\n   \(issue.message)" }.joined(separator: "\n\n")
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll)
        let privacy = NSButton(title: "打开完全磁盘访问设置", target: self, action: #selector(openPrivacy(_:)))
        privacy.bezelStyle = .rounded
        stack.addArrangedSubview(privacy)
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor), stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor), stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        panel.center()
        issuesController = NSWindowController(window: panel)
        issuesController?.showWindow(sender)
    }
    @objc private func openPrivacy(_ sender: Any?) { model.openPrivacySettings() }
}

@MainActor
private final class ResultTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onPreview: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onFocus: (() -> Void)?
    var onCopyFiles: (() -> Void)?
    var onCutFiles: (() -> Void)?
    var onPasteFiles: (() -> Void)?
    var onDeleteFiles: (() -> Void)?
    var onRenameFile: (() -> Void)?
    @objc func copy(_ sender: Any?) { onFocus?(); onCopyFiles?() }
    @objc func cut(_ sender: Any?) { onFocus?(); onCutFiles?() }
    @objc func paste(_ sender: Any?) { onFocus?(); onPasteFiles?() }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); if accepted { onFocus?() }; return accepted }
    override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
    override func keyDown(with event: NSEvent) {
        onFocus?()
        if event.keyCode == 51, event.modifierFlags.contains(.command) { onDeleteFiles?(); return }
        if event.keyCode == 120 { onRenameFile?(); return }
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.command) { onReveal?() } else { onOpen?() }
            return
        }
        if event.keyCode == 49 { onPreview?(); return }
        if event.charactersIgnoringModifiers?.lowercased() == "c", event.modifierFlags.contains([.command, .shift]) { onCopyPath?(); return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        onFocus?()
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return row >= 0 ? super.menu(for: event) : nil
    }
}

@MainActor
private final class RootCellView: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        addSubview(icon); addSubview(title); addSubview(subtitle)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 21), icon.heightAnchor.constraint(equalToConstant: 21),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5), title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor), subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor), subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4)
        ])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func set(title: String, subtitle: String, symbol: String, offline: Bool) {
        self.title.stringValue = title
        self.subtitle.stringValue = subtitle
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = offline ? .secondaryLabelColor : .controlAccentColor
        self.title.textColor = offline ? .secondaryLabelColor : .labelColor
    }
}

@MainActor
private final class ResultCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon: NSImageView?
    init(hasIcon: Bool) {
        icon = hasIcon ? NSImageView() : nil
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        if let icon {
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 17), icon.heightAnchor.constraint(equalToConstant: 17), label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)])
        } else { label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5).isActive = true }
        NSLayoutConstraint.activate([label.centerYAnchor.constraint(equalTo: centerYAnchor), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5)])
        textField = label
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func set(_ value: String, icon image: NSImage?, online: Bool) {
        label.stringValue = value
        label.textColor = online ? .labelColor : .secondaryLabelColor
        icon?.image = image
        icon?.contentTintColor = online ? .controlAccentColor : .secondaryLabelColor
    }
}

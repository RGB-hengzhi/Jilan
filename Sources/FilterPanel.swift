// SPDX-License-Identifier: GPL-3.0-only
import AppKit

struct SearchFilterPanelValues {
    var filters: SearchFilters
    var kind: SearchKind
    var extensionFilter: String
    var matchPath: Bool
    var sizeFilter: String
    var modifiedFilter: String
}

@MainActor
final class SearchFilterPanelController: NSWindowController, NSWindowDelegate {
    private let original: SearchFilterPanelValues
    private let currentDirectory: String
    private var finished = false
    private var completion: ((SearchFilterPanelValues?) -> Void)?
    private let category: NSPopUpButton
    private let kind: NSPopUpButton
    private let nameMode: NSPopUpButton
    private let nameValue: NSTextField
    private let extensionValue: NSTextField
    private let matchPath = NSButton(checkboxWithTitle: "顶部关键词同时匹配路径", target: nil, action: nil)
    private let hidden: NSPopUpButton
    private let connection: NSPopUpButton
    private let subfolders = NSButton(checkboxWithTitle: "包含所选目录的子目录", target: nil, action: nil)
    private let included: SearchDirectoryListEditor
    private let excluded: SearchDirectoryListEditor
    private let size: SearchSizeFilterEditor
    private let modified: SearchDateFilterEditor
    private let created: SearchDateFilterEditor
    private let group: SearchConditionGroupEditor

    init(values: SearchFilterPanelValues, currentDirectory: String) {
        original = values; self.currentDirectory = currentDirectory
        category = FilterUI.popup(SearchFilterCategory.allCases.map(\.rawValue), selected: values.filters.category.rawValue)
        kind = FilterUI.popup(SearchKind.allCases.map(\.rawValue), selected: values.kind.rawValue)
        nameMode = FilterUI.popup(SearchNameMode.allCases.map(\.rawValue), selected: values.filters.nameMode.rawValue)
        nameValue = FilterUI.text(values.filters.nameValue, placeholder: "名称条件，独立于顶部关键词")
        extensionValue = FilterUI.text(values.extensionFilter, placeholder: "多个扩展名用分号分开，如 pdf;docx")
        hidden = FilterUI.popup(SearchHiddenFilter.allCases.map(\.rawValue), selected: values.filters.hidden.rawValue)
        connection = FilterUI.popup(SearchConnectionFilter.allCases.map(\.rawValue), selected: values.filters.connection.rawValue)
        included = SearchDirectoryListEditor(paths: values.filters.includedPaths, purpose: "包含目录", currentDirectory: currentDirectory)
        excluded = SearchDirectoryListEditor(paths: values.filters.excludedPaths, purpose: "排除目录", currentDirectory: nil)
        size = SearchSizeFilterEditor(expression: values.sizeFilter)
        modified = SearchDateFilterEditor(expression: values.modifiedFilter)
        created = SearchDateFilterEditor(expression: values.filters.createdFilter)
        group = SearchConditionGroupEditor(group: values.filters.conditionGroup)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 770, height: 730), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "更多筛选"; window.minSize = NSSize(width: 680, height: 500); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; makeInterface()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func presentSheet(for parent: NSWindow, completion: @escaping (SearchFilterPanelValues?) -> Void) {
        self.completion = completion
        guard let window else { return }; parent.beginSheet(window)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(nil); return false }

    private func makeInterface() {
        guard let root = window?.contentView else { return }
        let main = FilterUI.column(); main.spacing = 12
        let introduction = FilterUI.hint("在面板中组合筛选条件，点击“应用筛选”后更新结果。取消会保留原条件；大小和日期需要在后台检查文件属性。")
        main.addArrangedSubview(introduction)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let fields = FilterUI.column(); fields.spacing = 13; fields.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 12)
        scroll.documentView = fields; fields.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([fields.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), fields.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), fields.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)])
        func section(_ title: String, _ views: [NSView]) {
            let block = FilterUI.column([FilterUI.label(title, bold: true)] + views)
            fields.addArrangedSubview(block); block.widthAnchor.constraint(equalTo: fields.widthAnchor, constant: -12).isActive = true
            for child in block.arrangedSubviews { child.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true }
        }
        matchPath.state = original.matchPath ? .on : .off
        subfolders.state = original.filters.includeSubfolders ? .on : .off
        section("文件类型与名称", [FilterUI.row([FilterUI.label("项目"), kind, FilterUI.label("常用类型"), category, NSView()]), FilterUI.row([FilterUI.label("名称"), nameMode, nameValue]), FilterUI.row([FilterUI.label("扩展名"), extensionValue]), matchPath])
        section("搜索范围", [FilterUI.hint("多个包含目录取并集；排除目录优先。范围只在已经索引的位置内筛选。"), included, subfolders, excluded])
        section("大小", [size, FilterUI.hint("空着表示不设限制。上下限同时填写时包含两端；文件夹大小不递归统计。")])
        section("修改日期", [modified])
        section("创建日期", [created])
        section("隐藏与连接状态", [FilterUI.row([FilterUI.label("隐藏文件"), hidden, FilterUI.label("磁盘状态"), connection, NSView()])])
        section("高级条件组", [FilterUI.hint("同组可选择全部满足或任一满足。可把不同组合放在子组中，例如：（PDF 或 Word）且名称不含草稿。"), group])
        main.addArrangedSubview(scroll); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        let apply = FilterActionButton("应用筛选") { [weak self] in self?.apply() }; apply.keyEquivalent = "\r"
        let cancel = FilterActionButton("取消") { [weak self] in self?.finish(nil) }; cancel.keyEquivalent = "\u{1b}"
        main.addArrangedSubview(FilterUI.row([FilterUI.hint("滚动查看全部条件"), NSView(), cancel, apply]))
        FilterUI.pin(main, in: root, inset: 16)
        main.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true }
    }
    private func apply() {
        window?.makeFirstResponder(nil)
        do {
            var result = original
            result.kind = SearchKind(rawValue: kind.titleOfSelectedItem ?? "") ?? .all
            result.extensionFilter = extensionValue.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            result.matchPath = matchPath.state == .on
            result.sizeFilter = try size.expression()
            try modified.validate(); try created.validate()
            result.modifiedFilter = modified.expression
            result.filters.category = SearchFilterCategory(rawValue: category.titleOfSelectedItem ?? "") ?? .all
            result.filters.nameMode = SearchNameMode(rawValue: nameMode.titleOfSelectedItem ?? "") ?? .contains
            result.filters.nameValue = nameValue.stringValue
            result.filters.includedPaths = included.paths; result.filters.excludedPaths = excluded.paths
            result.filters.includeSubfolders = subfolders.state == .on
            result.filters.hidden = SearchHiddenFilter(rawValue: hidden.titleOfSelectedItem ?? "") ?? .all
            result.filters.connection = SearchConnectionFilter(rawValue: connection.titleOfSelectedItem ?? "") ?? .all
            result.filters.createdFilter = created.expression
            result.filters.conditionGroup = group.value
            try validateGroup(result.filters.conditionGroup)
            finish(result)
        } catch {
            let alert = NSAlert(); alert.messageText = "请检查筛选条件"; alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "知道了")
            if let window { alert.beginSheetModal(for: window) }
        }
    }
    private func validateGroup(_ group: SearchConditionGroup) throws {
        for rule in group.rules where !rule.isEmpty {
            if rule.comparison == .range && rule.upperValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SearchFilterFormError("“\(rule.field.rawValue) 介于”需要填写上限。") }
            if rule.field == .size {
                let pattern = "^[0-9]+(?:\\.[0-9]+)?(?:b|kb|mb|gb|tb|kib|mib|gib|tib)?$"
                for raw in [rule.value] + (rule.comparison == .range ? [rule.upperValue] : []) where raw.range(of: pattern, options: .regularExpression) == nil { throw SearchFilterFormError("大小条件请使用非负数字和单位。") }
                if rule.comparison == .range {
                    func bytes(_ raw: String) -> Double {
                        let number = raw.prefix { $0.isNumber || $0 == "." }
                        let unit = String(raw.dropFirst(number.count))
                        let factors: [String: Double] = ["": 1, "b": 1, "kb": 1_000, "mb": 1_000_000, "gb": 1_000_000_000, "tb": 1_000_000_000_000, "kib": 1_024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776]
                        return (Double(number) ?? 0) * (factors[unit] ?? 1)
                    }
                    if bytes(rule.value) > bytes(rule.upperValue) { throw SearchFilterFormError("组合条件的大小下限不能高于上限。") }
                }
            }
            if (rule.field == .modified || rule.field == .created), rule.comparison == .range,
               let lower = FilterUI.dateFormatter.date(from: rule.value), let upper = FilterUI.dateFormatter.date(from: rule.upperValue), lower > upper {
                throw SearchFilterFormError("组合条件的日期起始时间不能晚于截止时间。")
            }
        }
        for child in group.groups { try validateGroup(child) }
    }
    private func finish(_ value: SearchFilterPanelValues?) {
        guard !finished else { return }; finished = true
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        completion?(value); completion = nil
    }
}

private struct SearchFilterFormError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
private final class SearchDirectoryListEditor: NSView {
    private(set) var paths: [String]
    private let purpose: String
    private let currentDirectory: String?
    private let stack = FilterUI.column()
    init(paths: [String], purpose: String, currentDirectory: String?) {
        self.paths = paths; self.purpose = purpose; self.currentDirectory = currentDirectory
        super.init(frame: .zero); FilterUI.pin(stack, in: self); rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func rebuild() {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let add = FilterActionButton("＋ 选择\(purpose)…") { [weak self] in self?.choose() }
        let actions = FilterUI.row([FilterUI.label(purpose), add])
        if let currentDirectory {
            let button = FilterActionButton("当前工作栏目录") { [weak self] in self?.append(currentDirectory) }; button.toolTip = currentDirectory; actions.addArrangedSubview(button)
        }
        actions.addArrangedSubview(NSView()); stack.addArrangedSubview(actions)
        if paths.isEmpty { stack.addArrangedSubview(FilterUI.hint(purpose == "包含目录" ? "全部已索引目录" : "没有排除目录")) }
        for path in paths {
            let label = FilterUI.label(path); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = path
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = FilterUI.row([label, FilterActionButton("移除") { [weak self] in self?.paths.removeAll { $0 == path }; self?.rebuild() }])
            stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
    private func append(_ path: String) {
        let normalized = SearchFilters.normalizedPath(path)
        if !paths.contains(where: { SearchFilters.normalizedPath($0) == normalized }) { paths.append(normalized) }
        rebuild()
    }
    private func choose() {
        let picker = NSOpenPanel(); picker.title = "选择\(purpose)"; picker.prompt = "追加目录"
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = true; picker.canCreateDirectories = false
        guard let window else { return }
        picker.beginSheetModal(for: window) { [weak self, weak picker] result in
            guard result == .OK, let self, let picker else { return }; for url in picker.urls { self.append(url.path) }
        }
    }
}

@MainActor
private final class SearchSizeFilterEditor: NSView, NSTextFieldDelegate {
    private let lower = FilterUI.text(placeholder: "不限")
    private let upper = FilterUI.text(placeholder: "不限")
    private let lowerUnit = FilterUI.popup(FilterUI.sizeUnits, selected: "MB")
    private let upperUnit = FilterUI.popup(FilterUI.sizeUnits, selected: "MB")
    private let lowerComparison = FilterUI.popup(["≥", ">"])
    private let upperComparison = FilterUI.popup(["≤", "<"])
    private var lowerStrict = false
    private var upperStrict = false
    private let legacy: String
    private var parsed = false
    private let fallback: NSTextField
    init(expression: String) {
        legacy = expression; fallback = FilterUI.text(expression, placeholder: "现有大小条件")
        super.init(frame: .zero)
        let stack = FilterUI.column([FilterUI.row([FilterUI.label("下限"), lowerComparison, lower, lowerUnit, FilterUI.label("上限"), upperComparison, upper, upperUnit])])
        FilterUI.pin(stack, in: self)
        parsed = restore(expression)
        if !parsed { lower.stringValue = ""; upper.stringValue = "" }
        lowerComparison.selectItem(at: lowerStrict ? 1 : 0); upperComparison.selectItem(at: upperStrict ? 1 : 0)
        lower.delegate = self; upper.delegate = self; updateComparisons()
        if !parsed && !expression.isEmpty { stack.addArrangedSubview(FilterUI.hint("保留现有自定义条件；填写上下限会替换它。")); stack.addArrangedSubview(fallback); fallback.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        lower.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true; upper.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func restore(_ raw: String) -> Bool {
        guard !raw.isEmpty else { return true }
        func load(_ raw: String, _ field: NSTextField, _ unit: NSPopUpButton) -> Bool {
            let pattern = "^([0-9]+(?:\\.[0-9]+)?)\\s*([a-zA-Z]*)$"
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)), let number = Range(match.range(at: 1), in: raw), let suffix = Range(match.range(at: 2), in: raw), let restoredUnit = FilterUI.sizeUnit(String(raw[suffix])) else { return false }
            field.stringValue = String(raw[number]); unit.selectItem(withTitle: restoredUnit); return true
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("..") { let bounds = text.components(separatedBy: ".."); return bounds.count == 2 && load(bounds[0], lower, lowerUnit) && load(bounds[1], upper, upperUnit) }
        if text.hasPrefix(">=") { return load(String(text.dropFirst(2)), lower, lowerUnit) }
        if text.hasPrefix(">") { lowerStrict = true; return load(String(text.dropFirst()), lower, lowerUnit) }
        if text.hasPrefix("<=") { return load(String(text.dropFirst(2)), upper, upperUnit) }
        if text.hasPrefix("<") { upperStrict = true; return load(String(text.dropFirst()), upper, upperUnit) }
        return false
    }
    func expression() throws -> String {
        func validated(_ expression: String) throws -> String {
            if !expression.isEmpty, let error = AdvancedSearchPlan.parse(SearchRequest(query: "", sizeFilter: expression)).error { throw SearchFilterFormError(error) }
            return expression
        }
        let low = lower.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), high = upper.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if low.isEmpty && high.isEmpty {
            let existing = parsed ? "" : fallback.stringValue
            return try validated(existing)
        }
        for raw in [low, high] where !raw.isEmpty {
            guard raw.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
                  let number = Double(raw), number.isFinite, number >= 0 else { throw SearchFilterFormError("大小上下限请填写非负十进制数字，例如 100 或 0.5；不支持加号和科学计数法。") }
        }
        let lowValue = low + (lowerUnit.titleOfSelectedItem ?? "MB").lowercased(), highValue = high + (upperUnit.titleOfSelectedItem ?? "MB").lowercased()
        if !low.isEmpty && !high.isEmpty {
            let multipliers: [String: Double] = ["B": 1, "KB": 1_000, "MB": 1_000_000, "GB": 1_000_000_000, "TB": 1_000_000_000_000, "KiB": 1_024, "MiB": 1_048_576, "GiB": 1_073_741_824, "TiB": 1_099_511_627_776]
            guard Double(low)! * (multipliers[lowerUnit.titleOfSelectedItem ?? "MB"] ?? 1) <= Double(high)! * (multipliers[upperUnit.titleOfSelectedItem ?? "MB"] ?? 1) else { throw SearchFilterFormError("大小下限不能高于上限。") }
            return try validated(lowValue + ".." + highValue)
        }
        return try validated(!low.isEmpty ? (lowerComparison.indexOfSelectedItem == 1 ? ">" : ">=") + lowValue : (upperComparison.indexOfSelectedItem == 1 ? "<" : "<=") + highValue)
    }
    func controlTextDidChange(_ notification: Notification) { updateComparisons() }
    private func updateComparisons() {
        let both = !lower.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !upper.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        lowerComparison.isEnabled = !both; upperComparison.isEnabled = !both
        if both { lowerComparison.selectItem(at: 0); upperComparison.selectItem(at: 0) }
    }
}

@MainActor
private final class SearchDateFilterEditor: NSView {
    private let mode = FilterUI.popup(["不限", "今天", "昨天", "近7天", "近30天", "日期范围", "现有自定义条件"])
    private let lowerEnabled = NSButton(checkboxWithTitle: "起始日期", target: nil, action: nil)
    private let upperEnabled = NSButton(checkboxWithTitle: "截止日期", target: nil, action: nil)
    private let lower = NSDatePicker()
    private let upper = NSDatePicker()
    private let custom: NSTextField
    private let range: NSStackView
    private var lowerStrict = false
    private var upperStrict = false
    init(expression: String) {
        custom = FilterUI.text(expression, placeholder: "现有日期条件")
        range = FilterUI.row([])
        super.init(frame: .zero)
        for picker in [lower, upper] { picker.datePickerStyle = .textFieldAndStepper; picker.presentsCalendarOverlay = true; picker.datePickerElements = .yearMonthDay; picker.locale = Locale(identifier: "zh_CN"); picker.dateValue = Date(); picker.widthAnchor.constraint(equalToConstant: 180).isActive = true }
        lowerEnabled.state = .on; upperEnabled.state = .on
        range.addArrangedSubview(FilterUI.column([lowerEnabled, lower])); range.addArrangedSubview(FilterUI.column([upperEnabled, upper])); range.addArrangedSubview(NSView())
        let stack = FilterUI.column([mode, range, custom]); FilterUI.pin(stack, in: self); custom.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        mode.target = self; mode.action = #selector(modeChanged(_:)); restore(expression); updateVisibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func restore(_ expression: String) {
        let mapping = ["": 0, "today": 1, "yesterday": 2, "7days": 3, "30days": 4]
        if let index = mapping[expression.lowercased()] { mode.selectItem(at: index); return }
        let bounds = expression.components(separatedBy: "..")
        if bounds.count == 2, let start = FilterUI.dateFormatter.date(from: bounds[0]), let end = FilterUI.dateFormatter.date(from: bounds[1]) { lower.dateValue = start; upper.dateValue = end; mode.selectItem(at: 5); return }
        for (prefix, lowerBound) in [(">=", true), ("<=", false), (">", true), ("<", false)] {
            if expression.hasPrefix(prefix), let date = FilterUI.dateFormatter.date(from: String(expression.dropFirst(prefix.count))) {
                mode.selectItem(at: 5)
                if lowerBound { lower.dateValue = date; upperEnabled.state = .off; lowerStrict = prefix == ">"; lowerEnabled.title = lowerStrict ? "起始日期（不含当天）" : "起始日期" }
                else { upper.dateValue = date; lowerEnabled.state = .off; upperStrict = prefix == "<"; upperEnabled.title = upperStrict ? "截止日期（不含当天）" : "截止日期" }
                return
            }
        }
        if let date = FilterUI.dateFormatter.date(from: expression) { lower.dateValue = date; upper.dateValue = date; mode.selectItem(at: 5) }
        else { mode.selectItem(at: 6) }
    }
    var expression: String {
        switch mode.indexOfSelectedItem {
        case 0: return ""
        case 1: return "today"
        case 2: return "yesterday"
        case 3: return "7days"
        case 4: return "30days"
        case 5:
            let start = FilterUI.dateFormatter.string(from: lower.dateValue), end = FilterUI.dateFormatter.string(from: upper.dateValue)
            if lowerEnabled.state == .on && upperEnabled.state == .on { return start + ".." + end }
            if lowerEnabled.state == .on { return (lowerStrict ? ">" : ">=") + start }
            if upperEnabled.state == .on { return (upperStrict ? "<" : "<=") + end }
            return ""
        default: return custom.stringValue
        }
    }
    func validate() throws {
        if mode.indexOfSelectedItem == 5, lowerEnabled.state == .on, upperEnabled.state == .on,
           Calendar.current.startOfDay(for: lower.dateValue) > Calendar.current.startOfDay(for: upper.dateValue) { throw SearchFilterFormError("日期起始时间不能晚于截止时间。") }
    }
    @objc private func modeChanged(_ sender: Any?) { updateVisibility() }
    private func updateVisibility() { range.isHidden = mode.indexOfSelectedItem != 5; custom.isHidden = mode.indexOfSelectedItem != 6 }
}

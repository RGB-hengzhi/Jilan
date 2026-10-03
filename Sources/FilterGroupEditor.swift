// SPDX-License-Identifier: GPL-3.0-only
import AppKit

@MainActor
final class FilterActionButton: NSButton {
    private var handler: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; controlSize = .small
        target = self; self.action = #selector(invoke(_:))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke(_ sender: Any?) { handler() }
}

@MainActor
private final class FilterVerticalStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
enum FilterUI {
    static func dateExpressionTitle(_ expression: String) -> String {
        switch expression.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "today": return "今天"
        case "yesterday": return "昨天"
        case "7days": return "近7天"
        case "30days": return "近30天"
        default: return expression
        }
    }
    static let sizeUnits = ["B", "KB", "MB", "GB", "TB", "KiB", "MiB", "GiB", "TiB"]
    static func sizeUnit(_ raw: String) -> String? {
        let normalized = raw.lowercased()
        if let alias = ["": "B", "k": "KB", "m": "MB", "g": "GB", "t": "TB"][normalized] { return alias }
        return sizeUnits.first { $0.lowercased() == normalized }
    }
    static func label(_ text: String, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        return field
    }
    static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        return row
    }
    static func column(_ views: [NSView] = []) -> NSStackView {
        let column = FilterVerticalStackView(views: views); column.orientation = .vertical; column.spacing = 8; column.alignment = .leading
        return column
    }
    static func popup(_ values: [String], selected: String? = nil) -> NSPopUpButton {
        let popup = NSPopUpButton(); popup.addItems(withTitles: values)
        if let selected { popup.selectItem(withTitle: selected) }
        popup.controlSize = .small; return popup
    }
    static func text(_ value: String = "", placeholder: String) -> NSTextField {
        let field = NSTextField(string: value); field.placeholderString = placeholder; field.font = .systemFont(ofSize: 12)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); return field
    }
    static func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor
        return field
    }
    static func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
        NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset), child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset), child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)])
    }
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; return formatter
    }()
}

/// Every nested editor edits the backend's value type directly. No generated
/// query string or duplicated parser stands between the native form and search.
@MainActor
final class SearchConditionGroupEditor: NSView {
    private var group: SearchConditionGroup
    private let depth: Int
    private let mode: NSPopUpButton
    private let content = FilterUI.column()
    private var ruleEditors: [SearchConditionRuleEditor] = []
    private var groupEditors: [SearchConditionGroupEditor] = []
    private let onRemove: (() -> Void)?

    init(group: SearchConditionGroup, depth: Int = 0, onRemove: (() -> Void)? = nil) {
        self.group = group; self.depth = depth; self.onRemove = onRemove
        mode = FilterUI.popup(SearchConditionMode.allCases.map(\.rawValue), selected: group.mode.rawValue)
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 7; layer?.borderWidth = 1; layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = (depth % 2 == 0 ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).cgColor
        FilterUI.pin(content, in: self, inset: 10); rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var value: SearchConditionGroup {
        var result = group
        result.mode = SearchConditionMode(rawValue: mode.titleOfSelectedItem ?? "") ?? .all
        result.rules = ruleEditors.map(\.value); result.groups = groupEditors.map(\.value)
        return result
    }

    private func rebuild() {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        ruleEditors.removeAll(); groupEditors.removeAll()
        let header = FilterUI.row([FilterUI.label(depth == 0 ? "组合条件" : "子条件组", bold: true), mode, NSView()])
        if let onRemove { header.addArrangedSubview(FilterActionButton("删除组", action: onRemove)) }
        add(header)
        for rule in group.rules {
            let editor = SearchConditionRuleEditor(rule: rule) { [weak self] in
                guard let self else { return }; self.group = self.value; self.group.rules.removeAll { $0.id == rule.id }; self.rebuild()
            }
            ruleEditors.append(editor); add(editor)
        }
        for child in group.groups {
            let editor = SearchConditionGroupEditor(group: child, depth: depth + 1) { [weak self] in
                guard let self else { return }; self.group = self.value; self.group.groups.removeAll { $0.id == child.id }; self.rebuild()
            }
            groupEditors.append(editor); add(editor)
        }
        let addGroup = FilterActionButton("＋ 添加子组") { [weak self] in guard let self else { return }; self.group = self.value; self.group.groups.append(SearchConditionGroup()); self.rebuild() }
        addGroup.isEnabled = depth < 8; addGroup.toolTip = depth < 8 ? "在本组中嵌套全部或任一条件" : "已达到 8 层嵌套，可在本层继续添加条件"
        add(FilterUI.row([
            FilterActionButton("＋ 添加条件") { [weak self] in guard let self else { return }; self.group = self.value; self.group.rules.append(SearchConditionRule()); self.rebuild() },
            addGroup, NSView()
        ]))
        if group.rules.isEmpty && group.groups.isEmpty { add(FilterUI.hint("可添加名称、路径、扩展名、大小和日期条件；子组可继续嵌套。空条件不参与筛选。")) }
    }
    private func add(_ child: NSView) { content.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
}

@MainActor
private final class SearchConditionRuleEditor: NSView {
    private var rule: SearchConditionRule
    private let field: NSPopUpButton
    private let comparison: NSPopUpButton
    private let lower: NSTextField
    private let upper: NSTextField
    private let lowerUnit = FilterUI.popup(FilterUI.sizeUnits)
    private let upperUnit = FilterUI.popup(FilterUI.sizeUnits)
    private let lowerDate = NSDatePicker()
    private let upperDate = NSDatePicker()
    private let datePreset = FilterUI.popup(["指定日期", "今天", "昨天", "近7天", "近30天"])
    private let rangeSeparator = FilterUI.label("至")
    private let values = FilterUI.row([])
    private let stack = FilterUI.column()

    init(rule: SearchConditionRule, onRemove: @escaping () -> Void) {
        self.rule = rule
        field = FilterUI.popup(SearchConditionField.allCases.map(\.rawValue), selected: rule.field.rawValue)
        comparison = FilterUI.popup(rule.field.comparisons.map(\.rawValue), selected: rule.comparison.rawValue)
        lower = FilterUI.text(rule.value, placeholder: "条件值")
        upper = FilterUI.text(rule.upperValue, placeholder: "上限")
        super.init(frame: .zero)
        FilterUI.pin(stack, in: self)
        field.target = self; field.action = #selector(fieldChanged(_:))
        comparison.target = self; comparison.action = #selector(comparisonChanged(_:))
        datePreset.target = self; datePreset.action = #selector(dateModeChanged(_:))
        for picker in [lowerDate, upperDate] {
            picker.datePickerElements = .yearMonthDay; picker.datePickerStyle = .textFieldAndStepper
            picker.presentsCalendarOverlay = true
            picker.locale = Locale(identifier: "zh_CN"); picker.widthAnchor.constraint(equalToConstant: 135).isActive = true
        }
        stack.addArrangedSubview(FilterUI.row([field, comparison, NSView(), FilterActionButton("删除", action: onRemove)]))
        stack.addArrangedSubview(values); values.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        restoreValues(); rebuildValues()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var value: SearchConditionRule {
        var result = rule
        result.field = SearchConditionField(rawValue: field.titleOfSelectedItem ?? "") ?? .name
        result.comparison = SearchComparison(rawValue: comparison.titleOfSelectedItem ?? "") ?? .contains
        if result.field == .size {
            let lowerValue = lower.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), upperValue = upper.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            result.value = lowerValue + (lowerValue.isEmpty ? "" : (lowerUnit.titleOfSelectedItem ?? "B").lowercased())
            result.upperValue = upperValue + (upperValue.isEmpty ? "" : (upperUnit.titleOfSelectedItem ?? "B").lowercased())
        } else if result.field == .modified || result.field == .created {
            let presets = ["", "today", "yesterday", "7days", "30days"]
            let allowsPreset = result.comparison == .equal || result.comparison == .notEqual
            result.value = allowsPreset && datePreset.indexOfSelectedItem > 0 ? presets[datePreset.indexOfSelectedItem] : FilterUI.dateFormatter.string(from: lowerDate.dateValue)
            result.upperValue = FilterUI.dateFormatter.string(from: upperDate.dateValue)
        } else { result.value = lower.stringValue; result.upperValue = upper.stringValue }
        return result
    }
    private func restoreValues() {
        if rule.field == .size {
            for (text, unit, raw) in [(lower, lowerUnit, rule.value), (upper, upperUnit, rule.upperValue)] {
                let pattern = "^([0-9]+(?:\\.[0-9]+)?)\\s*([a-zA-Z]*)$"
                if let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)), let numberRange = Range(match.range(at: 1), in: raw), let unitRange = Range(match.range(at: 2), in: raw), let restoredUnit = FilterUI.sizeUnit(String(raw[unitRange])) {
                    text.stringValue = String(raw[numberRange]); unit.selectItem(withTitle: restoredUnit)
                }
            }
        }
        lowerDate.dateValue = FilterUI.dateFormatter.date(from: rule.value) ?? Date()
        upperDate.dateValue = FilterUI.dateFormatter.date(from: rule.upperValue) ?? lowerDate.dateValue
        let relative = ["today": 1, "yesterday": 2, "7days": 3, "30days": 4]
        datePreset.selectItem(at: relative[rule.value] ?? 0)
        if datePreset.indexOfSelectedItem > 0 { restorePresetDates() }
    }
    private func rebuildValues() {
        values.arrangedSubviews.forEach { values.removeArrangedSubview($0); $0.removeFromSuperview() }
        let fieldValue = SearchConditionField(rawValue: field.titleOfSelectedItem ?? "") ?? .name
        let range = comparison.titleOfSelectedItem == SearchComparison.range.rawValue
        if fieldValue == .modified || fieldValue == .created {
            let operation = SearchComparison(rawValue: comparison.titleOfSelectedItem ?? "")
            let allowsPreset = operation == .equal || operation == .notEqual
            if allowsPreset { values.addArrangedSubview(datePreset) }
            if !allowsPreset || datePreset.indexOfSelectedItem == 0 { values.addArrangedSubview(lowerDate) }
            if range { values.addArrangedSubview(rangeSeparator); values.addArrangedSubview(upperDate) }
            values.addArrangedSubview(NSView())
        } else {
            values.addArrangedSubview(lower)
            lower.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
            if fieldValue == .size { values.addArrangedSubview(lowerUnit) }
            if range { values.addArrangedSubview(rangeSeparator); values.addArrangedSubview(upper); if fieldValue == .size { values.addArrangedSubview(upperUnit) } }
        }
    }
    @objc private func fieldChanged(_ sender: Any?) {
        let selected = SearchConditionField(rawValue: field.titleOfSelectedItem ?? "") ?? .name
        rule.field = selected; rule.value = ""; rule.upperValue = ""
        lower.stringValue = ""; upper.stringValue = ""; datePreset.selectItem(at: 0)
        comparison.removeAllItems(); comparison.addItems(withTitles: selected.comparisons.map(\.rawValue)); rule.comparison = selected.comparisons.first ?? .contains; rebuildValues()
    }
    @objc private func comparisonChanged(_ sender: Any?) {
        let operation = SearchComparison(rawValue: comparison.titleOfSelectedItem ?? "") ?? .contains
        let wasPresetComparison = rule.comparison == .equal || rule.comparison == .notEqual
        let isPresetComparison = operation == .equal || operation == .notEqual
        if wasPresetComparison && !isPresetComparison && datePreset.indexOfSelectedItem > 0 { restorePresetDates(); datePreset.selectItem(at: 0) }
        rule.comparison = operation; rebuildValues()
    }
    @objc private func dateModeChanged(_ sender: Any?) { if datePreset.indexOfSelectedItem > 0 { restorePresetDates() }; rebuildValues() }
    private func restorePresetDates() {
        let dayOffset = [0, 0, -1, -6, -29][datePreset.indexOfSelectedItem]
        let today = Calendar.current.startOfDay(for: Date())
        lowerDate.dateValue = Calendar.current.date(byAdding: .day, value: dayOffset, to: today) ?? today
        upperDate.dateValue = datePreset.indexOfSelectedItem == 2 ? lowerDate.dateValue : today
    }
}

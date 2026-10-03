// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// All changes are delegated by stable bookmark ID so sorting pinned rows never
/// causes a rename, replacement or deletion to affect a different bookmark.
@MainActor
final class SearchFavoritesPanelController: NSWindowController, NSWindowDelegate {
    private let items: () -> [SavedSearch]
    private let apply: (UUID) -> Void
    private let rename: (UUID, String) -> Void
    private let replace: (UUID) -> Void
    private let pin: (UUID) -> Void
    private let delete: (UUID) -> Void
    private let rows = FilterUI.column()
    private var onClose: (() -> Void)?
    private var finished = false
    init(items: @escaping () -> [SavedSearch], apply: @escaping (UUID) -> Void, rename: @escaping (UUID, String) -> Void, replace: @escaping (UUID) -> Void, pin: @escaping (UUID) -> Void, delete: @escaping (UUID) -> Void) {
        self.items = items; self.apply = apply; self.rename = rename; self.replace = replace; self.pin = pin; self.delete = delete
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 530), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "管理收藏搜索"; panel.minSize = NSSize(width: 670, height: 350); panel.isReleasedWhenClosed = false
        super.init(window: panel); panel.delegate = self
        let stack = FilterUI.column([FilterUI.hint("固定项排在收藏菜单前面。“更新为当前条件”保留原名称和固定状态；删除仅移除搜索收藏。")])
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        rows.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 12); scroll.documentView = rows; rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), rows.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)])
        stack.addArrangedSubview(scroll); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let close = FilterActionButton("完成") { [weak self] in self?.finish() }; close.keyEquivalent = "\r"
        stack.addArrangedSubview(FilterUI.row([NSView(), close])); FilterUI.pin(stack, in: panel.contentView!, inset: 16)
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func presentSheet(for parent: NSWindow, onClose: @escaping () -> Void) { self.onClose = onClose; if let window { parent.beginSheet(window) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(); return false }
    private func rebuild() {
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        let saved = items().enumerated().sorted { a, b in a.element.isPinned == b.element.isPinned ? a.offset < b.offset : a.element.isPinned }
        if saved.isEmpty { rows.addArrangedSubview(FilterUI.hint("还没有收藏搜索。关闭面板后，可点击“收藏当前搜索”。")) }
        for entry in saved {
            let item = entry.element
            let box = NSView(); box.wantsLayer = true; box.layer?.borderWidth = 1; box.layer?.borderColor = NSColor.separatorColor.cgColor; box.layer?.cornerRadius = 6
            let name = FilterUI.text(item.name, placeholder: item.title); name.setAccessibilityLabel("收藏名称：" + item.title)
            let renameButton = FilterActionButton("保存名称") { [weak self, weak name] in guard let self, let name else { return }; self.window?.makeFirstResponder(nil); self.rename(item.id, name.stringValue); self.rebuild() }
            let pinButton = FilterActionButton(item.isPinned ? "取消固定" : "固定") { [weak self] in self?.pin(item.id); self?.rebuild() }
            let details = FilterUI.hint(conditionSummary(item)); details.maximumNumberOfLines = 3; details.toolTip = details.stringValue
            let block = FilterUI.column([FilterUI.row([name, renameButton, pinButton]), details, FilterUI.row([
                FilterActionButton("应用") { [weak self] in self?.apply(item.id); self?.finish() },
                FilterActionButton("更新为当前条件") { [weak self] in self?.replace(item.id); self?.rebuild() }, NSView(),
                FilterActionButton("删除") { [weak self] in self?.delete(item.id); self?.rebuild() }
            ])])
            FilterUI.pin(block, in: box, inset: 10); block.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true }
            rows.addArrangedSubview(box); box.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true
        }
    }
    private func conditionSummary(_ item: SavedSearch) -> String {
        var result = [item.query.isEmpty ? "全部名称" : item.query]
        if item.kind != SearchKind.all.rawValue { result.append(item.kind) }
        if !item.extensionFilter.isEmpty { result.append("扩展名：" + item.extensionFilter) }
        if !item.sizeFilter.isEmpty { result.append("大小：" + item.sizeFilter) }
        if !item.modifiedFilter.isEmpty { result.append("修改：" + FilterUI.dateExpressionTitle(item.modifiedFilter)) }
        if item.filters.category != .all { result.append(item.filters.category.rawValue) }
        if !item.filters.nameValue.isEmpty { result.append("名称" + item.filters.nameMode.rawValue + "：" + item.filters.nameValue) }
        if !item.filters.includedPaths.isEmpty { result.append("包含 \(item.filters.includedPaths.count) 个目录") }
        if !item.filters.excludedPaths.isEmpty { result.append("排除 \(item.filters.excludedPaths.count) 个目录") }
        if !item.filters.createdFilter.isEmpty { result.append("创建：" + FilterUI.dateExpressionTitle(item.filters.createdFilter)) }
        if !item.filters.conditionGroup.isEmpty { result.append("包含组合条件") }
        if item.filters.hidden != .all { result.append(item.filters.hidden.rawValue) }
        if item.filters.connection != .all { result.append(item.filters.connection.rawValue) }
        return result.joined(separator: " · ")
    }
    private func finish() {
        guard !finished else { return }; finished = true
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        onClose?(); onClose = nil
    }
}

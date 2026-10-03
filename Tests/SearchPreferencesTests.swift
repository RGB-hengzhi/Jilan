// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum SearchPreferencesTests {
    static func run() throws -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickFindPreferences-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = SearchWorkspacePreferences(directory: directory)
        let first = SavedSearch(query: "合同 !草稿", kind: "文件", extensionFilter: "pdf", matchPath: true,
                                rootID: "isolated-fixture", sizeFilter: ">10mb", modifiedFilter: "7days")
        let second = SavedSearch(query: "图片", kind: "全部", extensionFilter: "jpg,png", matchPath: false,
                                 rootID: nil, sizeFilter: "", modifiedFilter: "")
        state.remember(first); state.remember(second); state.remember(first)
        state.bookmark(first); state.bookmark(first)
        state.previewVisible = true; state.save()
        let restored = SearchWorkspacePreferences(directory: directory)
        guard restored.history == [first, second], restored.saved == [first], restored.previewVisible else {
            throw EngineTestError.failed("收藏、历史条件或预览布局没有完整持久化")
        }
        try legacyRecovery(directory: directory.appendingPathComponent("旧版"))
        try editableBookmarks(directory: directory.appendingPathComponent("新版"))
        return ["status": "passed", "exactConditionsRestored": true, "historyDeduplicated": true,
            "bookmarkDeduplicated": true, "legacyJSONRecovery": true,
            "filterTreeRoundtrip": true, "semanticConditionDeduplication": true,
            "namedPinnedBookmarkPersistence": true, "conditionReplacementPersistence": true,
            "bookmarkRemovalPersistence": true]
    }

    private static func legacyRecovery(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // This is the actual previous schema: no id/name/pin/filter fields.
        let oldItem: [String: Any] = ["query": "旧合同", "kind": "文件", "extensionFilter": "pdf",
            "matchPath": true, "rootID": "owned-fixture", "sizeFilter": ">1kb", "modifiedFilter": "today"]
        let bytes = try JSONSerialization.data(withJSONObject:
            ["history": [oldItem], "saved": [oldItem], "previewVisible": true])
        try bytes.write(to: directory.appendingPathComponent("search-workspace-v2.json"))
        let recovered = SearchWorkspacePreferences(directory: directory)
        guard recovered.history.count == 1, recovered.saved.count == 1, recovered.previewVisible,
              let saved = recovered.saved.first, saved.query == "旧合同", saved.kind == "文件",
              saved.extensionFilter == "pdf", saved.rootID == "owned-fixture", saved.matchPath,
              saved.sizeFilter == ">1kb", saved.modifiedFilter == "today",
              saved.filters.isEmpty, saved.name.isEmpty, !saved.isPinned else {
            throw EngineTestError.failed("旧搜索 JSON 恢复时丢失原条件或没有正确补齐默认字段")
        }
        recovered.save()
        let reopened = SearchWorkspacePreferences(directory: directory)
        guard reopened.saved.first?.id == saved.id, reopened.saved.first?.query == saved.query else {
            throw EngineTestError.failed("迁移后的收藏标识或原条件没有保持")
        }
    }

    private static func editableBookmarks(directory: URL) throws {
        let preferences = SearchWorkspacePreferences(directory: directory)
        var nameRule = SearchConditionRule()
        nameRule.field = .name; nameRule.comparison = .notContains; nameRule.value = "草稿"
        var sizeRule = SearchConditionRule()
        sizeRule.field = .size; sizeRule.comparison = .range; sizeRule.value = "1kb"; sizeRule.upperValue = "5mb"
        var alternative = SearchConditionGroup()
        alternative.mode = .any; alternative.rules = [nameRule, sizeRule]
        var filters = SearchFilters()
        filters.category = .documents; filters.nameMode = .prefix; filters.nameValue = "合同"
        filters.includedPaths = ["/owned/甲", "/owned/乙"]
        filters.excludedPaths = ["/owned/甲/历史"]
        filters.includeSubfolders = false; filters.hidden = .visible; filters.connection = .online
        filters.createdFilter = "2026-10-01..2026-10-03"
        filters.conditionGroup.groups = [alternative]
        var saved = SavedSearch(query: "合同", kind: "文件", extensionFilter: "pdf,docx", matchPath: true,
            rootID: "owned-fixture", sizeFilter: ">=1kb", modifiedFilter: "7days")
        saved.filters = filters; saved.name = "本周合同"; saved.isPinned = true
        preferences.bookmark(saved); preferences.remember(saved)
        var equivalent = saved
        equivalent.id = UUID(); equivalent.name = "相同条件的其他名称"; equivalent.isPinned = false
        equivalent.filters.conditionGroup.id = UUID()
        equivalent.filters.conditionGroup.groups[0].id = UUID()
        for index in equivalent.filters.conditionGroup.groups[0].rules.indices {
            equivalent.filters.conditionGroup.groups[0].rules[index].id = UUID()
        }
        guard saved.sameConditions(as: equivalent) else {
            throw EngineTestError.failed("条件等价比较错误地依赖收藏或规则 UUID、名称、固定状态")
        }
        // An empty replacement label is a plain save of the same conditions;
        // explicit rename behavior is exercised separately below.
        var duplicate = equivalent; duplicate.name = ""
        preferences.bookmark(duplicate); preferences.remember(equivalent)
        guard preferences.saved.count == 1, preferences.history.count == 1 else {
            throw EngineTestError.failed("相同查询条件的收藏或历史没有去重")
        }
        let reopened = SearchWorkspacePreferences(directory: directory)
        guard reopened.saved == [saved], reopened.saved.first?.filters == filters,
              reopened.saved.first?.name == "本周合同", reopened.saved.first?.isPinned == true,
              reopened.saved.first?.filters.conditionGroup.groups.first?.rules.first?.id == nameRule.id else {
            throw EngineTestError.failed("新筛选树、规则标识、命名或固定状态没有完整 roundtrip")
        }
        guard reopened.renameSaved(id: saved.id, name: "已命名收藏"), reopened.togglePinned(id: saved.id) else {
            throw EngineTestError.failed("有效收藏无法命名或切换固定状态")
        }
        let renamed = SearchWorkspacePreferences(directory: directory)
        guard renamed.saved.first?.name == "已命名收藏", renamed.saved.first?.isPinned == false else {
            throw EngineTestError.failed("收藏命名或固定状态未立即持久化")
        }
        var replacement = equivalent
        replacement.query = "预算"; replacement.filters.category = .images
        guard renamed.updateSaved(id: saved.id, with: replacement) else {
            throw EngineTestError.failed("有效收藏无法更新条件")
        }
        let updated = SearchWorkspacePreferences(directory: directory)
        guard let newSaved = updated.saved.first, newSaved.id == saved.id, newSaved.query == "预算",
              newSaved.filters.category == .images, newSaved.name == "已命名收藏", !newSaved.isPinned else {
            throw EngineTestError.failed("更新收藏条件时丢失条件、原标识、名称或固定状态")
        }
        let unknown = UUID()
        guard !updated.renameSaved(id: unknown, name: "不存在"), !updated.togglePinned(id: unknown),
              !updated.updateSaved(id: unknown, with: replacement), !updated.removeSaved(id: unknown),
              updated.removeSaved(id: saved.id), SearchWorkspacePreferences(directory: directory).saved.isEmpty else {
            throw EngineTestError.failed("删除收藏未持久化或无效标识被错误接受")
        }
    }
}

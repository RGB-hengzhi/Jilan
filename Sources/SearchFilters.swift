// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

enum SearchFilterCategory: String, Codable, CaseIterable {
    case all = "全部", documents = "文档", images = "图片", videos = "视频", audio = "音频", archives = "压缩包", code = "代码"
    var extensions: Set<String> {
        switch self {
        case .all: return []
        case .documents: return ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "txt", "md", "pages", "numbers", "key", "epub", "csv"]
        case .images: return ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg", "ico", "avif", "raw", "dng", "psd"]
        case .videos: return ["mp4", "mov", "mkv", "avi", "wmv", "webm", "m4v", "mpeg", "mpg", "flv", "ts", "mts", "m2ts", "3gp"]
        case .audio: return ["mp3", "wav", "aac", "m4a", "flac", "ogg", "opus", "aiff", "aif", "alac", "wma", "mid", "midi"]
        case .archives: return ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "zst", "iso", "dmg"]
        case .code: return ["swift", "py", "js", "jsx", "ts", "tsx", "html", "css", "scss", "c", "h", "cpp", "hpp", "m", "mm", "java", "kt", "go", "rs", "rb", "php", "sh", "zsh", "bash", "sql", "json", "yaml", "yml", "xml", "toml", "vue", "svelte"]
        }
    }
}
enum SearchNameMode: String, Codable, CaseIterable {
    case contains = "包含", exact = "完全匹配", prefix = "开头", suffix = "结尾"
}
enum SearchHiddenFilter: String, Codable, CaseIterable {
    case all = "全部", visible = "仅可见", hidden = "仅隐藏"
}
enum SearchConnectionFilter: String, Codable, CaseIterable {
    case all = "全部", online = "已连接", offline = "离线"
}
enum SearchConditionMode: String, Codable, CaseIterable {
    case all = "全部满足", any = "任一满足"
}
enum SearchComparison: String, Codable, CaseIterable {
    case contains = "包含", notContains = "不包含", equal = "等于", notEqual = "不等于", prefix = "开头是", suffix = "结尾是"
    case greater = "大于", greaterEqual = "大于等于", less = "小于", lessEqual = "小于等于", range = "介于"
}
enum SearchConditionField: String, Codable, CaseIterable {
    case name = "名称", path = "路径", extensionName = "扩展名", size = "大小", modified = "修改日期", created = "创建日期"
    var comparisons: [SearchComparison] {
        switch self {
        case .name, .path, .extensionName: return [.contains, .notContains, .equal, .notEqual, .prefix, .suffix]
        case .size, .modified, .created: return [.equal, .notEqual, .greater, .greaterEqual, .less, .lessEqual, .range]
        }
    }
}
struct SearchConditionRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var field: SearchConditionField = .name
    var comparison: SearchComparison = .contains
    var value = ""
    var upperValue = ""
    var isEmpty: Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (comparison != .range || upperValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
struct SearchConditionGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var mode: SearchConditionMode = .all
    var rules: [SearchConditionRule] = []
    var groups: [SearchConditionGroup] = []
    var isEmpty: Bool { rules.allSatisfy(\.isEmpty) && groups.allSatisfy(\.isEmpty) }
}
struct SearchFilters: Codable, Equatable {
    var category: SearchFilterCategory = .all
    var nameMode: SearchNameMode = .contains
    var nameValue = ""
    var includedPaths: [String] = []
    var excludedPaths: [String] = []
    var includeSubfolders = true
    var hidden: SearchHiddenFilter = .all
    var connection: SearchConnectionFilter = .all
    var createdFilter = ""
    var conditionGroup = SearchConditionGroup()
    var isEmpty: Bool {
        category == .all && nameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && includedPaths.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && excludedPaths.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && hidden == .all && connection == .all && createdFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && conditionGroup.isEmpty
    }
    /// IDs and inactive editor defaults do not invalidate a completed query.
    var signature: String {
        guard !isEmpty else { return "" }
        func groupObject(_ group: SearchConditionGroup) -> [String: Any] {
            let rules = group.rules.filter { !$0.isEmpty }.map { rule in
                ["field": rule.field.rawValue, "comparison": rule.comparison.rawValue,
                 "value": rule.value.trimmingCharacters(in: .whitespacesAndNewlines),
                 "upper": rule.comparison == .range ? rule.upperValue.trimmingCharacters(in: .whitespacesAndNewlines) : ""]
            }
            return ["mode": group.mode.rawValue, "rules": rules,
                    "groups": group.groups.filter { !$0.isEmpty }.map(groupObject)]
        }
        let includes = includedPaths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(Self.normalizedPath)
        let excludes = excludedPaths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(Self.normalizedPath)
        let name = nameValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let object: [String: Any] = ["category": category.rawValue, "nameMode": name.isEmpty ? "" : nameMode.rawValue,
            "nameValue": name, "includedPaths": Array(Set(includes)).sorted(), "excludedPaths": Array(Set(excludes)).sorted(),
            "includeSubfolders": includes.isEmpty || includeSubfolders, "hidden": hidden.rawValue,
            "connection": connection.rawValue, "createdFilter": createdFilter.trimmingCharacters(in: .whitespacesAndNewlines),
            "conditionGroup": conditionGroup.isEmpty ? [:] : groupObject(conditionGroup)]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
    }
    static func == (lhs: SearchFilters, rhs: SearchFilters) -> Bool { lhs.signature == rhs.signature }
    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath).standardized.path
    }
    /// Match IndexStore.makeRoot's physical paths. Offline or inaccessible
    /// directories retain their lexical scope and remain recoverable.
    static func canonicalScopePath(_ path: String) -> String {
        let lexical = normalizedPath(path)
        guard let resolved = realpath(lexical, nil) else { return lexical }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Filename syntax is evaluated entirely in memory. Filesystem properties are
/// deliberately a separate, cancellable stage, never part of the index lock.
struct AdvancedSearchPlan {
    struct Term {
        var predicate: Predicate
        var negated: Bool
        func accepts(_ value: Bool) -> Bool { negated ? !value : value }
    }

    enum Predicate {
        case name(String, wildcard: Bool)
        case typedName(SearchKind, String, wildcard: Bool)
        case extensions(Set<String>)
        case size(NumberCondition)
        case modified(DateCondition)
        case created(DateCondition)
        case nameCondition(String, SearchComparison)
        case pathCondition(String, SearchComparison)
        case extensionCondition(String, SearchComparison)
        case visibility(SearchHiddenFilter)
    }

    indirect enum Expression {
        case term(Term), all([Expression]), any([Expression]), not(Expression)
        func evaluate(_ evaluateTerm: (Term) -> Bool?) -> Bool? {
            switch self {
            case .term(let term): return evaluateTerm(term)
            case .not(let child): return child.evaluate(evaluateTerm).map { !$0 }
            case .all(let children):
                var unknown = false
                for child in children {
                    if let value = child.evaluate(evaluateTerm) { if !value { return false } }
                    else { unknown = true }
                }
                return unknown ? nil : true
            case .any(let children):
                var unknown = false
                for child in children {
                    if let value = child.evaluate(evaluateTerm) { if value { return true } }
                    else { unknown = true }
                }
                return unknown ? nil : false
            }
        }
        var terms: [Term] {
            switch self {
            case .term(let term): return [term]
            case .all(let children), .any(let children): return children.flatMap(\.terms)
            case .not(let child): return child.terms
            }
        }
    }

    struct NumberCondition {
        enum Comparison { case equal, less, lessEqual, greater, greaterEqual, range }
        var comparison: Comparison
        var lower: Int64
        var upper: Int64? = nil
        func matches(_ number: Int64) -> Bool {
            switch comparison {
            case .equal: return number == lower
            case .less: return number < lower
            case .lessEqual: return number <= lower
            case .greater: return number > lower
            case .greaterEqual: return number >= lower
            case .range: return number >= lower && number <= (upper ?? lower)
            }
        }
    }

    struct DateCondition {
        var start: Date?
        var end: Date?
        var includeStart = true
        var includeEnd = false
        func matches(_ date: Date) -> Bool {
            if let start, includeStart ? date < start : date <= start { return false }
            if let end, includeEnd ? date > end : date >= end { return false }
            return true
        }
    }

    var branches: [[Term]] = [[]]
    var propertyControls: [Term] = []
    var error: String? = nil
    private var expression: Expression? = nil
    private var filterExpression: Expression? = nil
    private var includedPaths: [String] = []
    private var excludedPaths: [String] = []
    private var includeSubfolders = true
    private var hiddenFilter: SearchHiddenFilter = .all
    var hasStructuredExpression: Bool { expression != nil }
    var hasIndexedFilters: Bool { filterExpression != nil || !includedPaths.isEmpty || !excludedPaths.isEmpty || hiddenFilter != .all }
    var hasNonCategoryIndexedFilters: Bool {
        !includedPaths.isEmpty || !excludedPaths.isEmpty || hiddenFilter != .all
            || (filterExpression?.terms.contains { term in
                if case .extensions = term.predicate { return false }; return true
            } ?? false)
    }
    var usesHiddenMetadata: Bool { hiddenFilter != .all }

    var usesMetadata: Bool {
        ((expression?.terms ?? branches.flatMap { $0 }) + propertyControls + (filterExpression?.terms ?? [])).contains { term in
            switch term.predicate { case .size, .modified, .created, .visibility: return true; default: return false }
        }
    }

    /// The common case continues to use Cling's byte-array/SIMD search. A quoted
    /// phrase is one literal token, including its embedded spaces.
    var simpleLiteralTokens: [String]? {
        guard error == nil, expression == nil, branches.count == 1 else { return nil }
        var result: [String] = []
        for term in branches[0] {
            guard !term.negated else { return nil }
            switch term.predicate {
            case .name(let text, let wildcard):
                guard !wildcard else { return nil }; result.append(text)
            case .size, .modified, .created: continue // applied outside the index
            default: return nil
            }
        }
        return result
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().precomposedStringWithCanonicalMapping
    }

    static func parse(_ request: SearchRequest, now: Date = Date(), calendar: Calendar = .current) -> AdvancedSearchPlan {
        var plan = AdvancedSearchPlan()
        do {
            let tokens = try tokenize(request.query)
            var parser = ExpressionParser(tokens: tokens, now: now, calendar: calendar)
            let queryExpression = try parser.parse()
            if let flat = flatBranches(queryExpression) { plan.branches = flat }
            else { plan.expression = queryExpression }
            if !request.sizeFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plan.propertyControls.append(Term(predicate: .size(try parseNumberCondition(request.sizeFilter)), negated: false))
            }
            if !request.modifiedFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plan.propertyControls.append(Term(predicate: .modified(try parseDateCondition(request.modifiedFilter, now: now, calendar: calendar)), negated: false))
            }
            let filters = request.filters
            plan.includedPaths = try normalizedPaths(filters.includedPaths)
            plan.excludedPaths = try normalizedPaths(filters.excludedPaths)
            plan.includeSubfolders = filters.includeSubfolders
            plan.hiddenFilter = filters.hidden
            if filters.hidden != .all { plan.propertyControls.append(Term(predicate: .visibility(filters.hidden), negated: false)) }
            var controls: [Expression] = []
            if filters.category != .all { controls.append(.term(Term(predicate: .extensions(filters.category.extensions), negated: false))) }
            let nameValue = normalize(filters.nameValue.trimmingCharacters(in: .whitespacesAndNewlines))
            if !nameValue.isEmpty {
                let comparison: SearchComparison
                switch filters.nameMode { case .contains: comparison = .contains; case .exact: comparison = .equal; case .prefix: comparison = .prefix; case .suffix: comparison = .suffix }
                controls.append(.term(Term(predicate: .nameCondition(nameValue, comparison), negated: false)))
            }
            if !filters.createdFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plan.propertyControls.append(Term(predicate: .created(try parseDateCondition(filters.createdFilter, now: now, calendar: calendar)), negated: false))
            }
            var conditionCount = 0
            if let group = try compileGroup(filters.conditionGroup, depth: 0, count: &conditionCount, now: now, calendar: calendar) { controls.append(group) }
            if !controls.isEmpty { plan.filterExpression = .all(controls) }
        } catch { plan.error = (error as? ParseFailure)?.description ?? "高级搜索条件格式不正确。" }
        return plan
    }

    /// Each branch is AND, with OR between branches. Metadata terms are ignored
    /// only while gathering candidates; the second stage rechecks whole branches
    /// so `size:>1mb | ext:pdf` retains its correct boolean meaning.
    func matchesName(normalizedText: String, isDirectory: Bool, extensionValue: String) -> Bool {
        if let expression {
            return expression.evaluate { term in
                evaluateName(term.predicate, text: normalizedText, isDirectory: isDirectory, extensionValue: extensionValue).map(term.accepts)
            } != false
        }
        return branches.contains { branch in
            branch.allSatisfy { term in
                guard let result = evaluateName(term.predicate, text: normalizedText, isDirectory: isDirectory,
                                                extensionValue: extensionValue) else { return true }
                return term.accepts(result)
            }
        }
    }

    func matches(_ hit: FileHit, matchPath: Bool, size: Int64?, modified: Date?, created: Date? = nil, hidden: Bool? = nil) -> Bool? {
        guard allowsPath(hit.path) else { return false }
        let text = Self.normalize(matchPath ? hit.path : hit.name)
        let ext = Self.normalize((hit.name as NSString).pathExtension)
        func evaluate(_ term: Term) -> Bool? {
            if let named = evaluateName(term.predicate, text: text, isDirectory: hit.isDirectory, extensionValue: ext) {
                return term.accepts(named)
            }
            switch term.predicate {
            case .size(let condition):
                // A folder's stat size is not its recursive content size.
                guard !hit.isDirectory, let size else { return nil }
                return term.accepts(condition.matches(size))
            case .modified(let condition):
                guard let modified else { return nil }
                return term.accepts(condition.matches(modified))
            case .created(let condition):
                guard let created else { return nil }
                return term.accepts(condition.matches(created))
            case .nameCondition(let value, let comparison):
                return term.accepts(Self.compareText(Self.normalize(hit.name), value, comparison))
            case .pathCondition(let value, let comparison):
                return term.accepts(Self.compareText(Self.normalize(hit.path), value, comparison))
            case .extensionCondition(let value, let comparison):
                return term.accepts(!hit.isDirectory && Self.compareText(ext, value, comparison))
            case .visibility(let filter):
                let dotHidden = hit.path.split(separator: "/").contains { $0.hasPrefix(".") }
                guard let actualHidden = dotHidden ? true : hidden else { return nil }
                return term.accepts(filter == .all || (filter == .hidden) == actualHidden)
            default: return false
            }
        }
        let query = expression ?? .any(branches.map { .all($0.map { .term($0) }) })
        var conditions = [query] + propertyControls.map { Expression.term($0) }
        if let filterExpression { conditions.append(filterExpression) }
        return Expression.all(conditions).evaluate(evaluate)
    }

    /// Metadata is unknown in the index; only definite failures are excluded.
    func matchesCandidate(_ hit: FileHit, matchPath: Bool) -> Bool {
        matches(hit, matchPath: matchPath, size: nil, modified: nil, created: nil) != false
    }
    /// Used only after the query's compiled byte matcher accepted an entry.
    func matchesIndexedFilters(_ hit: FileHit, categoryPrechecked: Bool = false) -> Bool {
        guard allowsPath(hit.path) else { return false }
        guard let filterExpression else { return true }
        let name = Self.normalize(hit.name), path = Self.normalize(hit.path)
        let ext = Self.normalize((hit.name as NSString).pathExtension)
        return filterExpression.evaluate { term in
            let result: Bool?
            switch term.predicate {
            case .extensions where categoryPrechecked: result = true
            case .nameCondition(let value, let comparison): result = Self.compareText(name, value, comparison)
            case .pathCondition(let value, let comparison): result = Self.compareText(path, value, comparison)
            case .extensionCondition(let value, let comparison): result = !hit.isDirectory && Self.compareText(ext, value, comparison)
            default: result = evaluateName(term.predicate, text: name, isDirectory: hit.isDirectory, extensionValue: ext)
            }
            return result.map(term.accepts)
        } != false
    }
    private func allowsPath(_ path: String) -> Bool {
        if !includedPaths.isEmpty || !excludedPaths.isEmpty {
            let path = path.precomposedStringWithCanonicalMapping
            func below(_ directory: String) -> Bool { path == directory || path.hasPrefix(directory == "/" ? "/" : directory + "/") }
            if excludedPaths.contains(where: below) { return false }
            if !includedPaths.isEmpty {
                if includeSubfolders { if !includedPaths.contains(where: below) { return false } }
                else if !includedPaths.contains((path as NSString).deletingLastPathComponent) { return false }
            }
        }
        if hiddenFilter != .all {
            let hidden = path.split(separator: "/").contains { $0.hasPrefix(".") }
            if hiddenFilter == .visible && hidden { return false }
        }
        return true
    }

    /// Characters required by every OR branch provide a safe SIMD prefilter.
    /// Negative conditions never contribute to this mask.
    var requiredMask: UInt64 { expression.map(Self.mask) ?? branchMasks.reduce(UInt64.max, &) }
    var branchMasks: [UInt64] {
        branches.map { branch in
            branch.reduce(UInt64(0)) { mask, term in
                guard !term.negated else { return mask }
                switch term.predicate {
                case .name(let text, _), .typedName(_, let text, _):
                    return text.utf8.reduce(mask) { value, byte in
                        if byte >= 97 && byte <= 122 { return value | (1 << UInt64(byte - 97)) }
                        if byte >= 48 && byte <= 57 { return value | (1 << UInt64(26 + byte - 48)) }
                        if byte == 46 { return value | (1 << 36) }
                        if byte == 45 { return value | (1 << 37) }
                        if byte == 95 { return value | (1 << 38) }
                        return value
                    }
                default: return mask
                }
            }
        }
    }

    private func evaluateName(_ predicate: Predicate, text: String, isDirectory: Bool, extensionValue: String) -> Bool? {
        switch predicate {
        case .name(let value, let wildcard): return wildcard ? Self.wildcardMatches(value, text: text) : text.contains(value)
        case .typedName(let kind, let value, let wildcard):
            guard kind == (isDirectory ? .folders : .files) else { return false }
            return value.isEmpty || (wildcard ? Self.wildcardMatches(value, text: text) : text.contains(value))
        case .extensions(let values): return !isDirectory && values.contains(extensionValue)
        case .size, .modified, .created, .nameCondition, .pathCondition, .extensionCondition, .visibility: return nil
        }
    }

    /// Wildcards match the entire name/path. `?` consumes one Swift Character,
    /// rather than one UTF-8 byte, so Chinese and combining characters work.
    static func wildcardMatches(_ pattern: String, text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star: Int? = nil, afterStar = 0
        while ti < t.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == t[ti]) { pi += 1; ti += 1 }
            else if pi < p.count && p[pi] == "*" { star = pi; pi += 1; afterStar = ti }
            else if let position = star { afterStar += 1; ti = afterStar; pi = position + 1 }
            else { return false }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    private struct ParseFailure: Error, CustomStringConvertible { var description: String; init(_ text: String) { description = text } }
    private enum Token: Equatable { case term(String, literalLeadingBang: Bool, literalFieldPrefix: Bool), and, or, not, open, close }
    private static func tokenize(_ query: String) throws -> [Token] {
        guard query.utf8.count <= 8192 else { throw ParseFailure("搜索条件过长，请控制在8192字节内。") }
        var result: [Token] = [], current = "", quoted = false, escaping = false, tokenStarted = false, tokenQuoted = false, literalLeadingBang = false, literalFieldPrefix = false
        func flush() {
            guard tokenStarted else { return }
            if !tokenQuoted && current.uppercased() == "AND" { result.append(.and) }
            else if !tokenQuoted && (current.uppercased() == "OR" || current == "|") { result.append(.or) }
            else if !tokenQuoted && (current.uppercased() == "NOT" || current == "!") { result.append(.not) }
            else { result.append(.term(current, literalLeadingBang: literalLeadingBang, literalFieldPrefix: literalFieldPrefix)) }
            current = ""; tokenStarted = false; tokenQuoted = false; literalLeadingBang = false; literalFieldPrefix = false
        }
        for character in query {
            if escaping {
                if current.isEmpty && character == "!" { literalLeadingBang = quoted }
                if character == ":" && !current.contains(":") { literalFieldPrefix = quoted }
                current.append(character); escaping = false; tokenStarted = true; continue
            }
            if quoted && character == "\\" { escaping = true; continue }
            if character == "\"" { quoted.toggle(); tokenStarted = true; tokenQuoted = true; continue }
            if !quoted && (character.isWhitespace || "|()".contains(character)) {
                flush()
                if character == "|" { result.append(.or) }
                if character == "(" { result.append(.open) }
                if character == ")" { result.append(.close) }
            } else {
                if current.isEmpty && character == "!" { literalLeadingBang = quoted }
                if character == ":" && !current.contains(":") { literalFieldPrefix = quoted }
                current.append(character); tokenStarted = true
            }
        }
        if escaping { current.append("\\") }
        guard !quoted else { throw ParseFailure("引号尚未闭合，请补上右侧双引号。") }
        flush()
        guard result.count <= 256 else { throw ParseFailure("搜索条件过多，最多支持256个条件符号。") }
        return result
    }

    private struct ExpressionParser {
        var tokens: [Token]
        var now: Date
        var calendar: Calendar
        var position = 0
        mutating func parse() throws -> Expression {
            if tokens.isEmpty { return .all([]) }
            let result = try parseOr(depth: 0)
            guard position == tokens.count else { throw ParseFailure("括号或条件符号位置不正确。") }
            return result
        }
        mutating func parseOr(depth: Int) throws -> Expression {
            var children = [try parseAnd(depth: depth)]
            while position < tokens.count, tokens[position] == .or {
                position += 1; children.append(try parseAnd(depth: depth))
            }
            return children.count == 1 ? children[0] : .any(children)
        }
        mutating func parseAnd(depth: Int) throws -> Expression {
            var children = [try parseUnary(depth: depth)]
            while position < tokens.count {
                if tokens[position] == .or || tokens[position] == .close { break }
                if tokens[position] == .and { position += 1 }
                children.append(try parseUnary(depth: depth))
            }
            return children.count == 1 ? children[0] : .all(children)
        }
        mutating func parseUnary(depth: Int) throws -> Expression {
            guard depth <= 16 else { throw ParseFailure("条件括号最多嵌套16层。") }
            guard position < tokens.count else { throw ParseFailure("条件符号后面需要一个条件。") }
            let token = tokens[position]; position += 1
            switch token {
            case .term(let value, let literalLeadingBang, let literalFieldPrefix):
                return .term(try parseTerm(value, now: now, calendar: calendar, literalLeadingBang: literalLeadingBang, literalFieldPrefix: literalFieldPrefix))
            case .not: return .not(try parseUnary(depth: depth + 1))
            case .open:
                let result = try parseOr(depth: depth + 1)
                guard position < tokens.count, tokens[position] == .close else { throw ParseFailure("括号尚未闭合，请补上右括号。") }
                position += 1; return result
            default: throw ParseFailure("括号或条件符号两侧缺少条件。")
            }
        }
    }

    /// Keep the established compiled SIMD branch path whenever grouping can be
    /// flattened without distributing AND over OR or increasing expression size.
    private static func flatBranches(_ expression: Expression) -> [[Term]]? {
        func conjunction(_ value: Expression) -> [Term]? {
            switch value {
            case .term(let term): return [term]
            case .not(.term(var term)): term.negated.toggle(); return [term]
            case .all(let children):
                var terms: [Term] = []
                for child in children { guard let next = conjunction(child) else { return nil }; terms += next }
                return terms
            default: return nil
            }
        }
        if let terms = conjunction(expression) { return [terms] }
        if case .any(let children) = expression {
            var branches: [[Term]] = []
            for child in children { guard let next = flatBranches(child) else { return nil }; branches += next }
            return branches
        }
        return nil
    }
    private static func mask(_ expression: Expression) -> UInt64 {
        switch expression {
        case .term(let term):
            guard !term.negated else { return 0 }
            switch term.predicate {
            case .name(let text, _), .typedName(_, let text, _):
                return text.utf8.reduce(UInt64(0)) { value, byte in
                    if byte >= 97 && byte <= 122 { return value | (1 << UInt64(byte - 97)) }
                    if byte >= 48 && byte <= 57 { return value | (1 << UInt64(26 + byte - 48)) }
                    if byte == 46 { return value | (1 << 36) }
                    if byte == 45 { return value | (1 << 37) }
                    if byte == 95 { return value | (1 << 38) }
                    return value
                }
            default: return 0
            }
        case .not: return 0
        case .all(let children): return children.reduce(UInt64(0)) { $0 | mask($1) }
        case .any(let children): return children.reduce(UInt64.max) { $0 & mask($1) }
        }
    }
    private static func normalizedPaths(_ paths: [String]) throws -> [String] {
        guard paths.count <= 128 else { throw ParseFailure("包含或排除目录最多支持128个。") }
        return try Array(Set(paths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { path in
            let trimmed = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            guard trimmed.hasPrefix("/") else { throw ParseFailure("目录范围必须是完整路径：\(path)。") }
            return SearchFilters.canonicalScopePath(trimmed).precomposedStringWithCanonicalMapping
        })).sorted()
    }
    private static func compareText(_ text: String, _ value: String, _ comparison: SearchComparison) -> Bool {
        switch comparison {
        case .contains: return text.contains(value)
        case .notContains: return !text.contains(value)
        case .equal: return text == value
        case .notEqual: return text != value
        case .prefix: return text.hasPrefix(value)
        case .suffix: return text.hasSuffix(value)
        default: return false
        }
    }
    private static func compileGroup(_ group: SearchConditionGroup, depth: Int, count: inout Int,
                                     now: Date, calendar: Calendar) throws -> Expression? {
        guard depth <= 8 else { throw ParseFailure("可视化条件组最多嵌套8层。") }
        count += 1 + group.rules.count
        guard count <= 128 else { throw ParseFailure("可视化条件最多支持128个条件或分组。") }
        var children: [Expression] = []
        for rule in group.rules where !rule.isEmpty {
            guard rule.field.comparisons.contains(rule.comparison) else { throw ParseFailure("\(rule.field.rawValue)不支持\(rule.comparison.rawValue)。") }
            let value = normalize(rule.value.trimmingCharacters(in: .whitespacesAndNewlines))
            var negated = false
            let predicate: Predicate
            switch rule.field {
            case .name: predicate = .nameCondition(value, rule.comparison)
            case .path: predicate = .pathCondition(value, rule.comparison)
            case .extensionName: predicate = .extensionCondition(value.trimmingCharacters(in: CharacterSet(charactersIn: ".")), rule.comparison)
            case .size, .modified, .created:
                let text: String
                switch rule.comparison {
                case .range:
                    let upper = rule.upperValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !upper.isEmpty else { throw ParseFailure("“介于”条件需要填写上下限。") }
                    text = value + ".." + upper
                case .greater: text = ">" + value
                case .greaterEqual: text = ">=" + value
                case .less: text = "<" + value
                case .lessEqual: text = "<=" + value
                case .notEqual: text = rule.field == .size ? "=" + value : value; negated = true
                default: text = rule.field == .size ? "=" + value : value
                }
                if rule.field == .size { predicate = .size(try parseNumberCondition(text)) }
                else {
                    let date = try parseDateCondition(text, now: now, calendar: calendar)
                    predicate = rule.field == .created ? .created(date) : .modified(date)
                }
            }
            children.append(.term(Term(predicate: predicate, negated: negated)))
        }
        for subgroup in group.groups {
            if let compiled = try compileGroup(subgroup, depth: depth + 1, count: &count, now: now, calendar: calendar) { children.append(compiled) }
        }
        guard !children.isEmpty else { return nil }
        return group.mode == .all ? .all(children) : .any(children)
    }

    private static func parseTerm(_ raw: String, now: Date, calendar: Calendar, literalLeadingBang: Bool = false, literalFieldPrefix: Bool = false) throws -> Term {
        var text = raw, negated = false
        if !literalLeadingBang && text.hasPrefix("!") { negated = true; text.removeFirst() }
        guard !text.isEmpty else { throw ParseFailure("“!” 后面需要一个条件。") }
        let normalized = normalize(text)
        let parts = normalized.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let wildcard = normalized.contains("*") || normalized.contains("?")
        var predicate: Predicate = .name(normalized, wildcard: wildcard)
        if parts.count == 2 && !literalFieldPrefix {
            let value = String(parts[1])
            switch parts[0] {
            case "ext":
                let values = Set(value.split(whereSeparator: { $0.isWhitespace || ",;，；".contains($0) })
                    .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty })
                guard !values.isEmpty else { throw ParseFailure("ext: 后面需要扩展名，例如 ext:pdf,docx。") }
                predicate = .extensions(values)
            case "file", "folder": predicate = .typedName(parts[0] == "file" ? .files : .folders, value, wildcard: value.contains("*") || value.contains("?"))
            case "size": predicate = .size(try parseNumberCondition(value))
            case "dm", "modified", "date-modified": predicate = .modified(try parseDateCondition(value, now: now, calendar: calendar))
            case "dc", "created", "date-created": predicate = .created(try parseDateCondition(value, now: now, calendar: calendar))
            default: break // colons in an ordinary filename remain literal
            }
        }
        return Term(predicate: predicate, negated: negated)
    }

    private static func parseNumberCondition(_ raw: String) throws -> NumberCondition {
        let text = normalize(raw).filter { !$0.isWhitespace }
        if let range = text.range(of: "..") {
            let lower = try parseBytes(String(text[..<range.lowerBound]))
            let upper = try parseBytes(String(text[range.upperBound...]))
            guard lower <= upper else { throw ParseFailure("大小范围的起点不能大于终点。") }
            return NumberCondition(comparison: .range, lower: lower, upper: upper)
        }
        let operators: [(String, NumberCondition.Comparison)] = [(">=", .greaterEqual), ("<=", .lessEqual), (">", .greater), ("<", .less), ("=", .equal)]
        for (prefix, comparison) in operators where text.hasPrefix(prefix) {
            return NumberCondition(comparison: comparison, lower: try parseBytes(String(text.dropFirst(prefix.count))))
        }
        return NumberCondition(comparison: .equal, lower: try parseBytes(text))
    }

    private static func parseBytes(_ text: String) throws -> Int64 {
        let number = String(text.prefix { $0.isNumber || $0 == "." })
        let unit = String(text.dropFirst(number.count))
        let factors: [String: Double] = ["": 1, "b": 1, "k": 1e3, "kb": 1e3, "m": 1e6, "mb": 1e6, "g": 1e9, "gb": 1e9, "t": 1e12, "tb": 1e12, "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776]
        guard let value = Double(number), value.isFinite, value >= 0, let factor = factors[unit],
              value * factor < Double(Int64.max) else { throw ParseFailure("大小条件无效，例如 >100mb、1gb..5gb 或 <=512kib。") }
        return Int64((value * factor).rounded(.down))
    }

    private static func parseDateCondition(_ raw: String, now: Date, calendar: Calendar) throws -> DateCondition {
        let text = normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let today = calendar.startOfDay(for: now)
        func dayAfter(_ day: Date) -> Date { calendar.date(byAdding: .day, value: 1, to: day)! }
        if text == "today" || text == "今天" { return DateCondition(start: today, end: dayAfter(today)) }
        if text == "yesterday" || text == "昨天" {
            return DateCondition(start: calendar.date(byAdding: .day, value: -1, to: today)!, end: today)
        }
        if text.hasSuffix("days"), let days = Int(text.dropLast(4)), days > 0, days <= 365_000 {
            return DateCondition(start: calendar.date(byAdding: .day, value: -(days - 1), to: today)!, end: dayAfter(today))
        }
        func parseDay(_ value: String) throws -> Date {
            let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
            guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
                  let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
                throw ParseFailure("日期条件无效，例如 today、7days 或 2026-10-01..2026-10-03。")
            }
            let actual = calendar.dateComponents([.year, .month, .day], from: date)
            guard actual.year == year && actual.month == month && actual.day == day else { throw ParseFailure("日期不存在：\(value)。") }
            return date
        }
        if let range = text.range(of: "..") {
            let start = try parseDay(String(text[..<range.lowerBound]))
            let end = try parseDay(String(text[range.upperBound...]))
            guard start <= end else { throw ParseFailure("日期范围的起点不能晚于终点。") }
            return DateCondition(start: start, end: dayAfter(end))
        }
        for op in [">=", "<=", ">", "<", "="] where text.hasPrefix(op) {
            let day = try parseDay(String(text.dropFirst(op.count)))
            switch op {
            case ">=": return DateCondition(start: day, end: nil)
            case ">": return DateCondition(start: dayAfter(day), end: nil)
            case "<=": return DateCondition(start: nil, end: dayAfter(day))
            case "<": return DateCondition(start: nil, end: day)
            default: return DateCondition(start: day, end: dayAfter(day))
            }
        }
        let day = try parseDay(text)
        return DateCondition(start: day, end: dayAfter(day))
    }
}

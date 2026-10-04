// SPDX-License-Identifier: GPL-3.0-only
// Derived from FuzzyIdeas/Cling, Cling/SearchEngine.swift.
// Upstream commit: 60c3570e4d278ac4be519b9c72221dda784ad132.
// Reused: SIMD byte/character-mask search, parallel byte-array index, free-slot
// mutation, and binary array persistence design. Adapted for literal AND search,
// Unicode normalization, exact extension IDs, and checked atomic persistence.

import Foundation
import CryptoKit
import simd
import os.log
import Darwin

private let engineLog = Logger(subsystem: "local.rgb.QuickFind", category: "SearchEngine")

// Cling's SIMD helpers: vector-scan first byte, then verify the entire substring.
@inline(__always)
private func simdFindByte(_ base: UnsafePointer<UInt8>, count: Int, needle: UInt8, from: Int) -> Int {
    let needleVec = SIMD16<UInt8>(repeating: needle)
    var i = from
    while i &+ 16 <= count {
        let block = UnsafeRawPointer(base + i).loadUnaligned(as: SIMD16<UInt8>.self)
        let cmp = block .== needleVec
        var lane = 0
        while lane < 16 {
            if cmp[lane] { return i &+ lane }
            lane &+= 1
        }
        i &+= 16
    }
    while i < count {
        if base[i] == needle { return i }
        i &+= 1
    }
    return -1
}

@inline(__always)
private func simdContains(_ base: UnsafePointer<UInt8>, count: Int, needle: UnsafePointer<UInt8>, needleLen: Int) -> Bool {
    if needleLen == 0 { return true }
    if needleLen > count { return false }
    let first = needle[0]
    let limit = count &- needleLen
    var from = 0
    while from <= limit {
        let pos = simdFindByte(base, count: count, needle: first, from: from)
        if pos < 0 || pos > limit { return false }
        var j = 1
        var ok = true
        while j < needleLen {
            if base[pos &+ j] != needle[j] { ok = false; break }
            j &+= 1
        }
        if ok { return true }
        from = pos &+ 1
    }
    return false
}

// Adapted from Cling's simdFilterMasks: return every possible match, with no
// candidate cap. Literal verification below removes mask false positives.
private func simdFilterMasks(_ maskPtr: UnsafePointer<UInt64>, count: Int,
                             queryMask: UInt64, out: UnsafeMutablePointer<Int>) -> Int {
    var resultCount = 0
    let qm = SIMD8<UInt64>(repeating: queryMask)
    var i = 0
    while i &+ 8 <= count {
        let v = UnsafeRawPointer(maskPtr + i).loadUnaligned(as: SIMD8<UInt64>.self)
        let matches = (v & qm) .== qm
        var lane = 0
        while lane < 8 {
            if matches[lane] { out[resultCount] = i &+ lane; resultCount &+= 1 }
            lane &+= 1
        }
        i &+= 8
    }
    while i < count {
        if maskPtr[i] & queryMask == queryMask {
            out[resultCount] = i
            resultCount &+= 1
        }
        i &+= 1
    }
    return resultCount
}

@inline(__always)
private func characterMask(_ byte: UInt8) -> UInt64 {
    if byte >= 0x61, byte <= 0x7A { return 1 << UInt64(byte &- 0x61) }
    if byte >= 0x30, byte <= 0x39 { return 1 << UInt64(26 &+ byte &- 0x30) }
    if byte == 0x2E { return 1 << 36 }
    if byte == 0x2D { return 1 << 37 }
    if byte == 0x5F { return 1 << 38 }
    return 0
}

enum IndexPersistenceError: LocalizedError {
    case corrupt(String)
    case tooLarge
    var errorDescription: String? {
        switch self {
        case .corrupt(let detail): return "索引文件损坏或版本不兼容：\(detail)"
        case .tooLarge: return "索引超过当前二进制格式支持的大小。"
        }
    }
}

/// A local, synchronous, thread-safe index. Searches never access the filesystem.
/// The app owns scanning/FSEvents; this component only owns in-memory paths.
final class SearchEngine: @unchecked Sendable {
    private static let absent = UInt32.max
    // Names and their parent prefixes have separate arena slices. No entry or
    // membership key owns a full-path String. UInt32 bounds are checked before
    // append; the persisted v1 format retains its original UInt64 offsets.
    fileprivate struct Entry {
        var parent: UInt32
        var originalOffset: UInt32
        var originalLength: UInt32
        var normalizedOffset: UInt32
        var normalizedLength: UInt32
        var extensionID: UInt32
        var nextHash: UInt32
        var flags: UInt32
        var isLive: Bool { originalLength != 0 }
        var isDir: Bool { flags & 1 != 0 }
    }
    fileprivate struct Parent {
        var originalOffset: UInt32
        var originalLength: UInt32
        var normalizedOffset: UInt32
        var normalizedLength: UInt32
        var mask: UInt64
        var nextHash: UInt32
        var references: UInt32
    }
    private enum ByteNameMatcher {
        case literal([UInt8])
        case wildcardLiteral([UInt8], String)
        case prefixSuffix([UInt8], [UInt8], String)
        case extensionSuffix(UInt32?, [UInt8], String)
        case characters(String)

        @inline(__always)
        func matches(_ text: UnsafePointer<UInt8>, count: Int, extensionID: UInt32,
                     decodedText: inout String?) -> Bool {
            func hasPrefix(_ bytes: [UInt8]) -> Bool {
                guard bytes.count <= count else { return false }
                for i in bytes.indices where text[i] != bytes[i] { return false }
                return true
            }
            func hasSuffix(_ bytes: [UInt8]) -> Bool {
                guard bytes.count <= count else { return false }
                let start = count - bytes.count
                for i in bytes.indices where text[start + i] != bytes[i] { return false }
                return true
            }
            func confirmWildcard(_ accepted: Bool, pattern: String) -> Bool {
                guard accepted else { return false }
                if pattern == "*" { return true }
                // A byte prefix/suffix can cut a combining, regional-indicator
                // or ZWJ grapheme. Character wildcard semantics remain the
                // authority, even when the pattern itself is plain ASCII.
                if !UnsafeBufferPointer(start: text, count: count).contains(where: { $0 >= 0x80 }) { return true }
                if decodedText == nil { decodedText = String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self) }
                return AdvancedSearchPlan.wildcardMatches(pattern, text: decodedText!)
            }
            switch self {
            case .literal(let bytes):
                if bytes.isEmpty { return true }
                return bytes.withUnsafeBufferPointer { needle in
                    simdContains(text, count: count, needle: needle.baseAddress!, needleLen: needle.count)
                }
            case .wildcardLiteral(let bytes, let pattern):
                let accepted = bytes.isEmpty || bytes.withUnsafeBufferPointer { needle in
                    simdContains(text, count: count, needle: needle.baseAddress!, needleLen: needle.count)
                }
                return confirmWildcard(accepted, pattern: pattern)
            case .prefixSuffix(let prefix, let suffix, let pattern):
                return confirmWildcard(count >= prefix.count + suffix.count && hasPrefix(prefix) && hasSuffix(suffix), pattern: pattern)
            case .extensionSuffix(let wantedID, let suffix, let pattern):
                // *.pdf includes folders named folder.pdf, unlike ext:pdf.
                // A .pdf dotfile has no extension ID and needs a byte fallback.
                let accepted = extensionID != 0 ? wantedID == extensionID : hasSuffix(suffix)
                return confirmWildcard(accepted, pattern: pattern)
            case .characters(let pattern):
                if decodedText == nil { decodedText = String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self) }
                return AdvancedSearchPlan.wildcardMatches(pattern, text: decodedText!)
            }
        }
    }
    private struct CompiledNameTerm {
        enum Predicate { case name(ByteNameMatcher), typed(SearchKind, ByteNameMatcher), extensions(Set<UInt32>) }
        var predicate: Predicate
        var negated: Bool
        @inline(__always)
        func matches(_ text: UnsafePointer<UInt8>, count: Int, isDirectory: Bool, extensionID: UInt32,
                     decodedText: inout String?) -> Bool {
            let value: Bool
            switch predicate {
            case .name(let matcher): value = matcher.matches(text, count: count, extensionID: extensionID, decodedText: &decodedText)
            case .typed(let kind, let matcher):
                value = kind == (isDirectory ? .folders : .files) && matcher.matches(text, count: count, extensionID: extensionID, decodedText: &decodedText)
            case .extensions(let ids): value = !isDirectory && ids.contains(extensionID)
            }
            return negated ? !value : value
        }
    }

    private var entries: [Entry] = []
    private var parents: [Parent] = []
    private var masks: [UInt64] = []
    private var bnMasks: [UInt64] = []
    private var originalBytes: [UInt8] = []
    private var normalizedBytes: [UInt8] = []
    private var pathBuckets: [UInt64: UInt32] = [:]
    private var parentBuckets: [UInt64: UInt32] = [:]
    private var extToID: [String: UInt32] = [:]
    private var free: [Int] = []
    private var liveNameBytes = 0
    private var parentByteCount = 0
    private let lock = NSLock()
    private let pathHashBits: Int
    private let pathHashMask: UInt64
    /// Short hashes are a deterministic collision seam for isolated tests.
    /// Production always uses the default full 64-bit hash.
    init(pathHashBits: Int = 64) {
        self.pathHashBits = min(64, max(0, pathHashBits))
        pathHashMask = self.pathHashBits == 64 ? UInt64.max : (UInt64(1) << self.pathHashBits) - 1
    }

    fileprivate struct Snapshot {
        var entries: [Entry]
        var parents: [Parent]
        var masks: [UInt64]
        var bnMasks: [UInt64]
        var original: [UInt8]
        var normalized: [UInt8]
        var extensions: [String: UInt32]
        var pathBuckets: [UInt64: UInt32]
        var hashMask: UInt64
        var count: Int
        func path(_ entry: Entry) -> String {
            let parent = parents[Int(entry.parent)]
            let p = Int(parent.originalOffset), pl = Int(parent.originalLength)
            let n = Int(entry.originalOffset), nl = Int(entry.originalLength)
            // Only a matching hit or a path predicate needs the full path.
            var bytes = [UInt8]()
            bytes.reserveCapacity(pl + nl)
            bytes.append(contentsOf: original[p..<(p + pl)])
            bytes.append(contentsOf: original[n..<(n + nl)])
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private func snapshotUnlocked() -> Snapshot {
        Snapshot(entries: entries, parents: parents, masks: masks, bnMasks: bnMasks,
                 original: originalBytes, normalized: normalizedBytes,
                 extensions: extToID, pathBuckets: pathBuckets, hashMask: pathHashMask, count: entries.count - free.count)
    }
    var count: Int { lock.withLock { entries.count - free.count } }
    func hasPath(_ path: String) -> Bool { lock.withLock { findPathUnlocked(path) != nil } }
    func pathIsDirectory(_ path: String) -> Bool? {
        lock.withLock { findPathUnlocked(path).map { entries[$0].isDir } }
    }

    func forEachPath(_ visit: (String, Bool) -> Void) {
        _ = forEachPathWhile { path, isDir in visit(path, isDir); return true }
    }
    /// All arena slices and compact arrays belong to one CoW snapshot. No
    /// callbacks hold the engine lock; callbacks may query or mutate the engine.
    @discardableResult
    func forEachPathWhile(_ visit: (String, Bool) -> Bool) -> Bool {
        let snapshot = lock.withLock { snapshotUnlocked() }
        for entry in snapshot.entries where entry.isLive {
            if !visit(snapshot.path(entry), entry.isDir) { return false }
        }
        return true
    }
    func reserveCapacity(_ n: Int, avgPathLen: Int = 64) {
        guard n > 0, n < Int(UInt32.max), n <= Int.max / 32 else { return }
        lock.withLock {
            entries.reserveCapacity(n); masks.reserveCapacity(n); bnMasks.reserveCapacity(n)
            pathBuckets.reserveCapacity(n)
            parents.reserveCapacity(max(1, n / 8)); parentBuckets.reserveCapacity(max(1, n / 8))
            // Reserve basename/prefix arenas, never N copies of the full path.
            originalBytes.reserveCapacity(n * min(max(avgPathLen / 2, 8), 32))
            normalizedBytes.reserveCapacity(n * min(max(avgPathLen / 2, 8), 32))
        }
    }
    @discardableResult
    func addPath(_ path: String, isDir: Bool) -> Int {
        lock.withLock { addUnlocked(Self.trimTrailingSlash(path), isDir: isDir).id }
    }
    @discardableResult
    func addIfChanged(_ path: String, isDir: Bool) -> Bool {
        lock.withLock { addUnlocked(Self.trimTrailingSlash(path), isDir: isDir).changed }
    }
    @discardableResult
    func removeSubtree(_ path: String) -> Bool {
        let root = Self.trimTrailingSlash(path)
        guard !root.isEmpty else { return false }
        let prefix = root == "/" ? "/" : root + "/"
        return lock.withLock {
            let rootID = findPathUnlocked(root)
            if let id = rootID, !entries[id].isDir {
                removeIDUnlocked(id, hash: hashPath(root))
                if entries.count > 1024, free.count > entries.count / 3 { compactUnlocked() }
                return true
            }
            // Each parent prefix is shared by many entries. Check the parent
            // table once, rather than allocating a full path for every file on
            // every directory/unknown-path event. String.hasPrefix preserves
            // the existing canonical Unicode semantics and slash boundary.
            var affectedParents = Set<UInt32>()
            let prefixBytes = Array(prefix.utf8)
            if prefixBytes.allSatisfy({ $0 < 0x80 }) {
                // Most unrelated parents differ at an ASCII byte. Those need
                // no String allocation. A non-ASCII mismatch still uses Swift
                // equality: e.g. the Kelvin sign is canonically equal to K.
                originalBytes.withUnsafeBufferPointer { arena in
                    prefixBytes.withUnsafeBufferPointer { wanted in
                        for id in parents.indices where parents[id].references > 0 {
                            let parent = parents[id]
                            let start = Int(parent.originalOffset), length = Int(parent.originalLength)
                            let bytes = arena.baseAddress! + start
                            let exact = length >= wanted.count && memcmp(bytes, wanted.baseAddress!, wanted.count) == 0
                            var checkUnicode = exact && length > wanted.count && bytes[wanted.count] >= 0x80
                            if !exact {
                                for offset in 0..<min(length, wanted.count) where bytes[offset] != wanted[offset] {
                                    checkUnicode = bytes[offset] >= 0x80; break
                                }
                            }
                            let matches = checkUnicode
                                ? String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self).hasPrefix(prefix)
                                : exact
                            if matches {
                                affectedParents.insert(UInt32(id))
                            }
                        }
                    }
                }
            } else {
                for id in parents.indices where parents[id].references > 0 {
                    let parent = parents[id]
                    let start = Int(parent.originalOffset), length = Int(parent.originalLength)
                    let value = String(decoding: originalBytes[start..<(start + length)], as: UTF8.self)
                    if value.hasPrefix(prefix) { affectedParents.insert(UInt32(id)) }
                }
            }
            guard rootID != nil || !affectedParents.isEmpty else { return false }
            var removed = false
            if let id = rootID {
                removeIDUnlocked(id, hash: hashPath(root)); removed = true
            }
            if !affectedParents.isEmpty {
                for id in entries.indices where entries[id].isLive && affectedParents.contains(entries[id].parent) {
                    let candidate = pathUnlocked(entries[id])
                    removeIDUnlocked(id, hash: hashPath(candidate)); removed = true
                }
            }
            if removed, !entries.isEmpty, free.count > entries.count / 3 { compactUnlocked() }
            return removed
        }
    }

    /// A bounded cursor owns a consistent compact snapshot, never all FileHits.
    /// next/countCandidates and exclusion callbacks run outside the engine lock.
    final class QueryCursor {
        private let snapshot: Snapshot
        private let request: SearchRequest
        private let rootID: String
        private let excludeHit: ((String) -> Bool)?
        private let plan: AdvancedSearchPlan
        private let tokens: [[UInt8]]?
        private let queryMask: UInt64
        private let extensionIDs: Set<UInt32>
        private let categoryIDs: Set<UInt32>
        private let checksExtensions: Bool
        private let checksCategory: Bool
        private let branches: [(mask: UInt64, terms: [CompiledNameTerm])]
        private var position = 0
        private var disabled: Bool
        var scannedEntries: Int { position }
        var isComplete: Bool { disabled || position >= snapshot.entries.count || request.cancellation?.isCancelled == true }
        fileprivate init(snapshot: Snapshot, request: SearchRequest, rootID: String,
                         excludeHit: ((String) -> Bool)?) {
            self.snapshot = snapshot; self.request = request; self.rootID = rootID; self.excludeHit = excludeHit
            let plan = request.parsedPlan ?? AdvancedSearchPlan.parse(request)
            self.plan = plan
            tokens = plan.simpleLiteralTokens.map { $0.map { SearchEngine.searchBytes($0) }.filter { !$0.isEmpty } }
            queryMask = tokens.map { values in values.reduce(UInt64(0)) { m, b in b.reduce(m) { $0 | characterMask($1) } } } ?? plan.requiredMask
            let extensions = SearchEngine.extensionTokens(request.extensionFilter)
            extensionIDs = Set(extensions.compactMap { snapshot.extensions[$0] })
            let categoryExtensions = request.filters.category.extensions
            categoryIDs = Set(categoryExtensions.compactMap { snapshot.extensions[$0] })
            checksExtensions = !extensions.isEmpty; checksCategory = !categoryExtensions.isEmpty
            disabled = plan.error != nil || (request.rootID != nil && request.rootID != rootID)
                || (!extensions.isEmpty && extensionIDs.isEmpty)
                || (!categoryExtensions.isEmpty && categoryIDs.isEmpty)
            let branchMasks = plan.branchMasks
            branches = plan.branches.enumerated().map { number, branch in
                (branchMasks[number], branch.compactMap { term -> CompiledNameTerm? in
                    let predicate: CompiledNameTerm.Predicate
                    switch term.predicate {
                    case .name(let text, let wildcard): predicate = .name(SearchEngine.compileName(text, wildcard: wildcard, extensions: snapshot.extensions))
                    case .typedName(let kind, let text, let wildcard): predicate = .typed(kind, SearchEngine.compileName(text, wildcard: wildcard, extensions: snapshot.extensions))
                    case .extensions(let values): predicate = .extensions(Set(values.compactMap { snapshot.extensions[$0] }))
                    case .size, .modified, .created, .nameCondition, .pathCondition, .extensionCondition, .visibility: return nil
                    }
                    return CompiledNameTerm(predicate: predicate, negated: term.negated)
                })
            }
        }
        func hasPath(_ path: String) -> Bool {
            var id = snapshot.pathBuckets[SearchEngine.pathHash(path) & snapshot.hashMask] ?? SearchEngine.absent
            while id != SearchEngine.absent {
                let entry = snapshot.entries[Int(id)]
                if SearchEngine.pathEquals(path, entry: entry, parent: snapshot.parents[Int(entry.parent)], original: snapshot.original) { return true }
                id = entry.nextHash
            }
            return false
        }
        func next(maximum: Int = 2000) -> [FileHit] {
            guard maximum > 0 else { return [] }
            return scan(maximum: min(maximum, 2000), countToEnd: false).hits
        }
        /// Counts on this exact snapshot without advancing next or building hits.
        func countCandidates() -> Int {
            var countedRequest = request
            countedRequest.parsedPlan = plan // Keep the captured scope/clock interpretation too.
            let copy = QueryCursor(snapshot: snapshot, request: countedRequest, rootID: rootID, excludeHit: excludeHit)
            return copy.scan(maximum: 0, countToEnd: true).totalMatches
        }
        fileprivate func scan(maximum: Int, countToEnd: Bool) -> EngineQueryResult {
            guard !isComplete else { return EngineQueryResult(hits: [], totalMatches: 0) }
            var scanPosition = position
            let maximum = max(0, maximum)
            var hits: [FileHit] = [], total = 0
            hits.reserveCapacity(min(maximum, min(snapshot.count, 2000)))
            let searchMasks = request.matchPath ? snapshot.masks : snapshot.bnMasks
            SearchEngine.withTokenPointers(tokens ?? []) { tokenBuffers in
                snapshot.normalized.withUnsafeBufferPointer { bytes in
                    searchMasks.withUnsafeBufferPointer { masks in
                        guard let base = bytes.baseAddress, let maskBase = masks.baseAddress else { scanPosition = snapshot.entries.count; return }
                        var blockStart = -1, blockBits: UInt8 = 0
                        while scanPosition < snapshot.entries.count {
                            if scanPosition & 255 == 0, request.cancellation?.isCancelled == true { break }
                            let id = scanPosition; scanPosition += 1
                            if queryMask != 0 {
                                let start = id & ~7
                                if blockStart != start {
                                    blockStart = start; blockBits = 0
                                    if start + 8 <= masks.count {
                                        let vector = UnsafeRawPointer(maskBase + start).loadUnaligned(as: SIMD8<UInt64>.self)
                                        let matches = (vector & SIMD8<UInt64>(repeating: queryMask)) .== SIMD8<UInt64>(repeating: queryMask)
                                        for lane in 0..<8 where matches[lane] { blockBits |= UInt8(1 << lane) }
                                    } else {
                                        for i in start..<masks.count where maskBase[i] & queryMask == queryMask { blockBits |= UInt8(1 << (i - start)) }
                                    }
                                }
                                if blockBits == 0 { scanPosition = min(blockStart + 8, snapshot.entries.count); continue }
                                if blockBits & UInt8(1 << (id & 7)) == 0 { continue }
                            }
                            let entry = snapshot.entries[id]
                            guard entry.isLive else { continue }
                            if request.kind == .files, entry.isDir { continue }
                            if request.kind == .folders, !entry.isDir { continue }
                            if checksExtensions, entry.isDir || !extensionIDs.contains(entry.extensionID) { continue }
                            if checksCategory, entry.isDir || !categoryIDs.contains(entry.extensionID) { continue }
                            let parent = snapshot.parents[Int(entry.parent)]
                            let text = base + Int(entry.normalizedOffset), length = Int(entry.normalizedLength)
                            var path: String? = nil
                            func actualPath() -> String {
                                if path == nil { path = snapshot.path(entry) }; return path!
                            }
                            let matches: Bool
                            if let _ = tokens {
                                matches = tokenBuffers.allSatisfy { needle in
                                    if request.matchPath {
                                        return SearchEngine.segmentedContains(base + Int(parent.normalizedOffset), parentCount: Int(parent.normalizedLength),
                                                                             name: text, nameCount: length, needle: needle.baseAddress!, needleCount: needle.count)
                                    }
                                    return simdContains(text, count: length, needle: needle.baseAddress!, needleLen: needle.count)
                                }
                            } else if plan.hasStructuredExpression {
                                matches = plan.matchesCandidate(FileHit(path: actualPath(), isDirectory: entry.isDir, rootID: rootID), matchPath: request.matchPath)
                            } else {
                                func matchesBranches(_ text: UnsafePointer<UInt8>, _ length: Int) -> Bool {
                                    var decoded: String? = nil
                                    for branch in branches where maskBase[id] & branch.mask == branch.mask {
                                        if branch.terms.allSatisfy({ $0.matches(text, count: length, isDirectory: entry.isDir, extensionID: entry.extensionID, decodedText: &decoded) }) { return true }
                                    }
                                    return false
                                }
                                if request.matchPath {
                                    var joined: [UInt8] = []
                                    joined.reserveCapacity(Int(parent.normalizedLength) + length)
                                    joined.append(contentsOf: snapshot.normalized[Int(parent.normalizedOffset)..<(Int(parent.normalizedOffset) + Int(parent.normalizedLength))])
                                    joined.append(contentsOf: snapshot.normalized[Int(entry.normalizedOffset)..<(Int(entry.normalizedOffset) + length)])
                                    matches = joined.withUnsafeBufferPointer { matchesBranches($0.baseAddress!, $0.count) }
                                } else { matches = matchesBranches(text, length) }
                            }
                            guard matches else { continue }
                            if plan.hasNonCategoryIndexedFilters,
                               !plan.matchesIndexedFilters(FileHit(path: actualPath(), isDirectory: entry.isDir, rootID: rootID), categoryPrechecked: true) { continue }
                            if let excludeHit, excludeHit(actualPath()) { continue }
                            // Re-entry/exclusion may itself have cancelled.
                            if request.cancellation?.isCancelled == true { break }
                            total += 1
                            if hits.count < maximum { hits.append(FileHit(path: actualPath(), isDirectory: entry.isDir, rootID: rootID)) }
                            if !countToEnd && hits.count >= maximum { break }
                        }
                    }
                }
            }
            position = scanPosition
            return EngineQueryResult(hits: hits, totalMatches: total)
        }
    }
    func makeQueryCursor(_ request: SearchRequest, rootID: String, excludeHit: ((String) -> Bool)? = nil) -> QueryCursor {
        let snapshot = lock.withLock { snapshotUnlocked() }
        return QueryCursor(snapshot: snapshot, request: request, rootID: rootID, excludeHit: excludeHit)
    }
    func literalQuery(_ request: SearchRequest, rootID: String, limit: Int,
                      excludeHit: ((String) -> Bool)? = nil) -> EngineQueryResult {
        makeQueryCursor(request, rootID: rootID, excludeHit: excludeHit).scan(maximum: max(0, limit), countToEnd: true)
    }

    @inline(__always)
    private static func segmentedContains(_ parent: UnsafePointer<UInt8>, parentCount: Int,
                                          name: UnsafePointer<UInt8>, nameCount: Int,
                                          needle: UnsafePointer<UInt8>, needleCount: Int) -> Bool {
        if simdContains(parent, count: parentCount, needle: needle, needleLen: needleCount)
            || simdContains(name, count: nameCount, needle: needle, needleLen: needleCount) { return true }
        guard needleCount > 1, needleCount <= parentCount + nameCount else { return false }
        // Check only substrings crossing the prefix/name boundary. Full path
        // literals retain contiguous semantics without allocating joined bytes.
        let start = max(0, parentCount - needleCount + 1)
        for offset in start..<parentCount where offset + needleCount > parentCount && offset + needleCount <= parentCount + nameCount {
            var accepted = true
            for j in 0..<needleCount {
                let at = offset + j
                if (at < parentCount ? parent[at] : name[at - parentCount]) != needle[j] { accepted = false; break }
            }
            if accepted { return true }
        }
        return false
    }
    private static func compileName(_ text: String, wildcard: Bool, extensions: [String: UInt32]) -> ByteNameMatcher {
        guard wildcard else { return .literal(Array(text.utf8)) }
        let starCount = text.reduce(0) { $1 == "*" ? $0 + 1 : $0 }
        if !text.contains("?"), starCount == 1, let star = text.firstIndex(of: "*") {
            let prefix = String(text[..<star]), suffix = String(text[text.index(after: star)...])
            if prefix.isEmpty, suffix.hasPrefix("."), suffix.count > 1, !suffix.dropFirst().contains("."), !suffix.contains("/") {
                return .extensionSuffix(extensions[String(suffix.dropFirst())], Array(suffix.utf8), text)
            }
            return .prefixSuffix(Array(prefix.utf8), Array(suffix.utf8), text)
        }
        if !text.contains("?"), starCount == 2, text.hasPrefix("*"), text.hasSuffix("*") { return .wildcardLiteral(Array(text.dropFirst().dropLast().utf8), text) }
        return .characters(text)
    }

    private static let binaryMagic = Array("QFINDIX1".utf8)
    private static let binaryHeaderSize = 32
    private static let binaryBytesPerEntry = 33
    // The on-disk v1 format is unchanged. Encode one column at a time with a
    // bounded buffer and incremental SHA; no N-entry ID list or full Data copy.
    func saveBinaryIndex(to url: URL) throws {
        let snapshot = lock.withLock { snapshotUnlocked() }
        var normalizedCount = 0, originalCount = 0
        for entry in snapshot.entries where entry.isLive {
            let parent = snapshot.parents[Int(entry.parent)]
            let normalizedLength = Int(parent.normalizedLength) + Int(entry.normalizedLength)
            let originalLength = Int(parent.originalLength) + Int(entry.originalLength)
            guard normalizedLength <= Int(UInt32.max), normalizedLength <= Int.max - normalizedCount,
                  originalLength < Int.max - originalCount - 1 else { throw IndexPersistenceError.tooLarge }
            normalizedCount += normalizedLength; originalCount += originalLength + 1
        }
        guard snapshot.count <= (Int.max - 64) / Self.binaryBytesPerEntry,
              normalizedCount <= Int.max - 64 - snapshot.count * Self.binaryBytesPerEntry,
              originalCount <= Int.max - 64 - snapshot.count * Self.binaryBytesPerEntry - normalizedCount else { throw IndexPersistenceError.tooLarge }
        let writer = try BinaryWriter(destination: url)
        try writer.append(Self.binaryMagic)
        try writer.append64(UInt64(snapshot.count)); try writer.append64(UInt64(normalizedCount)); try writer.append64(UInt64(originalCount))
        for id in snapshot.entries.indices where snapshot.entries[id].isLive { try writer.append64(snapshot.masks[id]) }
        for id in snapshot.entries.indices where snapshot.entries[id].isLive { try writer.append64(snapshot.bnMasks[id]) }
        var offset = 0
        for entry in snapshot.entries where entry.isLive {
            try writer.append64(UInt64(offset)); offset += Int(snapshot.parents[Int(entry.parent)].normalizedLength) + Int(entry.normalizedLength)
        }
        for entry in snapshot.entries where entry.isLive { try writer.append32(snapshot.parents[Int(entry.parent)].normalizedLength + entry.normalizedLength) }
        for entry in snapshot.entries where entry.isLive { try writer.append32(snapshot.parents[Int(entry.parent)].normalizedLength) }
        for entry in snapshot.entries where entry.isLive { try writer.appendByte(entry.isDir ? 1 : 0) }
        for entry in snapshot.entries where entry.isLive {
            let parent = snapshot.parents[Int(entry.parent)]
            try writer.append(snapshot.normalized[Int(parent.normalizedOffset)..<(Int(parent.normalizedOffset) + Int(parent.normalizedLength))])
            try writer.append(snapshot.normalized[Int(entry.normalizedOffset)..<(Int(entry.normalizedOffset) + Int(entry.normalizedLength))])
        }
        for entry in snapshot.entries where entry.isLive {
            let parent = snapshot.parents[Int(entry.parent)]
            try writer.append(snapshot.original[Int(parent.originalOffset)..<(Int(parent.originalOffset) + Int(parent.originalLength))])
            try writer.append(snapshot.original[Int(entry.originalOffset)..<(Int(entry.originalOffset) + Int(entry.originalLength))])
            try writer.appendByte(0)
        }
        try writer.finish()
    }
    private final class BinaryWriter {
        private let destination: URL, temporary: URL
        private var descriptor: Int32
        private var buffer = [UInt8]()
        private var hash = SHA256()
        init(destination: URL) throws {
            self.destination = destination
            temporary = destination.deletingLastPathComponent().appendingPathComponent(".qfi-" + UUID().uuidString + ".tmp")
            descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600)) }
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            buffer.reserveCapacity(1_048_576)
        }
        deinit { if descriptor >= 0 { Darwin.close(descriptor) }; try? FileManager.default.removeItem(at: temporary) }
        func appendByte(_ byte: UInt8) throws { buffer.append(byte); if buffer.count >= 1_048_576 { try flush() } }
        func append64(_ value: UInt64) throws { var value = value.littleEndian; try withUnsafeBytes(of: &value) { try append($0) } }
        func append32(_ value: UInt32) throws { var value = value.littleEndian; try withUnsafeBytes(of: &value) { try append($0) } }
        func append<C: RandomAccessCollection>(_ bytes: C) throws where C.Element == UInt8 {
            var start = bytes.startIndex
            while start != bytes.endIndex {
                let length = min(1_048_576 - buffer.count, bytes.distance(from: start, to: bytes.endIndex))
                let end = bytes.index(start, offsetBy: length)
                buffer.append(contentsOf: bytes[start..<end])
                start = end
                if buffer.count >= 1_048_576 { try flush() }
            }
        }
        private func write(_ bytes: UnsafeRawBufferPointer) throws {
            var sent = 0
            while sent < bytes.count {
                let result = Darwin.write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                sent += result
            }
        }
        private func flush() throws {
            guard !buffer.isEmpty else { return }
            let data = Data(buffer); hash.update(data: data)
            try data.withUnsafeBytes { try write($0) }
            buffer.removeAll(keepingCapacity: true)
        }
        func finish() throws {
            try flush()
            let digest = Array(hash.finalize())
            try digest.withUnsafeBytes { try write($0) }
            guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let fd = descriptor; descriptor = -1
            guard Darwin.close(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let result = temporary.path.withCString { source in destination.path.withCString { Darwin.rename(source, $0) } }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
    static func loadBinaryIndex(from url: URL) throws -> SearchEngine {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= binaryHeaderSize + 32 else { throw IndexPersistenceError.corrupt("文件过短") }
        let payloadSize = data.count - 32
        guard data.prefix(8).elementsEqual(binaryMagic) else { throw IndexPersistenceError.corrupt("格式标识错误") }
        guard data.suffix(32).elementsEqual(SHA256.hash(data: data.prefix(payloadSize))) else { throw IndexPersistenceError.corrupt("完整性校验失败") }
        let engine = SearchEngine()
        try data.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            func read64(_ at: Int) -> UInt64 { UInt64(littleEndian: base.loadUnaligned(fromByteOffset: at, as: UInt64.self)) }
            func read32(_ at: Int) -> UInt32 { UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
            let rawN = read64(8), rawBytes = read64(16), rawPaths = read64(24)
            guard rawN <= UInt64(payloadSize / (binaryBytesPerEntry + 1)), rawN < UInt64(UInt32.max),
                  rawBytes <= UInt64(payloadSize), rawPaths <= UInt64(payloadSize) else { throw IndexPersistenceError.corrupt("头部数量超出文件大小") }
            let n = Int(rawN), byteCount = Int(rawBytes), pathCount = Int(rawPaths)
            let fixedEnd = binaryHeaderSize + n * binaryBytesPerEntry
            guard fixedEnd <= payloadSize, byteCount <= payloadSize - fixedEnd,
                  pathCount == payloadSize - fixedEnd - byteCount else { throw IndexPersistenceError.corrupt("数组长度不匹配") }
            let maskAt = 32, bnMaskAt = maskAt + n * 8, offsetAt = bnMaskAt + n * 8
            let lengthAt = offsetAt + n * 8, basenameAt = lengthAt + n * 4, dirAt = basenameAt + n * 4
            let normalizedBase = (base + fixedEnd).assumingMemoryBound(to: UInt8.self)
            let originalBase = normalizedBase + byteCount
            engine.reserveCapacity(n)
            var pathOffset = 0, expectedNormalizedOffset = 0
            for id in 0..<n {
                let normalizedOffset = read64(offsetAt + id * 8), normalizedLength = Int(read32(lengthAt + id * 4))
                let basenameStart = Int(read32(basenameAt + id * 4)), flag = base.load(fromByteOffset: dirAt + id, as: UInt8.self)
                guard normalizedOffset <= UInt64(byteCount), normalizedLength > 0,
                      normalizedLength <= byteCount - Int(normalizedOffset), basenameStart < normalizedLength,
                      flag <= 1 else { throw IndexPersistenceError.corrupt("条目字节区域或目录标志错误") }
                // Preserve v1's strict contiguous offsets, rejecting overlap,
                // gaps and reordered regions even with a recomputed checksum.
                guard normalizedOffset == UInt64(expectedNormalizedOffset) else { throw IndexPersistenceError.corrupt("字节偏移不连续") }
                expectedNormalizedOffset += normalizedLength
                guard expectedNormalizedOffset <= byteCount else { throw IndexPersistenceError.corrupt("字节区域长度不匹配") }
                var length = 0
                while pathOffset + length < pathCount, originalBase[pathOffset + length] != 0 { length += 1 }
                guard length > 0, pathOffset + length < pathCount,
                      let path = String(bytes: UnsafeBufferPointer(start: originalBase + pathOffset, count: length), encoding: .utf8) else { throw IndexPersistenceError.corrupt("路径字符串无效") }
                let norm = normalizedBase + Int(normalizedOffset)
                var originalStart = length
                while originalStart > 0, originalBase[pathOffset + originalStart - 1] != 0x2F { originalStart -= 1 }
                if originalStart == length { originalStart = 0 } // root /
                guard (basenameStart == 0) == (originalStart == 0), basenameStart == 0 || norm[basenameStart - 1] == 0x2F,
                      !UnsafeBufferPointer(start: norm + basenameStart, count: normalizedLength - basenameStart).contains(0x2F) || path == "/" else {
                    throw IndexPersistenceError.corrupt("名称边界错误")
                }
                let pathHash = Self.pathHash(path)
                guard engine.findPathUnlocked(path, hash: pathHash) == nil else { throw IndexPersistenceError.corrupt("路径字符串重复") }
                let parentID = try engine.internParent(original: UnsafeBufferPointer(start: originalBase + pathOffset, count: originalStart),
                                                       normalized: UnsafeBufferPointer(start: norm, count: basenameStart))
                let originalName = UnsafeBufferPointer(start: originalBase + pathOffset + originalStart, count: length - originalStart)
                let normalizedName = UnsafeBufferPointer(start: norm + basenameStart, count: normalizedLength - basenameStart)
                guard engine.canAppend(originalCount: originalName.count, normalizedCount: normalizedName.count) else { throw IndexPersistenceError.tooLarge }
                let entry = Entry(parent: parentID, originalOffset: UInt32(engine.originalBytes.count), originalLength: UInt32(originalName.count),
                                  normalizedOffset: UInt32(engine.normalizedBytes.count), normalizedLength: UInt32(normalizedName.count),
                                  extensionID: engine.extensionID(normalizedName), nextHash: engine.pathBuckets[pathHash] ?? Self.absent, flags: UInt32(flag))
                engine.originalBytes.append(contentsOf: originalName); engine.normalizedBytes.append(contentsOf: normalizedName)
                engine.liveNameBytes += originalName.count + normalizedName.count
                engine.retainParent(parentID)
                engine.entries.append(entry); engine.masks.append(read64(maskAt + id * 8)); engine.bnMasks.append(read64(bnMaskAt + id * 8))
                engine.pathBuckets[pathHash] = UInt32(id)
                pathOffset += length + 1
            }
            guard pathOffset == pathCount, expectedNormalizedOffset == byteCount else { throw IndexPersistenceError.corrupt("路径数据或字节区域有多余内容") }
        }
        return engine
    }

    private static func trimTrailingSlash(_ path: String) -> String {
        var value = path
        while value.hasSuffix("/"), value != "/" { value.removeLast() }
        return value
    }
    private static func searchBytes(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        if !bytes.contains(where: { $0 >= 0x80 }) { return bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 &+ 32 : $0 } }
        return Array(text.lowercased().precomposedStringWithCanonicalMapping.utf8)
    }
    private static func extensionTokens(_ filter: String) -> Set<String> {
        Set(filter.split(whereSeparator: { $0.isWhitespace || ",;|，；".contains($0) }).compactMap { part in
            var value = String(decoding: searchBytes(String(part)), as: UTF8.self)
            if value.hasPrefix("*.") { value.removeFirst(2) }
            while value.hasPrefix(".") { value.removeFirst() }
            return value.isEmpty ? nil : value
        })
    }
    private static func withTokenPointers(_ tokens: [[UInt8]], _ body: ([UnsafeBufferPointer<UInt8>]) -> Void) {
        let allocations: [UnsafeMutablePointer<UInt8>] = tokens.map { token in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: token.count)
            token.withUnsafeBufferPointer { pointer.initialize(from: $0.baseAddress!, count: token.count) }
            return pointer
        }
        defer { for pointer in allocations { pointer.deallocate() } }
        body(zip(allocations, tokens).map { UnsafeBufferPointer(start: $0.0, count: $0.1.count) })
    }
    private static func byteHash<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        var hash: UInt64 = 14695981039346656037
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return hash
    }
    private static func pathHash(_ path: String) -> UInt64 {
        // Swift String dictionary equality is canonically equivalent Unicode.
        // Hash NFC, retain exact original spelling in the arenas, and verify
        // every hash-bucket candidate by the full original String equality.
        if path.utf8.contains(where: { $0 >= 0x80 }) { return byteHash(path.precomposedStringWithCanonicalMapping.utf8) }
        return byteHash(path.utf8)
    }
    private func hashPath(_ path: String) -> UInt64 { Self.pathHash(path) & pathHashMask }
    private func findPathUnlocked(_ path: String, hash: UInt64? = nil) -> Int? {
        var id = pathBuckets[hash ?? hashPath(path)] ?? Self.absent
        while id != Self.absent {
            let entry = entries[Int(id)]
            if Self.pathEquals(path, entry: entry, parent: parents[Int(entry.parent)], original: originalBytes) { return Int(id) }
            id = entry.nextHash
        }
        return nil
    }
    private static func pathEquals(_ path: String, entry: Entry, parent: Parent, original: [UInt8]) -> Bool {
        let pl = Int(parent.originalLength), nl = Int(entry.originalLength)
        var input = path
        let exact = input.withUTF8 { bytes in
            guard bytes.count == pl + nl else { return false }
            return original.withUnsafeBufferPointer { arena in
                let prefixEqual = pl == 0 || memcmp(bytes.baseAddress!, arena.baseAddress! + Int(parent.originalOffset), pl) == 0
                return prefixEqual && memcmp(bytes.baseAddress! + pl, arena.baseAddress! + Int(entry.originalOffset), nl) == 0
            }
        }
        if exact { return true }
        // A true hash collision or a different NFC/NFD spelling still needs
        // canonical String equality, never an unchecked hash-only acceptance.
        let prefix = original[Int(parent.originalOffset)..<(Int(parent.originalOffset) + pl)]
        let name = original[Int(entry.originalOffset)..<(Int(entry.originalOffset) + nl)]
        return String(decoding: prefix, as: UTF8.self) + String(decoding: name, as: UTF8.self) == path
    }
    private func pathUnlocked(_ entry: Entry) -> String {
        let parent = parents[Int(entry.parent)]
        let p = Int(parent.originalOffset), pl = Int(parent.originalLength)
        let n = Int(entry.originalOffset), nl = Int(entry.originalLength)
        return String(decoding: originalBytes[p..<(p + pl)], as: UTF8.self) + String(decoding: originalBytes[n..<(n + nl)], as: UTF8.self)
    }
    private func canAppend(originalCount: Int, normalizedCount: Int) -> Bool {
        originalCount > -1 && normalizedCount > -1 && originalCount <= Int(UInt32.max) - originalBytes.count
            && normalizedCount <= Int(UInt32.max) - normalizedBytes.count
    }
    private func internParent(original: UnsafeBufferPointer<UInt8>, normalized: UnsafeBufferPointer<UInt8>) throws -> UInt32 {
        let hash = Self.byteHash(original)
        var candidate = parentBuckets[hash] ?? Self.absent
        while candidate != Self.absent {
            let parent = parents[Int(candidate)]
            if original.count == Int(parent.originalLength),
               originalBytes[Int(parent.originalOffset)..<(Int(parent.originalOffset) + original.count)].elementsEqual(original) {
                guard normalized.count == Int(parent.normalizedLength), normalizedBytes[Int(parent.normalizedOffset)..<(Int(parent.normalizedOffset) + normalized.count)].elementsEqual(normalized) else { throw IndexPersistenceError.corrupt("同目录的标准化前缀不一致") }
                return candidate
            }
            candidate = parent.nextHash
        }
        guard parents.count < Int(Self.absent), canAppend(originalCount: original.count, normalizedCount: normalized.count) else { throw IndexPersistenceError.tooLarge }
        let id = UInt32(parents.count)
        let mask = normalized.reduce(UInt64(0)) { $0 | characterMask($1) }
        parents.append(Parent(originalOffset: UInt32(originalBytes.count), originalLength: UInt32(original.count),
                              normalizedOffset: UInt32(normalizedBytes.count), normalizedLength: UInt32(normalized.count),
                              mask: mask, nextHash: parentBuckets[hash] ?? Self.absent, references: 0))
        originalBytes.append(contentsOf: original); normalizedBytes.append(contentsOf: normalized)
        parentBuckets[hash] = id
        return id
    }
    private func retainParent(_ id: UInt32) {
        let id = Int(id)
        if parents[id].references == 0 { parentByteCount += Int(parents[id].originalLength) + Int(parents[id].normalizedLength) }
        parents[id].references += 1
    }
    private func addUnlocked(_ path: String, isDir: Bool) -> (id: Int, changed: Bool) {
        guard !path.isEmpty, !path.utf8.contains(0) else { return (-1, false) }
        let hash = hashPath(path)
        if let existing = findPathUnlocked(path, hash: hash) {
            let changed = entries[existing].isDir != isDir
            entries[existing].flags = isDir ? 1 : 0
            return (existing, changed)
        }
        if originalBytes.count + normalizedBytes.count > liveNameBytes + parentByteCount + max(liveNameBytes / 2, 1_048_576) { compactUnlocked() }
        let original = Array(path.utf8)
        var start = original.count
        while start > 0, original[start - 1] != 0x2F { start -= 1 }
        if start == original.count { start = 0 }
        let originalParent = Array(original[..<start]), originalName = Array(original[start...])
        let normalizedParent = Self.searchBytes(String(decoding: originalParent, as: UTF8.self))
        let normalizedName = Self.searchBytes(String(decoding: originalName, as: UTF8.self))
        guard let parentID = try? originalParent.withUnsafeBufferPointer({ prefix in
            try normalizedParent.withUnsafeBufferPointer { try internParent(original: prefix, normalized: $0) }
        }), canAppend(originalCount: originalName.count, normalizedCount: normalizedName.count), entries.count < Int(Self.absent) else { return (-1, false) }
        let originalOffset = UInt32(originalBytes.count), normalizedOffset = UInt32(normalizedBytes.count)
        originalBytes.append(contentsOf: originalName); normalizedBytes.append(contentsOf: normalizedName)
        liveNameBytes += originalName.count + normalizedName.count
        retainParent(parentID)
        let nameMask = normalizedName.reduce(UInt64(0)) { $0 | characterMask($1) }
        let eid = normalizedName.withUnsafeBufferPointer { extensionID($0) }
        let entry = Entry(parent: parentID, originalOffset: originalOffset, originalLength: UInt32(originalName.count),
                          normalizedOffset: normalizedOffset, normalizedLength: UInt32(normalizedName.count), extensionID: eid,
                          nextHash: pathBuckets[hash] ?? Self.absent, flags: isDir ? 1 : 0)
        let id: Int
        if let reused = free.popLast() {
            id = reused; entries[id] = entry; masks[id] = parents[Int(parentID)].mask | nameMask; bnMasks[id] = nameMask
        } else {
            id = entries.count; entries.append(entry); masks.append(parents[Int(parentID)].mask | nameMask); bnMasks.append(nameMask)
        }
        pathBuckets[hash] = UInt32(id)
        return (id, true)
    }
    private func removeIDUnlocked(_ id: Int, hash: UInt64) {
        var candidate = pathBuckets[hash] ?? Self.absent, previous = Self.absent
        while candidate != Self.absent {
            if Int(candidate) == id {
                let next = entries[id].nextHash
                if previous == Self.absent { if next == Self.absent { pathBuckets.removeValue(forKey: hash) } else { pathBuckets[hash] = next } }
                else { entries[Int(previous)].nextHash = next }
                let parentID = Int(entries[id].parent)
                parents[parentID].references -= 1
                if parents[parentID].references == 0 { parentByteCount -= Int(parents[parentID].originalLength) + Int(parents[parentID].normalizedLength) }
                liveNameBytes -= Int(entries[id].originalLength) + Int(entries[id].normalizedLength)
                entries[id].originalLength = 0; entries[id].normalizedLength = 0
                entries[id].nextHash = Self.absent; masks[id] = 0; bnMasks[id] = 0
                free.append(id); return
            }
            previous = candidate; candidate = entries[Int(candidate)].nextHash
        }
    }
    private func compactUnlocked() {
        // Rebuild only live parents and names; snapshots retain their old arenas
        // until their consumers finish, including re-entrant enumeration.
        let snapshot = snapshotUnlocked(), rebuilt = SearchEngine(pathHashBits: pathHashBits)
        rebuilt.reserveCapacity(snapshot.count)
        for entry in snapshot.entries where entry.isLive { _ = rebuilt.addUnlocked(snapshot.path(entry), isDir: entry.isDir) }
        entries = rebuilt.entries; parents = rebuilt.parents; masks = rebuilt.masks; bnMasks = rebuilt.bnMasks
        originalBytes = rebuilt.originalBytes; normalizedBytes = rebuilt.normalizedBytes
        pathBuckets = rebuilt.pathBuckets; parentBuckets = rebuilt.parentBuckets; extToID = rebuilt.extToID
        liveNameBytes = rebuilt.liveNameBytes; parentByteCount = rebuilt.parentByteCount; free.removeAll(keepingCapacity: false)
    }
    private func extensionID(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        guard bytes.count > 2 else { return 0 }
        var dot = bytes.count - 1
        while dot > 0, bytes[dot] != 0x2E { dot -= 1 }
        guard dot > 0, bytes[dot] == 0x2E, dot < bytes.count - 1 else { return 0 }
        let ext = String(decoding: bytes[(dot + 1)...], as: UTF8.self)
        if let existing = extToID[ext] { return existing }
        guard extToID.count < Int(UInt32.max) - 1 else { return 0 }
        let id = UInt32(extToID.count + 1); extToID[ext] = id; return id
    }
}

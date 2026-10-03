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
    private struct Entry {
        var path: String
        var isDir: Bool
        var bnStart: Int
        var pathLen: Int
    }
    private enum ByteNameMatcher {
        case literal([UInt8])
        case prefixSuffix([UInt8], [UInt8])
        case extensionSuffix(UInt32?, [UInt8])
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
            switch self {
            case .literal(let bytes):
                if bytes.isEmpty { return true }
                return bytes.withUnsafeBufferPointer { needle in
                    simdContains(text, count: count, needle: needle.baseAddress!, needleLen: needle.count)
                }
            case .prefixSuffix(let prefix, let suffix):
                return count >= prefix.count + suffix.count && hasPrefix(prefix) && hasSuffix(suffix)
            case .extensionSuffix(let wantedID, let suffix):
                // *.pdf includes folders named folder.pdf, unlike ext:pdf.
                // A .pdf dotfile has no extension ID and needs a byte fallback.
                if extensionID != 0 { return wantedID == extensionID }
                return hasSuffix(suffix)
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
    private var masks: [UInt64] = []
    private var bnMasks: [UInt64] = []
    private var allBytes: [UInt8] = []
    private var byteOffsets: [Int] = []
    private var byteLengths: [Int] = []
    private var liveByteCount = 0
    private var extIDs: [UInt32] = []
    private var extToID: [String: UInt32] = [:]
    private var free: [Int] = []
    private var pathToID: [String: Int] = [:]
    private let lock = NSLock()

    var count: Int { lock.withLock { entries.count - free.count } }

    func hasPath(_ path: String) -> Bool { lock.withLock { pathToID[path] != nil } }

    /// Visit a consistent snapshot of the paths live at the time of capture.
    /// Swift's copy-on-write Array shares its storage until a concurrent writer
    /// changes entries. Capture under the lock, then run callbacks unlocked so
    /// slow consumers cannot block searches or mutations. Callbacks may safely
    /// re-enter this engine; changes are not included in this enumeration.
    func forEachPath(_ visit: (String, Bool) -> Void) {
        _ = forEachPathWhile { path, isDir in
            visit(path, isDir)
            return true
        }
    }

    /// Returns false as soon as the callback asks to stop, or true after the
    /// whole captured snapshot has been visited. Shares the same lock-free
    /// callback contract as forEachPath, including safe engine re-entry.
    @discardableResult
    func forEachPathWhile(_ visit: (String, Bool) -> Bool) -> Bool {
        let snapshot = lock.withLock { entries }
        for entry in snapshot where entry.pathLen > 0 {
            if !visit(entry.path, entry.isDir) { return false }
        }
        return true
    }

    func reserveCapacity(_ n: Int, avgPathLen: Int = 64) {
        guard n > 0, n <= Int.max / max(avgPathLen, 1) else { return }
        lock.withLock {
            entries.reserveCapacity(n)
            masks.reserveCapacity(n)
            bnMasks.reserveCapacity(n)
            byteOffsets.reserveCapacity(n)
            byteLengths.reserveCapacity(n)
            extIDs.reserveCapacity(n)
            pathToID.reserveCapacity(n)
            allBytes.reserveCapacity(n * max(avgPathLen, 1))
        }
    }

    @discardableResult
    func addPath(_ path: String, isDir: Bool) -> Int {
        lock.withLock { addUnlocked(Self.trimTrailingSlash(path), isDir: isDir) }
    }

    /// Match exact root or slash-delimited descendants, never siblings such as
    /// /a/report-old when deleting /a/report.
    func removeSubtree(_ path: String) {
        let root = Self.trimTrailingSlash(path)
        guard !root.isEmpty else { return }
        let prefix = root == "/" ? "/" : root + "/"
        lock.withLock {
            if let id = pathToID[root], !entries[id].isDir {
                removeUnlocked(root)
                return
            }
            var removed: [String] = []
            for key in pathToID.keys where key == root || key.hasPrefix(prefix) {
                removed.append(key)
            }
            for key in removed { removeUnlocked(key) }
            // Free slots are reused immediately; reclaim stale byte storage
            // after a substantial removal instead of growing without bound.
            if !entries.isEmpty, free.count > entries.count / 3 { compactUnlocked() }
        }
    }

    /// excludeHit runs under this engine's lock and must never re-enter this
    /// engine. Cross-engine membership checks must follow one stable lock order.
    /// Exclusions are applied before totalMatches and the first-page limit.
    func literalQuery(_ request: SearchRequest, rootID: String, limit: Int,
                      excludeHit: ((String) -> Bool)? = nil) -> EngineQueryResult {
        if let wantedRoot = request.rootID, wantedRoot != rootID {
            return EngineQueryResult(hits: [], totalMatches: 0)
        }
        let plan = request.parsedPlan ?? AdvancedSearchPlan.parse(request)
        guard plan.error == nil, request.cancellation?.isCancelled != true else {
            return EngineQueryResult(hits: [], totalMatches: 0)
        }
        guard let literals = plan.simpleLiteralTokens else {
            return advancedQuery(request, plan: plan, rootID: rootID, limit: limit, excludeHit: excludeHit)
        }
        let tokens = literals.map { Self.searchBytes($0) }.filter { !$0.isEmpty }
        let queryMask = tokens.reduce(UInt64(0)) { mask, token in
            token.reduce(mask) { $0 | characterMask($1) }
        }
        let extensions = Self.extensionTokens(request.extensionFilter)
        let checkIndexedFilters = plan.hasNonCategoryIndexedFilters
        let categoryExtensions = request.filters.category.extensions
        let maxHits = max(0, limit)
        return lock.withLock {
            guard !entries.isEmpty else { return EngineQueryResult(hits: [], totalMatches: 0) }
            let extensionIDs = Set(extensions.compactMap { extToID[$0] })
            let categoryIDs = Set(categoryExtensions.compactMap { extToID[$0] })
            if !extensions.isEmpty, extensionIDs.isEmpty {
                return EngineQueryResult(hits: [], totalMatches: 0)
            }
            let searchMasks = request.matchPath ? masks : bnMasks
            let candidates: [Int] = searchMasks.withUnsafeBufferPointer { maskBuffer in
                [Int](unsafeUninitializedCapacity: entries.count) { out, initialized in
                    initialized = simdFilterMasks(maskBuffer.baseAddress!, count: entries.count,
                                                   queryMask: queryMask, out: out.baseAddress!)
                }
            }
            var hits: [FileHit] = []
            hits.reserveCapacity(min(maxHits, candidates.count))
            var total = 0
            // Hold every token's pointer alive once for the entire candidate
            // pass instead of bridging Swift arrays for each entry.
            Self.withTokenPointers(tokens) { tokenBuffers in
                allBytes.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    for (number, id) in candidates.enumerated() {
                        if number & 255 == 0, request.cancellation?.isCancelled == true { break }
                        let entry = entries[id]
                        guard entry.pathLen > 0 else { continue }
                        if request.kind == .files, entry.isDir { continue }
                        if request.kind == .folders, !entry.isDir { continue }
                        if !extensions.isEmpty, (entry.isDir || !extensionIDs.contains(extIDs[id])) { continue }
                        if !categoryExtensions.isEmpty, (entry.isDir || !categoryIDs.contains(extIDs[id])) { continue }
                        let start = request.matchPath ? 0 : entry.bnStart
                        let text = base + byteOffsets[id] + start
                        let length = byteLengths[id] - start
                        var matches = true
                        for token in tokenBuffers {
                            if !simdContains(text, count: length, needle: token.baseAddress!, needleLen: token.count) {
                                matches = false
                                break
                            }
                        }
                        if matches, (!checkIndexedFilters || plan.matchesIndexedFilters(FileHit(path: entry.path, isDirectory: entry.isDir, rootID: rootID), categoryPrechecked: true)),
                           excludeHit?(entry.path) != true {
                            total += 1
                            if hits.count < maxHits {
                                hits.append(FileHit(path: entry.path, isDirectory: entry.isDir, rootID: rootID))
                            }
                        }
                    }
                }
            }
            return EngineQueryResult(hits: hits, totalMatches: total)
        }
    }

    /// Complex name conditions still scan only the compact in-memory index.
    /// Property predicates are evaluated later by MetadataQuery, unlocked.
    private func advancedQuery(_ request: SearchRequest, plan: AdvancedSearchPlan, rootID: String, limit: Int,
                               excludeHit: ((String) -> Bool)?) -> EngineQueryResult {
        let extensions = Self.extensionTokens(request.extensionFilter)
        let maxHits = max(0, limit), queryMask = plan.requiredMask
        let checkIndexedFilters = plan.hasNonCategoryIndexedFilters
        let categoryExtensions = request.filters.category.extensions
        return lock.withLock {
            guard !entries.isEmpty else { return EngineQueryResult(hits: [], totalMatches: 0) }
            let extensionIDs = Set(extensions.compactMap { extToID[$0] })
            let categoryIDs = Set(categoryExtensions.compactMap { extToID[$0] })
            if !extensions.isEmpty, extensionIDs.isEmpty { return EngineQueryResult(hits: [], totalMatches: 0) }
            let branchMasks = plan.branchMasks
            let branches = plan.branches.enumerated().map { number, branch in
                (mask: branchMasks[number], terms: branch.compactMap { term -> CompiledNameTerm? in
                    let predicate: CompiledNameTerm.Predicate
                    switch term.predicate {
                    case .name(let text, let wildcard): predicate = .name(compileName(text, wildcard: wildcard))
                    case .typedName(let kind, let text, let wildcard): predicate = .typed(kind, compileName(text, wildcard: wildcard))
                    case .extensions(let values): predicate = .extensions(Set(values.compactMap { extToID[$0] }))
                    case .size, .modified, .created, .nameCondition, .pathCondition, .extensionCondition, .visibility: return nil
                    }
                    return CompiledNameTerm(predicate: predicate, negated: term.negated)
                })
            }
            let searchMasks = request.matchPath ? masks : bnMasks
            let candidates: [Int] = searchMasks.withUnsafeBufferPointer { maskBuffer in
                [Int](unsafeUninitializedCapacity: entries.count) { out, initialized in
                    initialized = simdFilterMasks(maskBuffer.baseAddress!, count: entries.count,
                                                   queryMask: queryMask, out: out.baseAddress!)
                }
            }
            var hits: [FileHit] = [], total = 0
            hits.reserveCapacity(min(maxHits, candidates.count))
            allBytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                for (number, id) in candidates.enumerated() {
                    if number & 255 == 0, request.cancellation?.isCancelled == true { break }
                    let entry = entries[id]
                    guard entry.pathLen > 0 else { continue }
                    if request.kind == .files, entry.isDir { continue }
                    if request.kind == .folders, !entry.isDir { continue }
                    if !extensions.isEmpty, (entry.isDir || !extensionIDs.contains(extIDs[id])) { continue }
                    if !categoryExtensions.isEmpty, (entry.isDir || !categoryIDs.contains(extIDs[id])) { continue }
                    if plan.hasStructuredExpression {
                        let hit = FileHit(path: entry.path, isDirectory: entry.isDir, rootID: rootID)
                        guard plan.matchesCandidate(hit, matchPath: request.matchPath), excludeHit?(entry.path) != true else { continue }
                        total += 1
                        if hits.count < maxHits { hits.append(hit) }
                        continue
                    }
                    let start = request.matchPath ? 0 : entry.bnStart
                    let text = base + byteOffsets[id] + start, length = byteLengths[id] - start
                    var decodedText: String? = nil, matches = false
                    for branch in branches where searchMasks[id] & branch.mask == branch.mask {
                        var accepted = true
                        for term in branch.terms {
                            if !term.matches(text, count: length, isDirectory: entry.isDir, extensionID: extIDs[id], decodedText: &decodedText) {
                                accepted = false; break
                            }
                        }
                        if accepted { matches = true; break }
                    }
                    guard matches, (!checkIndexedFilters || plan.matchesIndexedFilters(FileHit(path: entry.path, isDirectory: entry.isDir, rootID: rootID), categoryPrechecked: true)),
                          excludeHit?(entry.path) != true else { continue }
                    total += 1
                    if hits.count < maxHits { hits.append(FileHit(path: entry.path, isDirectory: entry.isDir, rootID: rootID)) }
                }
            }
            return EngineQueryResult(hits: hits, totalMatches: total)
        }
    }

    /// Compile common wildcard forms once per query. ASCII and UTF-8 literal
    /// prefixes/suffixes can compare the existing normalized bytes directly;
    /// only patterns needing Character-aware '?' or several interior stars fall
    /// back to the generic matcher. No per-entry NSString/Character allocation
    /// is needed for extension OR queries or mixed `合同 *.pdf !草稿` queries.
    private func compileName(_ text: String, wildcard: Bool) -> ByteNameMatcher {
        guard wildcard else { return .literal(Array(text.utf8)) }
        let starCount = text.reduce(0) { $1 == "*" ? $0 + 1 : $0 }
        if !text.contains("?"), starCount == 1, let star = text.firstIndex(of: "*") {
            let prefix = String(text[..<star]), suffix = String(text[text.index(after: star)...])
            if prefix.isEmpty, suffix.hasPrefix("."), suffix.count > 1,
               !suffix.dropFirst().contains("."), !suffix.contains("/") {
                return .extensionSuffix(extToID[String(suffix.dropFirst())], Array(suffix.utf8))
            }
            return .prefixSuffix(Array(prefix.utf8), Array(suffix.utf8))
        }
        if !text.contains("?"), starCount == 2, text.hasPrefix("*"), text.hasSuffix("*") {
            return .literal(Array(text.dropFirst().dropLast().utf8))
        }
        return .characters(text)
    }

    // Binary format v1, little endian. Derived from Cling's array format:
    // magic[8], n[8], normalizedByteCount[8], originalPathByteCount[8],
    // masks[n*8], basenameMasks[n*8], offsets[n*8], lengths[n*4],
    // basenameStarts[n*4], isDirectory[n], normalizedBytes, originalPaths(NUL),
    // SHA256[32]. Only live entries are written, so every save compacts the file
    // without modifying the live engine or holding its lock while encoding.
    private static let binaryMagic = Array("QFINDIX1".utf8)
    private static let binaryHeaderSize = 32
    private static let binaryBytesPerEntry = 33

    func saveBinaryIndex(to url: URL) throws {
        // All arrays and Entry/String values have copy-on-write value semantics:
        // their shared storage remains immutable if a concurrent writer changes
        // the live engine. Capture them together to preserve a coherent version.
        let snapshot = lock.withLock {
            (entries: entries, masks: masks, bnMasks: bnMasks, allBytes: allBytes,
             byteOffsets: byteOffsets, byteLengths: byteLengths,
             count: entries.count - free.count)
        }
        let n = snapshot.count
        var liveIDs: [Int] = []
        liveIDs.reserveCapacity(n)
        var normalizedByteCount = 0, originalPathBytes = 0
        var normalizedBytesAreCompact = true
        for id in snapshot.entries.indices where snapshot.entries[id].pathLen > 0 {
            let byteLength = snapshot.byteLengths[id]
            let pathLength = snapshot.entries[id].path.utf8.count
            guard byteLength <= Int(UInt32.max), byteLength <= Int.max - normalizedByteCount,
                  pathLength < Int.max - originalPathBytes - 1 else { throw IndexPersistenceError.tooLarge }
            if snapshot.byteOffsets[id] != normalizedByteCount { normalizedBytesAreCompact = false }
            normalizedByteCount += byteLength
            originalPathBytes += pathLength + 1
            liveIDs.append(id)
        }
        normalizedBytesAreCompact = normalizedBytesAreCompact && snapshot.allBytes.count == normalizedByteCount
        guard n <= (Int.max - Self.binaryHeaderSize - 32) / Self.binaryBytesPerEntry,
              normalizedByteCount <= Int.max - Self.binaryHeaderSize - n * Self.binaryBytesPerEntry - 32,
              originalPathBytes <= Int.max - Self.binaryHeaderSize - n * Self.binaryBytesPerEntry - normalizedByteCount - 32
        else { throw IndexPersistenceError.tooLarge }
        let size = Self.binaryHeaderSize + n * Self.binaryBytesPerEntry + normalizedByteCount + originalPathBytes
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            var offset = 0
            for byte in Self.binaryMagic { base.storeBytes(of: byte, toByteOffset: offset, as: UInt8.self); offset += 1 }
            func write64(_ value: UInt64) {
                base.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self); offset += 8
            }
            func write32(_ value: UInt32) {
                base.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self); offset += 4
            }
            write64(UInt64(n)); write64(UInt64(normalizedByteCount)); write64(UInt64(originalPathBytes))
            for id in liveIDs { write64(snapshot.masks[id]) }
            for id in liveIDs { write64(snapshot.bnMasks[id]) }
            var normalizedOffset = 0
            for id in liveIDs {
                write64(UInt64(normalizedOffset))
                normalizedOffset += snapshot.byteLengths[id]
            }
            for id in liveIDs { write32(UInt32(snapshot.byteLengths[id])) }
            for id in liveIDs { write32(UInt32(snapshot.entries[id].bnStart)) }
            for id in liveIDs {
                base.storeBytes(of: UInt8(snapshot.entries[id].isDir ? 1 : 0), toByteOffset: offset, as: UInt8.self); offset += 1
            }
            if normalizedByteCount > 0 {
                snapshot.allBytes.withUnsafeBufferPointer { bytes in
                    if normalizedBytesAreCompact {
                        _ = memcpy(base + offset, bytes.baseAddress!, normalizedByteCount)
                        offset += normalizedByteCount
                    } else {
                        for id in liveIDs {
                            let length = snapshot.byteLengths[id]
                            _ = memcpy(base + offset, bytes.baseAddress! + snapshot.byteOffsets[id], length)
                            offset += length
                        }
                    }
                }
            }
            for id in liveIDs {
                var path = snapshot.entries[id].path
                path.withUTF8 { bytes in
                    _ = memcpy(base + offset, bytes.baseAddress!, bytes.count)
                    offset += bytes.count
                }
                base.storeBytes(of: UInt8(0), toByteOffset: offset, as: UInt8.self); offset += 1
            }
        }
        data.append(contentsOf: SHA256.hash(data: data))
        try data.write(to: url, options: .atomic)
        engineLog.debug("Saved checked binary index: \(data.count) bytes")
    }

    static func loadBinaryIndex(from url: URL) throws -> SearchEngine {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= binaryHeaderSize + 32 else { throw IndexPersistenceError.corrupt("文件过短") }
        let payloadSize = data.count - 32
        guard data.prefix(8).elementsEqual(binaryMagic) else { throw IndexPersistenceError.corrupt("格式标识错误") }
        let checksum = SHA256.hash(data: data.prefix(payloadSize))
        guard data.suffix(32).elementsEqual(checksum) else { throw IndexPersistenceError.corrupt("完整性校验失败") }
        let engine = SearchEngine()
        try data.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            func read64(_ offset: Int) -> UInt64 { UInt64(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
            func read32(_ offset: Int) -> UInt32 { UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            let rawN = read64(8), rawBytes = read64(16), rawPaths = read64(24)
            // Validate as UInt64 before Int conversion or any multiplication.
            guard rawN <= UInt64(payloadSize / (binaryBytesPerEntry + 1)),
                  rawBytes <= UInt64(payloadSize), rawPaths <= UInt64(payloadSize) else {
                throw IndexPersistenceError.corrupt("头部数量超出文件大小")
            }
            let n = Int(rawN), bytesCount = Int(rawBytes), pathBytes = Int(rawPaths)
            let fixedEnd = binaryHeaderSize + n * binaryBytesPerEntry
            guard fixedEnd <= payloadSize, bytesCount <= payloadSize - fixedEnd,
                  pathBytes == payloadSize - fixedEnd - bytesCount else {
                throw IndexPersistenceError.corrupt("数组长度不匹配")
            }
            var offset = binaryHeaderSize
            engine.masks = (0..<n).map { read64(offset + $0 * 8) }; offset += n * 8
            engine.bnMasks = (0..<n).map { read64(offset + $0 * 8) }; offset += n * 8
            engine.byteOffsets = []
            engine.byteOffsets.reserveCapacity(n)
            for i in 0..<n {
                let value = read64(offset + i * 8)
                guard value <= UInt64(bytesCount) else { throw IndexPersistenceError.corrupt("字节偏移越界") }
                engine.byteOffsets.append(Int(value))
            }
            offset += n * 8
            engine.byteLengths = (0..<n).map { Int(read32(offset + $0 * 4)) }; offset += n * 4
            let bnStarts = (0..<n).map { Int(read32(offset + $0 * 4)) }; offset += n * 4
            var isDirs: [Bool] = []
            isDirs.reserveCapacity(n)
            for i in 0..<n {
                let value = base.load(fromByteOffset: offset + i, as: UInt8.self)
                guard value <= 1 else { throw IndexPersistenceError.corrupt("目录标志错误") }
                isDirs.append(value == 1)
                guard engine.byteLengths[i] > 0,
                      engine.byteLengths[i] <= bytesCount - engine.byteOffsets[i],
                      bnStarts[i] < engine.byteLengths[i] else { throw IndexPersistenceError.corrupt("条目字节范围越界") }
                // A v1 file compacts paths consecutively. Reject overlapping,
                // missing or duplicated ranges, even with a valid checksum.
                guard engine.byteOffsets[i] == engine.liveByteCount else {
                    throw IndexPersistenceError.corrupt("条目字节区域不连续")
                }
                engine.liveByteCount += engine.byteLengths[i]
            }
            guard engine.liveByteCount == bytesCount else { throw IndexPersistenceError.corrupt("字节区域长度不匹配") }
            offset += n
            let byteBase = (base + offset).assumingMemoryBound(to: UInt8.self)
            engine.allBytes = Array(UnsafeBufferPointer(start: byteBase, count: bytesCount))
            offset += bytesCount
            let pathBase = (base + offset).assumingMemoryBound(to: UInt8.self)
            var pathOffset = 0
            engine.entries.reserveCapacity(n)
            engine.pathToID.reserveCapacity(n)
            for i in 0..<n {
                var length = 0
                while pathOffset + length < pathBytes, pathBase[pathOffset + length] != 0 { length += 1 }
                guard length > 0, pathOffset + length < pathBytes,
                      let path = String(bytes: UnsafeBufferPointer(start: pathBase + pathOffset, count: length), encoding: .utf8),
                      engine.pathToID[path] == nil else { throw IndexPersistenceError.corrupt("路径字符串无效或重复") }
                engine.entries.append(Entry(path: path, isDir: isDirs[i], bnStart: bnStarts[i], pathLen: engine.byteLengths[i]))
                engine.pathToID[path] = i
                pathOffset += length + 1
            }
            guard pathOffset == pathBytes else { throw IndexPersistenceError.corrupt("路径数据有多余内容") }
            engine.extIDs = [UInt32](repeating: 0, count: n)
            engine.allBytes.withUnsafeBufferPointer { buffer in
                guard let bytes = buffer.baseAddress else { return }
                for i in 0..<n {
                    engine.extIDs[i] = engine.extensionID(bytes + engine.byteOffsets[i],
                                                          length: engine.byteLengths[i], basenameStart: bnStarts[i])
                }
            }
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
        // Most system paths are ASCII: keep Cling's inexpensive lowercase pass.
        if !bytes.contains(where: { $0 >= 0x80 }) {
            return bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 &+ 32 : $0 }
        }
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

    private static func withTokenPointers(_ tokens: [[UInt8]],
                                          _ body: ([UnsafeBufferPointer<UInt8>]) -> Void) {
        let allocations: [UnsafeMutablePointer<UInt8>] = tokens.map { token in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: token.count)
            token.withUnsafeBufferPointer { pointer.initialize(from: $0.baseAddress!, count: token.count) }
            return pointer
        }
        defer { for pointer in allocations { pointer.deallocate() } }
        body(zip(allocations, tokens).map { UnsafeBufferPointer(start: $0.0, count: $0.1.count) })
    }

    /// Cling's _addPath storage layout with Unicode-normalized bytes and exact
    /// extension identifiers, avoiding the upstream 8-byte extension hash alias.
    @discardableResult
    private func addUnlocked(_ path: String, isDir: Bool) -> Int {
        guard !path.isEmpty, !path.utf8.contains(0) else { return -1 }
        if let existing = pathToID[path] {
            entries[existing].isDir = isDir
            return existing
        }
        // FSEvents commonly removes/re-adds the same path. Reused slots still
        // append normalized bytes, so reclaim storage after 50% waste (with a
        // 1 MiB allowance for small indexes). This amortizes compaction rather
        // than letting a long-running background process grow indefinitely.
        if allBytes.count > liveByteCount + max(liveByteCount / 2, 1_048_576) {
            compactUnlocked()
        }
        let bytes = Self.searchBytes(path)
        let byteOff = allBytes.count
        let pathLen = bytes.count
        var bnStart = 0
        var mask: UInt64 = 0, bnMask: UInt64 = 0
        for (i, byte) in bytes.enumerated() {
            if byte == 0x2F {
                bnStart = i + 1
                bnMask = 0
            } else {
                let bit = characterMask(byte)
                mask |= bit; bnMask |= bit
            }
        }
        // Root / is itself a searchable folder, with / as its visible name.
        if bnStart == pathLen { bnStart = 0 }
        allBytes.append(contentsOf: bytes)
        liveByteCount += pathLen
        let eid = bytes.withUnsafeBufferPointer {
            extensionID($0.baseAddress!, length: pathLen, basenameStart: bnStart)
        }
        let entry = Entry(path: path, isDir: isDir, bnStart: bnStart, pathLen: pathLen)
        let id: Int
        if let reused = free.popLast() {
            id = reused
            entries[id] = entry
            masks[id] = mask; bnMasks[id] = bnMask
            byteOffsets[id] = byteOff; byteLengths[id] = pathLen; extIDs[id] = eid
        } else {
            id = entries.count
            entries.append(entry)
            masks.append(mask); bnMasks.append(bnMask)
            byteOffsets.append(byteOff); byteLengths.append(pathLen); extIDs.append(eid)
        }
        pathToID[path] = id
        return id
    }

    private func removeUnlocked(_ path: String) {
        guard let id = pathToID.removeValue(forKey: path) else { return }
        liveByteCount -= byteLengths[id]
        entries[id] = Entry(path: "", isDir: false, bnStart: 0, pathLen: 0)
        masks[id] = 0; bnMasks[id] = 0
        byteOffsets[id] = 0; byteLengths[id] = 0; extIDs[id] = 0
        free.append(id)
    }

    private func compactUnlocked(force: Bool = false) {
        if free.isEmpty {
            if allBytes.count == liveByteCount { return }
            if !force, allBytes.count <= liveByteCount + max(liveByteCount / 4, 1_048_576) { return }
        }
        var liveEntries: [Entry] = []
        var liveMasks: [UInt64] = [], liveBnMasks: [UInt64] = []
        var liveOffsets: [Int] = [], liveLengths: [Int] = []
        var liveExtIDs: [UInt32] = []
        var liveBytes: [UInt8] = []
        let liveCount = entries.count - free.count
        liveEntries.reserveCapacity(liveCount)
        liveMasks.reserveCapacity(liveCount); liveBnMasks.reserveCapacity(liveCount)
        liveOffsets.reserveCapacity(liveCount); liveLengths.reserveCapacity(liveCount)
        liveExtIDs.reserveCapacity(liveCount)
        liveBytes.reserveCapacity(liveByteCount)
        pathToID.removeAll(keepingCapacity: true)
        for i in entries.indices where entries[i].pathLen > 0 {
            let id = liveEntries.count
            pathToID[entries[i].path] = id
            liveEntries.append(entries[i]); liveMasks.append(masks[i]); liveBnMasks.append(bnMasks[i])
            liveOffsets.append(liveBytes.count); liveLengths.append(byteLengths[i]); liveExtIDs.append(extIDs[i])
            liveBytes.append(contentsOf: allBytes[byteOffsets[i]..<(byteOffsets[i] + byteLengths[i])])
        }
        entries = liveEntries; masks = liveMasks; bnMasks = liveBnMasks
        byteOffsets = liveOffsets; byteLengths = liveLengths; extIDs = liveExtIDs
        allBytes = liveBytes
        free.removeAll(keepingCapacity: true)
    }

    private func extensionID(_ bytes: UnsafePointer<UInt8>, length: Int, basenameStart: Int) -> UInt32 {
        var dot = length - 1
        while dot > basenameStart, bytes[dot] != 0x2E { dot -= 1 }
        guard dot > basenameStart, bytes[dot] == 0x2E, dot < length - 1 else { return 0 }
        let ext = String(decoding: UnsafeBufferPointer(start: bytes + dot + 1, count: length - dot - 1), as: UTF8.self)
        if let existing = extToID[ext] { return existing }
        // A real macOS disk cannot fit UInt32.max distinct file extensions in
        // memory. Keep zero as the reserved no-extension identifier.
        let id = UInt32(extToID.count + 1)
        extToID[ext] = id
        return id
    }
}

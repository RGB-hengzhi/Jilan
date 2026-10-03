// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A bounded, short-lived property cache. No filesystem access takes place while
/// holding either this cache's lock or SearchEngine's index lock. The index keeps
/// filename search fast without depending on complete disk metadata coverage.
final class MetadataQuery: @unchecked Sendable {
    struct Properties {
        var size: Int64?
        var modified: Date?
        var created: Date? = nil
        var hidden: Bool? = nil
    }
    struct Progress {
        var hits: [FileHit]
        var totalMatches: Int
        var inspected: Int
        var totalCandidates: Int
        var offline: Int
        var unavailable: Int
        var cancelled: Bool
        var uninspected: Int { max(0, totalCandidates - inspected) }
        var hasMore: Bool { uninspected > 0 }
        var detail: String {
            let prefix = cancelled ? "属性检查已取消" : hasMore ? "部分结果" : "属性检查完成"
            var text = "\(prefix) · 已检查 \(inspected.formatted()) / \(totalCandidates.formatted()) 个名称候选"
            if hasMore { text += " · \(uninspected.formatted()) 项尚未检查" }
            if offline > 0 { text += " · 离线 \(offline.formatted()) 项" }
            if unavailable > 0 { text += " · 属性未知 \(unavailable.formatted()) 项未纳入匹配数" }
            return text
        }
    }
    private struct Cached { var properties: Properties; var readAt: Date; var generation: Int; var includesHidden: Bool }
    private struct CachedVisibility { var value: Bool?; var readAt: Date; var generation: Int }
    private let lock = NSLock()
    private var cache: [String: Cached] = [:]
    private var visibilityCache: [String: CachedVisibility] = [:]
    private var generation = 0
    private let cacheLifetime: TimeInterval
    private let cacheCapacity: Int

    init(cacheLifetime: TimeInterval = 10, cacheCapacity: Int = 100_000) {
        self.cacheLifetime = max(0, cacheLifetime); self.cacheCapacity = max(1, cacheCapacity)
    }

    func invalidate() { lock.withLock { generation += 1; cache.removeAll(keepingCapacity: true); visibilityCache.removeAll(keepingCapacity: true) } }

    func properties(for path: String, includeHidden: Bool = false) -> Properties? {
        let now = Date()
        let state = lock.withLock { (generation, cache[path]) }
        if let cached = state.1, now.timeIntervalSince(cached.readAt) < cacheLifetime,
           !includeHidden || cached.includesHidden { return cached.properties }
        // FileManager's attributes are read on the caller's background queue.
        // Folder size is deliberately omitted by the caller when filtering.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value
        let properties = Properties(size: size, modified: attributes[.modificationDate] as? Date,
            created: attributes[.creationDate] as? Date, hidden: includeHidden ? effectiveHidden(path: path, generation: state.0) : nil)
        lock.withLock {
            guard generation == state.0 else { return }
            if cache.count >= cacheCapacity { cache.removeAll(keepingCapacity: true) }
            cache[path] = Cached(properties: properties, readAt: now, generation: generation, includesHidden: includeHidden)
        }
        return properties
    }

    /// Finder's hidden flag is inherited through visible filesystem ancestors.
    /// Stop at the mounted volume root: /Volumes itself is a hidden system
    /// container and must not make every item on an external disk hidden.
    private func effectiveHidden(path: String, generation expectedGeneration: Int) -> Bool? {
        if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return true }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isHiddenKey, .volumeURLKey]),
              let ownHidden = values.isHidden else { return nil }
        if ownHidden { return true }
        let volumeRoot = values.volume?.standardized.path ?? "/"
        if url.standardized.path == volumeRoot { return false }
        var parent = (path as NSString).deletingLastPathComponent
        var unknown = false
        while !parent.isEmpty && parent != path {
            let now = Date()
            let cached = lock.withLock { visibilityCache[parent] }
            let hidden: Bool?
            if let cached, cached.generation == expectedGeneration, now.timeIntervalSince(cached.readAt) < cacheLifetime {
                hidden = cached.value
            } else {
                hidden = (try? URL(fileURLWithPath: parent).resourceValues(forKeys: [.isHiddenKey]))?.isHidden
                lock.withLock {
                    guard generation == expectedGeneration else { return }
                    if visibilityCache.count >= cacheCapacity { visibilityCache.removeAll(keepingCapacity: true) }
                    visibilityCache[parent] = CachedVisibility(value: hidden, readAt: now, generation: generation)
                }
            }
            if hidden == true { return true }
            if hidden == nil { unknown = true }
            if parent == volumeRoot || parent == "/" { break }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return unknown ? nil : false
    }

    /// The caller selects an explicit inspection budget. A short first pass lets
    /// users see results promptly; "检查全部候选" supplies the full candidate list.
    /// Progress is throttled, and cancellation is checked between every item.
    func filter(_ candidates: [FileHit], totalCandidates: Int, plan: AdvancedSearchPlan,
                matchPath: Bool, limit: Int, cancellation: CancellationFlag,
                readProperties: ((String) -> Properties?)? = nil,
                onProgress: ((Progress) -> Void)? = nil) -> Progress {
        var hits: [FileHit] = [], count = 0, inspected = 0, offline = 0, unavailable = 0
        hits.reserveCapacity(min(max(0, limit), candidates.count))
        var reportedAt = Date(), reportedCount = 0
        func progress(_ cancelled: Bool = false) -> Progress {
            Progress(hits: hits, totalMatches: count, inspected: inspected, totalCandidates: totalCandidates,
                     offline: offline, unavailable: unavailable, cancelled: cancelled)
        }
        for var hit in candidates {
            if cancellation.isCancelled { return progress(true) }
            inspected += 1
            var accepted = plan.matches(hit, matchPath: matchPath, size: nil, modified: nil)
            if accepted == nil {
                if !hit.isOnline { offline += 1 }
                else if let properties = readProperties?(hit.path) ?? (readProperties == nil ? self.properties(for: hit.path, includeHidden: plan.usesHiddenMetadata) : nil) {
                    hit.size = hit.isDirectory ? nil : properties.size
                    hit.modifiedDate = properties.modified
                    hit.createdDate = properties.created
                    accepted = plan.matches(hit, matchPath: matchPath, size: hit.size, modified: hit.modifiedDate,
                                            created: hit.createdDate, hidden: properties.hidden)
                }
            }
            if accepted == true {
                count += 1
                if hits.count < max(0, limit) { hits.append(hit) }
            } else if accepted == nil && hit.isOnline { unavailable += 1 }
            if inspected - reportedCount >= 5000 || Date().timeIntervalSince(reportedAt) >= 1 {
                onProgress?(progress()); reportedAt = Date(); reportedCount = inspected
            }
        }
        return progress(cancellation.isCancelled)
    }
}

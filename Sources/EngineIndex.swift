// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Stable app-facing adapter; SearchEngine owns the synchronization.
final class EngineIndex: @unchecked Sendable {
    private let engine: SearchEngine
    init() { engine = SearchEngine() }
    private init(engine: SearchEngine) { self.engine = engine }
    var count: Int { engine.count }
    func hasPath(_ path: String) -> Bool { engine.hasPath(path) }
    /// Enumerates an immutable snapshot captured under this index's lock.
    /// Callbacks run unlocked and may query or modify this index safely.
    /// Changes made during enumeration are not part of the captured snapshot.
    func forEachPath(_ visit: (String, Bool) -> Void) { engine.forEachPath(visit) }
    /// A false callback result stops immediately. Returns true only if the
    /// complete snapshot was visited; callbacks run without the index lock.
    @discardableResult
    func forEachPathWhile(_ visit: (String, Bool) -> Bool) -> Bool { engine.forEachPathWhile(visit) }
    func add(path: String, isDirectory: Bool) { engine.addPath(path, isDir: isDirectory) }
    func removeSubtree(path: String) { engine.removeSubtree(path) }
    /// excludeHit cannot re-enter this index. When checking other indexes, the
    /// caller must enforce a stable lock order for all simultaneous searches.
    func query(_ request: SearchRequest, rootID: String, limit: Int,
               excludeHit: ((String) -> Bool)? = nil) -> EngineQueryResult {
        engine.literalQuery(request, rootID: rootID, limit: limit, excludeHit: excludeHit)
    }
    func save(to url: URL) throws { try engine.saveBinaryIndex(to: url) }
    static func load(from url: URL) throws -> EngineIndex {
        EngineIndex(engine: try SearchEngine.loadBinaryIndex(from: url))
    }
}

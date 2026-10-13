// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

enum FileDragError: Error, LocalizedError {
    case staleResults
    case invalidSelection
    case offline(String)
    case missing(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .staleResults: return "搜索结果正在更新，请等搜索完成后重新选择。"
        case .invalidSelection: return "所选项目已经变化，请重新选择。"
        case .offline(let name): return "“\(name)”所在磁盘已断开，请连接后重试。"
        case .missing(let name): return "“\(name)”已不存在或暂时无法访问，请刷新结果并检查磁盘状态。"
        case .unreadable(let name): return "无法读取“\(name)”，请检查文件访问权限。"
        }
    }
}

enum FileDragSource {
    static func recordQAEvent(_ event: String) {
        guard RuntimePaths.isTestingInstance else { return }
        let url = RuntimePaths.dataDirectory.appendingPathComponent("drag-events.txt")
        let line = Data((event + "\n").utf8)
        if let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: line)
        } else { try? line.write(to: url) }
    }
    /// Capture only the selected paths. File checks never run during searches or
    /// result loading, and no file contents or directory trees are read here.
    /// Refuse the whole selection rather than silently exporting only part of it.
    static func prepare(results: [FileHit], rows: IndexSet, resultsAreCurrent: Bool,
                        fileManager: FileManager = .default) throws -> [Int: NSURL] {
        guard resultsAreCurrent else { throw FileDragError.staleResults }
        guard !rows.isEmpty else { throw FileDragError.invalidSelection }
        var items: [Int: NSURL] = [:]
        for row in rows {
            guard results.indices.contains(row) else { throw FileDragError.invalidSelection }
            let hit = results[row]
            guard hit.path.hasPrefix("/") else { throw FileDragError.invalidSelection }
            guard hit.isOnline else { throw FileDragError.offline(hit.name) }
            var directory: ObjCBool = false
            guard fileManager.fileExists(atPath: hit.path, isDirectory: &directory) else {
                // fileExists returns false for both missing paths and an
                // inaccessible parent. Preserve the useful permission reason.
                let (status, reason) = hit.path.withCString { pointer -> (Int32, Int32) in
                    let status = access(pointer, F_OK)
                    return (status, errno)
                }
                if status != 0 && (reason == EACCES || reason == EPERM) {
                    throw FileDragError.unreadable(hit.name)
                }
                throw FileDragError.missing(hit.name)
            }
            guard fileManager.isReadableFile(atPath: hit.path),
                  !directory.boolValue || fileManager.isExecutableFile(atPath: hit.path) else {
                throw FileDragError.unreadable(hit.name)
            }
            items[row] = NSURL(fileURLWithPath: hit.path)
        }
        return items
    }
}

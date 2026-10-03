import Foundation

enum SearchKind: String, CaseIterable {
    case all = "全部", files = "文件", folders = "文件夹"
}

struct SearchRequest {
    var query: String
    var kind: SearchKind = .all
    var extensionFilter: String = ""
    var matchPath: Bool = false
    var rootID: String? = nil
    var sizeFilter: String = ""
    var modifiedFilter: String = ""
    var filters: SearchFilters = SearchFilters()
    var cancellation: CancellationFlag? = nil
    var parsedPlan: AdvancedSearchPlan? = nil
}

struct FileHit: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let isDirectory: Bool
    let rootID: String
    var isOnline: Bool = true
    var size: Int64? = nil
    var modifiedDate: Date? = nil
    var createdDate: Date? = nil
    var name: String { (path as NSString).lastPathComponent }
    var parentPath: String { (path as NSString).deletingLastPathComponent }
}

struct EngineQueryResult {
    var hits: [FileHit]
    var totalMatches: Int
}

struct SearchBatch {
    var hits: [FileHit]
    var totalMatches: Int
    var elapsedMilliseconds: Double
}

struct RootRecord: Codable, Identifiable, Equatable {
    var id: String
    var path: String
    var name: String
    var volumeID: String
}

struct RootStatus: Identifiable, Equatable {
    let record: RootRecord
    var id: String { record.id }
    var name: String { record.name }
    var path: String { record.path }
    var count: Int = 0
    var isOnline: Bool = true
    var state: String = "等待扫描"
    var lastUpdated: Date? = nil
    var issueCount: Int = 0
}

struct ScanIssue: Codable, Identifiable {
    var id: String { path + message }
    var path: String
    var message: String
}

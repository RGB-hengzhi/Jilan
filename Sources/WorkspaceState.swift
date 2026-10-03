import Foundation

struct WorkspacePaneState: Codable {
    var paths: [String]
    var selectedTab: Int
}

struct WorkspaceSession: Codable {
    var version = 1
    var panes: [WorkspacePaneState]
    var activePane = 0
    var favorites: [String]
    var showHidden = false
    var previewVisible = true
    var dualPane = true
}

enum WorkspaceSessionStore {
    static var directory: URL { RuntimePaths.dataDirectory }

    static var file: URL { directory.appendingPathComponent("workspace-session.json") }

    static func load(from file: URL = WorkspaceSessionStore.file) -> WorkspaceSession? {
        guard let data = try? Data(contentsOf: file),
              let session = try? JSONDecoder().decode(WorkspaceSession.self, from: data),
              session.version == 1, session.panes.count == 2 else { return nil }
        return session
    }

    static func save(_ session: WorkspaceSession, to file: URL = WorkspaceSessionStore.file) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: file, options: .atomic)
    }

    static var defaultFavorites: [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        return [home, home + "/Desktop", home + "/Documents", home + "/Downloads", "/Applications", "/Volumes"]
    }
}

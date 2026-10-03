import Foundation

enum WorkspaceSessionTests {
    static func run() throws -> [String: Any] {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("QuickFindWorkspaceSession-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("workspace-session.json")
        let expected = WorkspaceSession(panes: [
            WorkspacePaneState(paths: ["/测试目录/左栏甲", "/测试目录/左栏乙"], selectedTab: 1),
            WorkspacePaneState(paths: ["/测试目录/右栏", "/Volumes"], selectedTab: 0)
        ], activePane: 1, favorites: ["/测试目录/收藏一", "/测试目录/收藏二"],
           showHidden: true, previewVisible: false, dualPane: false)
        try WorkspaceSessionStore.save(expected, to: file)
        guard let loaded = WorkspaceSessionStore.load(from: file) else { throw EngineTestError.failed("工作区会话不能恢复") }
        guard loaded.panes.count == 2,
              loaded.panes[0].paths == expected.panes[0].paths,
              loaded.panes[1].paths == expected.panes[1].paths,
              loaded.panes[0].selectedTab == 1, loaded.panes[1].selectedTab == 0,
              loaded.activePane == 1, loaded.favorites == expected.favorites,
              loaded.showHidden, !loaded.previewVisible, !loaded.dualPane else {
            throw EngineTestError.failed("工作区双栏标签、收藏、活动栏或显示设置恢复不一致")
        }
        try Data("损坏的 JSON".utf8).write(to: file)
        guard WorkspaceSessionStore.load(from: file) == nil else { throw EngineTestError.failed("损坏会话没有安全回退") }
        var unsupported = expected; unsupported.version = 999
        try WorkspaceSessionStore.save(unsupported, to: file)
        guard WorkspaceSessionStore.load(from: file) == nil else { throw EngineTestError.failed("未知会话版本没有安全回退") }
        var incomplete = expected; incomplete.panes.removeLast()
        try WorkspaceSessionStore.save(incomplete, to: file)
        guard WorkspaceSessionStore.load(from: file) == nil else { throw EngineTestError.failed("不足双栏的会话可能导致数组越界") }
        guard WorkspaceSessionStore.load(from: fixture.appendingPathComponent("缺失.json")) == nil else {
            throw EngineTestError.failed("缺失会话没有安全回退")
        }
        return ["result": "passed", "checks": ["双栏标签顺序和选中标签精确恢复", "活动栏、收藏、隐藏文件、预览及单双栏恢复", "损坏和缺失 JSON 回退", "未知版本和不足双栏回退"], "isolatedFixture": true]
    }
}

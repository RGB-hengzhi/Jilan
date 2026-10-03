// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum PathCoverageTestError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

enum PathCoverageTests {
    static func run() throws -> [String: Any] {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw PathCoverageTestError.failed(message) }
        }
        let empty = PathCoverage([])
        try expect(!empty.contains("/") && !empty.contains("/a"), "空受限集合误覆盖路径")

        let subtree = PathCoverage(["/a", "/中文目录/家庭资料/", "/abc/nested"])
        for path in ["/a", "/a/", "/a/file.txt", "/a/深层/文件",
                     "/中文目录/家庭资料", "/中文目录/家庭资料/报告.pdf", "/abc/nested/child"] {
            try expect(subtree.contains(path), "受限子树漏匹配：\(path)")
        }
        for path in ["/", "/a-old", "/aa", "/abc", "/abc/nested-old/child",
                     "/中文目录", "/中文目录/家庭资料旧/报告.pdf", "a", ""] {
            try expect(!subtree.contains(path), "目录边界误匹配：\(path)")
        }
        for paths in [["/a/deep", "/a"], ["/a", "/a/deep"], ["/a/", "/a", "/a/deep/"]] {
            let nested = PathCoverage(paths)
            try expect(nested.contains("/a/other/file") && nested.contains("/a/deep/file"),
                       "受限路径顺序影响嵌套覆盖")
            try expect(!nested.contains("/a-old/file"), "嵌套去重误覆盖兄弟目录")
        }
        let root = PathCoverage(["/a", "/", "/中文"])
        try expect(root.contains("/") && root.contains("/a") && root.contains("/其他目录/文件"),
                   "根目录受限未覆盖所有绝对路径")
        try expect(!root.contains("relative/file") && !root.contains(""), "根覆盖相对路径")

        // Check many distinct issue paths against the simple boundary rule on
        // a small deterministic fixture, including similar sibling names.
        let issuePaths = (0..<800).map { "/Users/用户/目录\($0)/受限资料" }
        let indexed = PathCoverage(issuePaths)
        for index in 0..<1200 {
            for suffix in ["", "/文件.txt", "-旧/文件.txt"] {
                let path = "/Users/用户/目录\(index)/受限资料" + suffix
                let expected = issuePaths.contains { path == $0 || path.hasPrefix($0 + "/") }
                try expect(indexed.contains(path) == expected, "大量受限路径匹配与边界规则不一致")
            }
        }
        return ["result": "passed", "issuePaths": issuePaths.count,
                "generatedComparisonChecks": 3600,
                "coverage": "absolute root, UTF8 Chinese, directory boundaries, nested prefixes, trailing slash"]
    }
}

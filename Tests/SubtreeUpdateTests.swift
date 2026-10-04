// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum SubtreeUpdateTests {
    static func run() throws -> [String: Any] {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw EngineTestError.failed(message) }
        }
        let index = EngineIndex()
        // Children may survive a restricted scan without their ancestor node.
        // Removing that absent ancestor still has to remove its descendants.
        let removed = ["/更新/école/报告.txt", "/更新/école/深层/附件.pdf"]
        let retained = ["/更新/école2/报告.txt", "/其他/école/报告.txt"]
        for path in removed + retained { index.add(path: path, isDirectory: false) }
        try check(!index.removeSubtree(path: "/更新/unknown.txt") && index.count == 4,
                  "未知且无子项的删除提示不能改动索引")
        try check(index.removeSubtree(path: "/更新/e\u{0301}cole/"),
                  "NFC/NFD 等价目录及尾部斜线须匹配共享父目录")
        try check(index.count == 2 && retained.allSatisfy { index.hasPath($0) }
                  && removed.allSatisfy { !index.hasPath($0) },
                  "缺失祖先的子树删除须保留同名前缀兄弟及其他目录")
        try check(!index.removeSubtree(path: "/更新/école"), "重复删除不能报告名称变化")
        index.add(path: "/更新/真实目录", isDirectory: true)
        index.add(path: "/更新/真实目录/a.txt", isDirectory: false)
        try check(index.removeSubtree(path: "/更新/真实目录") && index.count == 2,
                  "真实目录节点与后代须一起删除")
        index.add(path: "/", isDirectory: true)
        try check(index.removeSubtree(path: "/") && index.count == 0,
                  "根目录删除须清除根节点及所有绝对路径")
        try check(!index.removeSubtree(path: "") && !index.removeSubtree(path: "/"),
                  "空路径与空索引重复删除须无变化")
        index.add(path: "/canonical/K/child.txt", isDirectory: false)
        index.add(path: "/canonical/K2/retained.txt", isDirectory: false)
        try check(index.removeSubtree(path: "/canonical/K") && index.count == 1
                  && index.hasPath("/canonical/K2/retained.txt"),
                  "ASCII 前缀快路径须保留 Kelvin sign 与 K 的规范等价及兄弟边界")
        return ["status": "passed", "unknownDeletionUnchanged": true,
                "missingAncestorDescendantsRemoved": true, "unicodeEquivalentParents": true,
                "siblingBoundaryPreserved": true, "rootDeletion": true]
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Matches an absolute path or any descendant at a directory boundary.
/// Construct once for a set of inaccessible subtrees; each lookup is linear
/// in the path's UTF-8 bytes, independent of the number of scan issues.
struct PathCoverage {
    private struct Node {
        var children: [UInt8: Int] = [:]
        var terminal = false
    }

    private let nodes: [Node]
    private let coversRoot: Bool

    init(_ paths: [String]) {
        var trie = [Node()]
        var root = false
        for path in paths {
            var bytes = Array(path.utf8)
            guard bytes.first == 47 else { continue }
            while bytes.count > 1, bytes.last == 47 { bytes.removeLast() }
            if bytes.count == 1 {
                root = true
                break
            }
            var cursor = 0
            var alreadyCovered = false
            for byte in bytes {
                if trie[cursor].terminal, byte == 47 {
                    alreadyCovered = true
                    break
                }
                if let next = trie[cursor].children[byte] {
                    cursor = next
                } else {
                    let next = trie.count
                    trie.append(Node())
                    trie[cursor].children[byte] = next
                    cursor = next
                }
            }
            if !alreadyCovered {
                trie[cursor].terminal = true
                // Descendants of a newly inserted ancestor need no further lookup.
                trie[cursor].children.removeAll(keepingCapacity: false)
            }
        }
        nodes = root ? [Node()] : trie
        coversRoot = root
    }

    func contains(_ path: String) -> Bool {
        guard path.utf8.first == 47 else { return false }
        if coversRoot { return true }
        var cursor = 0
        for byte in path.utf8 {
            if nodes[cursor].terminal, byte == 47 { return true }
            guard let next = nodes[cursor].children[byte] else { return false }
            cursor = next
        }
        return nodes[cursor].terminal
    }
}

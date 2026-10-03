import Foundation
import Darwin

struct DirectoryEntry {
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let isSymbolicLink: Bool
    var name: String { (path as NSString).lastPathComponent }
}

/// Directory browsing is separate from the filename index. Only the current
/// directory is inspected, and symbolic links are never traversed while listing.
final class DirectoryBrowser {
    private let queue = DispatchQueue(label: "cn.local.quickfind.directory-browser", qos: .userInitiated,
                                      attributes: .concurrent)

    func load(path: String, showHidden: Bool = false,
              completion: @escaping (Result<[DirectoryEntry], Error>) -> Void) {
        queue.async {
            let result = Result { () throws -> [DirectoryEntry] in
                guard path.hasPrefix("/") else {
                    throw NSError(domain: "QuickFind.DirectoryBrowser", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "目录必须使用完整路径。"])
                }
                let directory = URL(fileURLWithPath: path, isDirectory: true).standardized
                let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
                let children = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isHiddenKey], options: options)
                var entries: [DirectoryEntry] = []
                entries.reserveCapacity(children.count)
                for child in children {
                    // Foundation may return /private/var children for a /var
                    // directory. Keep the pane's actual lexical path stable.
                    let childPath = (directory.path == "/" ? "" : directory.path) + "/" + child.lastPathComponent
                    var info = stat()
                    let status = childPath.withCString { lstat($0, &info) }
                    // A file can disappear between enumeration and metadata lookup.
                    if status != 0 && errno == ENOENT { continue }
                    if !showHidden && (child.lastPathComponent.hasPrefix(".") ||
                        (try? child.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true) { continue }
                    let kind = info.st_mode & mode_t(S_IFMT)
                    let link = status == 0 && kind == mode_t(S_IFLNK)
                    entries.append(DirectoryEntry(path: childPath,
                        isDirectory: status == 0 && kind == mode_t(S_IFDIR),
                        size: status == 0 && kind == mode_t(S_IFREG) ? Int64(info.st_size) : nil,
                        modified: status == 0 ? Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) +
                            Double(info.st_mtimespec.tv_nsec) / 1_000_000_000) : nil,
                        isSymbolicLink: link))
                }
                return entries.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

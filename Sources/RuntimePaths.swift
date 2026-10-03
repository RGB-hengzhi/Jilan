// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum RuntimePaths {
    static var isTestingInstance: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true }
    static var dataDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["QUICKFIND_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        // An isolated, separately identified QA bundle can exercise the native
        // UI without touching the installed application's index or preferences.
        if isTestingInstance,
           let path = Bundle.main.object(forInfoDictionaryKey: "QuickFindTestingDataDirectory") as? String,
           path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuickFind", isDirectory: true)
    }
}

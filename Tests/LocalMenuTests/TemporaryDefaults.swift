import Foundation
import Testing

/// A preferences suite private to one test. Removing the domain leaves an empty plist behind, so `remove()`
/// deletes that file too.
struct TemporaryDefaults {
    let suite = "LocalMenuTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        CFPreferencesAppSynchronize(suite as CFString)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/\(suite).plist"))
    }
}

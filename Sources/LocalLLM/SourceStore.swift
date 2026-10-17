import CryptoKit
import Foundation

public struct SourceStore: Sendable {
    public let directory: URL
    private var bookmarkURL: URL { directory.appending(path: "selection.bookmark") }

    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "LocalMenu/Sources")) {
        self.directory = directory
    }

    public func indexURL(for source: URL) throws -> URL {
        try prepareDirectory()
        let path = source.resolvingSymlinksInPath().standardizedFileURL.path
        let hash = SHA256.hash(data: Data(path.utf8)).map { ("0" + String($0, radix: 16)).suffix(2) }.joined()
        return directory.appending(path: "\(hash).sqlite")
    }

    public func remember(_ source: URL) throws {
        let data = try source.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil)
        try prepareDirectory()
        try data.write(to: bookmarkURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bookmarkURL.path)
    }

    public func restoredURL() throws -> URL? {
        guard FileManager.default.fileExists(atPath: bookmarkURL.path) else { return nil }
        var stale = false
        return try URL(resolvingBookmarkData: Data(contentsOf: bookmarkURL),
            options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    public func forget() throws {
        // This directory contains only LocalMenu's bookmarks and extracted index, never original files.
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw DocumentError.indexStorage("dossier d'index symbolique refusé")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}

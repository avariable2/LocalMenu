import Foundation

final class DocumentIndex: Sendable {
    let url: URL
    private let temporary: Bool

    init(url: URL? = nil) throws {
        temporary = url == nil
        self.url = url ?? FileManager.default.temporaryDirectory.appending(path: "localmenu-\(UUID().uuidString).sqlite")
        let parent = self.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: self.url.path) {
            guard try self.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw DocumentError.indexStorage("lien symbolique refusé")
            }
        } else {
            guard FileManager.default.createFile(atPath: self.url.path, contents: Data(),
                attributes: [.posixPermissions: 0o600]) else { throw DocumentError.indexStorage("création impossible") }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
    }

    deinit {
        if temporary { try? FileManager.default.removeItem(at: url) }
    }
}

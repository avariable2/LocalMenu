import Foundation
import LocalLLM
import Testing
@testable import LocalMenu

@MainActor
struct SourceSelectionTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForIdle(_ model: ChatModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isLoading, "Une sélection ne doit pas laisser le bouton bloqué")
    }

    @Test func rapidSelectionsKeepOnlyLastRequestAndReleaseBusyState() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SourceStore(directory: root.appending(path: "cache"))
        let model = ChatModel(store: store)
        for index in 0..<30 {
            let directory = root.appending(path: "repo-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("Projet \(index). Budget 7300 euros.".utf8).write(to: directory.appending(path: "note.txt"))
            model.loadSource(directory)
            #expect(model.canChooseSource)
        }
        try await waitForIdle(model)
        #expect(model.attachment?.name == "repo-29")
        #expect(model.error == nil)
        let selected = try store.restoredURL()
        #expect(selected?.lastPathComponent == "repo-29")
        model.removeAttachment()
        #expect(model.attachment == nil)
    }

    @Test func replacesRunningIndexAndRecoversAfterInvalidSelection() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let large = root.appending(path: "large.txt")
        try Data(String(repeating: "Le projet progresse avec son budget.\n", count: 200_000).utf8).write(to: large)
        let small = root.appending(path: "small.txt")
        try Data("Destination finale.".utf8).write(to: small)
        let model = ChatModel(store: SourceStore(directory: root.appending(path: "cache")))
        model.loadSource(large)
        try await Task.sleep(for: .milliseconds(25))
        #expect(model.canChooseSource)
        model.loadSource(small)
        try await waitForIdle(model)
        #expect(model.attachment?.name == "small.txt")
        let invalid = root.appending(path: "invalid.txt")
        try Data([0, 255]).write(to: invalid)
        model.loadSource(invalid)
        try await waitForIdle(model)
        #expect(model.error != nil)
        #expect(model.canChooseSource)
        model.loadSource(small)
        try await waitForIdle(model)
        #expect(model.error == nil)
        #expect(model.attachment?.name == "small.txt")
        model.removeAttachment()
    }

    @Test func remembersEngineChoiceAcrossLaunches() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = try TemporaryDefaults()
        defer { preferences.remove() }
        let defaults = preferences.defaults
        let store = SourceStore(directory: root.appending(path: "cache"))
        let first = ChatModel(store: store, defaults: defaults)
        #expect(first.engine == .local)
        first.engine = .claudeCode
        #expect(ChatModel(store: store, defaults: defaults).engine == .claudeCode)
    }

    @Test func restoresPermissionAndCanPauseWithoutDeletingIndex() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "note.txt")
        try Data("Projet test.".utf8).write(to: url)
        let store = SourceStore(directory: root.appending(path: "cache"))
        let first = ChatModel(store: store)
        first.loadSource(url)
        try await waitForIdle(first)
        #expect(first.usesDocuments)
        first.useSources = false
        #expect(!first.usesDocuments)
        #expect(first.attachment != nil)
        let saved = try store.restoredURL()
        #expect(saved != nil)
        let restored = ChatModel(store: store)
        try await waitForIdle(restored)
        #expect(restored.attachment?.name == "note.txt")
        #expect(restored.attachment?.indexedFileCount == 0)
        restored.clear()
        let forgotten = try store.restoredURL()
        #expect(forgotten == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

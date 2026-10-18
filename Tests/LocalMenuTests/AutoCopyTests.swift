import AppKit
import LocalLLM
import Testing
@testable import LocalMenu

/// Runs a full question through the Claude Code engine, backed by a stand-in `claude`, against a private pasteboard.
@MainActor
struct AutoCopyTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let preferences: TemporaryDefaults
        let pasteboard = NSPasteboard(name: .init("LocalMenuTests-\(UUID().uuidString)"))
        var defaults: UserDefaults { preferences.defaults }

        init() throws {
            preferences = try TemporaryDefaults()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let response = """
                {"type":"result","is_error":false,"result":"{}","structured_output":\
                {"answer":"Le **T4** culmine à 240 k€ [S1].","sources":[{"file":"rapport.pdf","location":"page 2"}]}}
                """
            try Data(response.utf8).write(to: root.appending(path: "response.json"))
            let script = root.appending(path: "claude")
            try Data("#!/bin/sh\ncat > /dev/null\ncat \"\(root.path)/response.json\"\n".utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            defaults.set(Engine.claudeCode.rawValue, forKey: "engine")
        }

        @MainActor func model() -> ChatModel {
            ChatModel(store: SourceStore(directory: root.appending(path: "cache")),
                      claude: ClaudeCodeClient(executable: root.appending(path: "claude")),
                      defaults: defaults, pasteboard: pasteboard)
        }

        func remove() {
            preferences.remove()
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func ask(_ model: ChatModel) async throws {
        model.question = "Quel trimestre ?"
        model.submit()
        #expect(model.isAnswering)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.error == nil)
        #expect(!model.answer.isEmpty)
    }

    @Test func copiesCompleteAnswerAsPlainTextOnlyWhenEnabled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("presse-papiers de l'utilisateur", forType: .string)
        let model = fixture.model()
        #expect(!model.autoCopy)
        try await ask(model)
        #expect(!model.justCompleted && !model.justCopied, "Ni barre ni coche sans l'option")
        #expect(fixture.pasteboard.string(forType: .string) == "presse-papiers de l'utilisateur")

        model.autoCopy = true
        try await ask(model)
        #expect(model.justCompleted && model.justCopied)
        #expect(fixture.pasteboard.string(forType: .string) == "Le T4 culmine à 240 k€ [S1].\n\n[S1] rapport.pdf · page 2")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.justCopied || model.justCompleted, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!model.justCompleted && !model.justCopied, "Les confirmations s'effacent d'elles-mêmes")
        #expect(fixture.model().autoCopy, "Le choix est mémorisé")
    }

    @Test func manualCopyAndFailuresLeaveClipboardAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.copyAnswer()
        #expect(!model.justCopied, "Rien à copier sans réponse")
        try await ask(model)
        model.copyAnswer()
        #expect(model.justCopied)
        #expect(!model.justCompleted, "Une copie manuelle ne simule pas une fin de génération")
        #expect(fixture.pasteboard.string(forType: .string)?.hasPrefix("Le T4 culmine") == true)

        fixture.pasteboard.clearContents()
        model.autoCopy = true
        try FileManager.default.removeItem(at: fixture.root.appending(path: "response.json"))
        model.question = "Encore ?"
        model.submit()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.error != nil)
        #expect(!model.justCompleted)
        #expect(fixture.pasteboard.string(forType: .string) == nil)
    }
}

import SwiftUI
import LocalLLM

enum Engine: String, CaseIterable {
    case local, claudeCode

    var title: String {
        switch self {
        case .local: "Local (Ollama)"
        case .claudeCode: "Claude Code (cloud)"
        }
    }
}

@MainActor
@Observable
final class ChatModel {
    var question = ""
    var answer = ""
    var error: String?
    var useSources = true {
        didSet { answer = ""; sources = [] }
    }
    var engine: Engine {
        didSet {
            answer = ""
            sources = []
            error = nil
            defaults.set(engine.rawValue, forKey: Self.engineKey)
        }
    }
    /// Puts each finished answer on the clipboard instead of showing it, with a generation bar and a copy button.
    var autoCopy: Bool {
        didSet { defaults.set(autoCopy, forKey: Self.autoCopyKey) }
    }
    var usesDocuments: Bool { useSources && attachment != nil }
    private(set) var attachment: DocumentLibrary?
    private(set) var sources: [SourceReference] = []
    private(set) var activity = ""
    /// Briefly true once a complete answer arrives, and after each copy, so the view can confirm it.
    private(set) var justCompleted = false
    private(set) var justCopied = false
    var isLoading: Bool { operation != .idle }
    var isAnswering: Bool { operation == .answer }
    var canChooseSource: Bool { operation != .answer }
    var canRefreshSources: Bool { sourceURL != nil && !isLoading }
    private var operation = Operation.idle
    private var requestID = UUID()
    private var task: Task<Void, Never>?
    private var completionFlash: Task<Void, Never>?
    private var copyFlash: Task<Void, Never>?
    private var sourceURL: URL?
    private let client: OllamaClient
    private let claude: ClaudeCodeClient
    private let store: SourceStore
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private let picker = SourcePicker()
    private static let engineKey = "engine"
    private static let autoCopyKey = "autoCopy"

    private enum Operation { case idle, answer, index }

    init(store: SourceStore = SourceStore(), client: OllamaClient = OllamaClient(),
         claude: ClaudeCodeClient = ClaudeCodeClient(), defaults: UserDefaults = .standard,
         pasteboard: NSPasteboard = .general) {
        self.store = store
        self.client = client
        self.claude = claude
        self.defaults = defaults
        self.pasteboard = pasteboard
        engine = defaults.string(forKey: Self.engineKey).flatMap(Engine.init) ?? .local
        autoCopy = defaults.bool(forKey: Self.autoCopyKey)
        do {
            if let url = try store.restoredURL() { loadSource(url) }
        } catch {
            self.error = "Sources mémorisées inaccessibles. Choisissez-les à nouveau : \(error.localizedDescription)"
        }
    }

    func submit() {
        guard !isLoading, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let question = question
        let attachment = usesDocuments ? attachment : nil
        let source = attachment == nil ? nil : sourceURL
        let engine = engine
        let id = UUID()
        requestID = id
        error = nil
        answer = ""
        sources = []
        activity = switch (engine, attachment == nil) {
        case (.local, true): "Réflexion en cours"
        case (.local, false): "Recherche dans les documents"
        case (.claudeCode, true): "Claude Code réfléchit"
        case (.claudeCode, false): "Claude Code lit les documents"
        }
        operation = .answer
        task = Task {
            defer { finish(id) }
            do {
                if engine == .claudeCode {
                    let result = try await claude.answer(question: question, source: source, library: attachment)
                    try Task.checkCancellation()
                    answer = result.text
                    sources = result.sources
                } else if let attachment {
                    let result = try await client.answer(question: question, library: attachment)
                    try Task.checkCancellation()
                    answer = result.text
                    sources = result.sources
                } else {
                    let result = try await client.answer(question: question)
                    try Task.checkCancellation()
                    answer = result
                }
                self.question = ""
                if autoCopy {
                    completionFlash = flash(\.justCompleted, for: .seconds(1.2), replacing: completionFlash)
                    copyAnswer()
                }
            } catch is CancellationError {
            } catch let failure as URLError where failure.code == .cancelled {
            } catch let failure as URLError where failure.code == .cannotConnectToHost {
                error = "Ollama est inaccessible. Installez-le si nécessaire, puis démarrez-le avec ollama serve."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func chooseSource() {
        guard canChooseSource else { return }
        picker.choose { [weak self] url in self?.loadSource(url) }
    }

    func refreshSources() {
        guard canRefreshSources, let sourceURL else { return }
        loadSource(sourceURL)
    }

    func loadSource(_ url: URL) {
        guard canChooseSource else { return }
        let previous = task
        previous?.cancel()
        let id = UUID()
        requestID = id
        operation = .index
        sourceURL = url
        useSources = true
        attachment = nil
        answer = ""
        sources = []
        error = nil
        activity = "Lecture et indexation des sources"
        task = Task {
            // Wait for cancellation to release the old file permissions and database transaction.
            await previous?.value
            defer { finish(id) }
            do {
                try Task.checkCancellation()
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                let indexURL = try store.indexURL(for: url)
                let model = self
                let worker = Task.detached(priority: .userInitiated) {
                    try DocumentLibrary(url: url, indexURL: indexURL, onProgress: { message in
                        Task { @MainActor in
                            guard model.requestID == id, model.operation == .index else { return }
                            model.activity = message
                        }
                    })
                }
                let library = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard requestID == id else { return }
                try store.remember(url)
                attachment = library
            } catch is CancellationError {
            } catch {
                if requestID == id { self.error = error.localizedDescription }
            }
        }
    }

    func removeAttachment() {
        guard !isLoading else { return }
        attachment = nil
        sourceURL = nil
        answer = ""
        sources = []
        error = nil
        do { try store.forget() }
        catch { self.error = "Effacement de l'index impossible : \(error.localizedDescription)" }
    }

    func copyAnswer() {
        guard !answer.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(Self.clipboardText(answer, sources: sources), forType: .string)
        copyFlash = flash(\.justCopied, for: .seconds(2), replacing: copyFlash)
    }

    private func flash(_ flag: ReferenceWritableKeyPath<ChatModel, Bool>, for duration: Duration,
                       replacing previous: Task<Void, Never>?) -> Task<Void, Never> {
        previous?.cancel()
        self[keyPath: flag] = true
        return Task {
            do { try await Task.sleep(for: duration) } catch { return }
            self[keyPath: flag] = false
        }
    }

    /// Plain text pastes cleanly anywhere: inline Markdown is rendered away, citations keep their references.
    static func clipboardText(_ answer: String, sources: [SourceReference]) -> String {
        let text = (try? AttributedString(markdown: answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? answer
        guard !sources.isEmpty else { return text }
        return ([text, ""] + sources.map { "[\($0.id)] \($0.file) · \($0.location)" }).joined(separator: "\n")
    }

    func cancel() {
        activity = "Annulation en cours"
        task?.cancel()
    }

    func clear() {
        guard !isLoading else { return }
        question = ""
        removeAttachment()
    }

    private func finish(_ id: UUID) {
        guard requestID == id else { return }
        operation = .idle
        task = nil
    }
}

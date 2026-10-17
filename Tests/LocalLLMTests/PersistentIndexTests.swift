import Foundation
import Testing
@testable import LocalLLM

struct PersistentIndexTests {
    @Test func reusesUnchangedFilesAndRemovesDeletedOrChangedContent() throws {
        try DocumentFixtures.withDirectory { root in
            let folder = root.appending(path: "sources")
            let cache = root.appending(path: "index.sqlite")
            let first = folder.appending(path: "first.txt")
            let second = folder.appending(path: "second.txt")
            try DocumentFixtures.write("ANCIEN_SECRET livraison janvier", to: first)
            try DocumentFixtures.write("ARCHIVE supprimée", to: second)
            let initial = try DocumentLibrary(url: folder, indexURL: cache)
            #expect(initial.indexedFileCount == 2)
            let old = try initial.search("ANCIEN_SECRET")
            let cached = try DocumentLibrary(url: folder, indexURL: cache)
            #expect(cached.indexedFileCount == 0)
            let same = try cached.search("ANCIEN_SECRET")
            #expect(same.first?.id == old.first?.id)
            try DocumentFixtures.write("NOUVELLE_REFERENCE livraison le 18 décembre 2027", to: first)
            try FileManager.default.removeItem(at: second)
            let refreshed = try DocumentLibrary(url: folder, indexURL: cache)
            #expect(refreshed.fileCount == 1)
            #expect(refreshed.indexedFileCount == 1)
            let previous = try refreshed.search("ANCIEN_SECRET ARCHIVE")
            let updated = try refreshed.search("NOUVELLE_REFERENCE")
            #expect(previous.isEmpty)
            #expect(updated.first?.text.contains("18 décembre 2027") == true)
        }
    }

    @Test func rebuildsIndexesMadeByOlderExtractors() throws {
        try DocumentFixtures.withDirectory { root in
            let folder = root.appending(path: "sources")
            let cache = root.appending(path: "index.sqlite")
            try DocumentFixtures.write("Rapport HELIOS", to: folder.appending(path: "rapport.txt"))
            #expect(try DocumentLibrary(url: folder, indexURL: cache).indexedFileCount == 1)
            #expect(try DocumentLibrary(url: folder, indexURL: cache).indexedFileCount == 0)
            try IndexDatabase(url: cache, writable: true).execute("PRAGMA user_version=1")
            let rebuilt = try DocumentLibrary(url: folder, indexURL: cache)
            #expect(rebuilt.indexedFileCount == 1)
            #expect(try rebuilt.search("HELIOS").count == 1)
        }
    }

    @Test func cancelledRefreshRollsBackPreviousIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.txt")
        let cache = root.appending(path: "index.sqlite")
        try DocumentFixtures.write("ANCIEN état validé", to: file)
        let previous = try DocumentLibrary(url: file, indexURL: cache)
        try DocumentFixtures.write("NOUVEAU état en cours d'indexation", to: file)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let gate = IndexProgressGate(ready: continuation)
        defer { gate.release(); continuation.finish() }
        let worker = Task.detached {
            try DocumentLibrary(url: file, indexURL: cache, onProgress: { gate.blockOnText($0) })
        }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        worker.cancel()
        gate.release()
        do {
            _ = try await worker.value
            Issue.record("Annulation attendue")
        } catch is CancellationError {
        }
        let preserved = try previous.search("ANCIEN")
        let incomplete = try previous.search("NOUVEAU")
        #expect(!preserved.isEmpty)
        #expect(incomplete.isEmpty)
        let completed = try DocumentLibrary(url: file, indexURL: cache)
        #expect(completed.indexedFileCount == 1)
    }

    @Test func scopesDoNotShareContentAndCanBeForgotten() throws {
        try DocumentFixtures.withDirectory { root in
            let first = root.appending(path: "one/source.txt")
            let second = root.appending(path: "two/source.txt")
            try DocumentFixtures.write("ALPHA uniquement", to: first)
            try DocumentFixtures.write("BETA uniquement", to: second)
            let store = SourceStore(directory: root.appending(path: "private-cache"))
            let oneURL = try store.indexURL(for: first)
            let twoURL = try store.indexURL(for: second)
            #expect(oneURL != twoURL)
            let one = try DocumentLibrary(url: first, indexURL: oneURL)
            let two = try DocumentLibrary(url: second, indexURL: twoURL)
            let unrelated = try one.search("BETA") + two.search("ALPHA")
            #expect(unrelated.isEmpty)
            try store.remember(first)
            let restoredURL = try store.restoredURL()
            let restored = try #require(restoredURL)
            #expect(restored.resolvingSymlinksInPath().path == first.resolvingSymlinksInPath().path)
            let attributes = try FileManager.default.attributesOfItem(atPath: oneURL.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            try store.forget()
            #expect(!FileManager.default.fileExists(atPath: store.directory.path))
            #expect(FileManager.default.fileExists(atPath: first.path))
            #expect(FileManager.default.fileExists(atPath: second.path))
            let forgotten = try store.restoredURL()
            #expect(forgotten == nil)
        }
    }

    @Test func filenameFilterAndFTSInputCannotEscapeScope() throws {
        try DocumentFixtures.withDirectory { root in
            try DocumentFixtures.write("Informations alpha", to: root.appending(path: "Contrat_Été.pdf.txt"))
            try DocumentFixtures.write("Informations beta", to: root.appending(path: "autre.txt"))
            let library = try DocumentLibrary(url: root)
            let files = try library.list(offset: 0, query: "contrat_ete")
            #expect(files.contains("Contrat_Été.pdf.txt"))
            #expect(!files.contains("autre.txt"))
            let injection = try library.list(offset: 0, query: "' OR 1=1 --")
            #expect(!injection.contains("autre.txt"))
            let special = try library.search("\"* OR () --")
            #expect(special.isEmpty)
        }
    }

    @Test func streamingPreservesUnicodeBOMAndCRLFAcrossBlocks() throws {
        try DocumentFixtures.withDirectory { root in
            let text = String(repeating: "début é😀 fin\r\n", count: 12_000) + "DERNIÈRE_LIGNE\r\n"
            for encoding in [String.Encoding.utf8, .utf16] {
                let url = root.appending(path: "unicode-\(encoding.rawValue).txt")
                let data = try #require(text.data(using: encoding))
                try data.write(to: url)
                var pieces: [ExtractedSection] = []
                try TextDocumentReader.forEach(url: url) { pieces.append($0) }
                #expect(pieces.count > 1)
                #expect(pieces.map(\.text).joined() == text)
                #expect(pieces.last?.startLine == pieces.dropLast().reduce(1) { $0 + $1.text.filter(\.isNewline).count })
            }
        }
    }

    @Test func repeatedFolderChangesAndErrorsDoNotPoisonOtherIndexes() throws {
        try DocumentFixtures.withDirectory { root in
            let store = SourceStore(directory: root.appending(path: "cache"))
            let one = root.appending(path: "one/note.txt")
            let two = root.appending(path: "two/note.txt")
            try DocumentFixtures.write("ALPHA", to: one)
            try DocumentFixtures.write("BETA", to: two)
            for iteration in 0..<30 {
                let file = iteration.isMultiple(of: 2) ? one : two
                let library = try DocumentLibrary(url: file, indexURL: store.indexURL(for: file))
                #expect(library.fileCount == 1)
                let expected = try library.search(iteration.isMultiple(of: 2) ? "ALPHA" : "BETA")
                #expect(!expected.isEmpty)
            }
            let invalid = root.appending(path: "bad.txt")
            try Data([0, 255, 0]).write(to: invalid)
            #expect(throws: DocumentError.self) {
                try DocumentLibrary(url: invalid, indexURL: store.indexURL(for: invalid))
            }
            let valid = try DocumentLibrary(url: one, indexURL: store.indexURL(for: one))
            #expect(valid.indexedFileCount == 0)
        }
    }
}

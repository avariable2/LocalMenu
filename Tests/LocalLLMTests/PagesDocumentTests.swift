import Foundation
import ImageIO
import Testing
@testable import LocalLLM

/// rapport.pages was saved by Pages 14.5 from the "Rapport professionnel" template, with a body, a table, a text box
/// and a picture added; its chart and header come from the template. Only the previews were removed from the ZIP.
struct PagesDocumentTests {
    static let fixture = Bundle.module.url(forResource: "rapport", withExtension: "pages", subdirectory: "Fixtures")!

    private static func copy(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: url)
    }

    /// Pages can also save a document as a package folder: the same members, unzipped.
    private static func unpack(to url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = ["-q", fixture.path, "-d", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DocumentError.unreadable("fixture Pages") }
    }

    @Test func readsBodyTablesChartsTextBoxesHeadersAndPictures() throws {
        try DocumentFixtures.withDirectory { root in
            try Self.copy(to: root.appending(path: "rapport.pages"))
            let library = try DocumentLibrary(url: root)
            #expect(library.fileCount == 1)
            #expect(library.notices.isEmpty)

            let body = try #require(try library.search("CYGNE-318").first)
            #expect(body.file == "rapport.pages")
            #expect(body.location == "texte, lignes 1-5")
            #expect(body.text.hasPrefix("Rapport Bellerive 2026\nLe projet CYGNE-318 sera livré le 4 mars 2027 à Lyon.\n"))
            #expect(!body.text.contains("\u{FFFC}"))

            let table = try #require(try library.search("ALTAÏR").first)
            #expect(table.location.hasPrefix("tableau Stocks, cellules (valeurs enregistrées)"))
            for cell in ["A1 = Article", "B2 = 1250", "C2 = 2027-03-04", "D2 = Fournisseur ALTAÏR", "A3 = Écrou",
                         "B3 = -0.125", "B4 = 1249.875"] {
                #expect(table.text.contains(cell + "\n"), "\(cell)")
            }

            let chart = try #require(try library.search("Juin Région").first)
            #expect(chart.location.hasPrefix("graphique 1, données"))
            #expect(chart.text.contains("Région 2 · Juin = 70\n"))

            #expect(try library.search("KESTREL-55").first?.location.hasPrefix("zones de texte") == true)
            #expect(try library.search("dʼentreprise").contains { $0.location.hasPrefix("en-têtes et pieds de page") })

            let picture = try #require(try library.search("TOURMALINE palettes").first)
            #expect(picture.location.hasPrefix("image 1, OCR"))
            let page = try library.pageImage(id: picture.id)
            #expect(page.jpeg.starts(with: [0xFF, 0xD8]))
            let source = try #require(CGImageSourceCreateWithData(page.jpeg as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1000)
            // Pages lays pages out only when it opens the document: text extracts have no page image.
            #expect(throws: DocumentError.self) { try library.pageImage(id: body.id) }
        }
    }

    @Test func readsPackagesInFoldersAndAloneAndNoticesChanges() throws {
        try DocumentFixtures.withDirectory { root in
            let folder = root.appending(path: "sources")
            let package = folder.appending(path: "Projets/rapport.pages")
            try Self.unpack(to: package)
            let cache = root.appending(path: "index.sqlite")
            let library = try DocumentLibrary(url: folder, indexURL: cache)
            #expect(library.fileCount == 1)
            #expect(library.notices.isEmpty, "Les fichiers du paquet ne sont pas indexés séparément")
            #expect(try library.search("CYGNE-318").first?.file == "Projets/rapport.pages")
            #expect(try library.search("TOURMALINE").first.map { try library.pageImage(id: $0.id) } != nil)
            #expect(try DocumentLibrary(url: folder, indexURL: cache).indexedFileCount == 0)
            // Pages rewrites the members of a package without touching the folder itself.
            let index = package.appending(path: "Index/Document.iwa")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: index.path)
            #expect(try DocumentLibrary(url: folder, indexURL: cache).indexedFileCount == 1)

            let alone = try DocumentLibrary(url: package)
            #expect(alone.name == "rapport.pages")
            #expect(try alone.search("KESTREL-55").first?.file == "rapport.pages")
        }
    }

    @Test func explainsProtectedOldAndDamagedDocuments() throws {
        try DocumentFixtures.withDirectory { root in
            let cases: [(String, [String: String], String)] = [
                ("protege.pages", ["Index/Document.iwa": "chiffré", ".iwpv2": "x"], "mot de passe"),
                ("ancien.pages", ["index.xml": "<sl:document/>"], "Pages '09"),
                ("abime.pages", ["Index/Document.iwa": "pas un IWA"], "document Pages invalide")
            ]
            for (name, entries, message) in cases {
                let url = root.appending(path: name)
                try DocumentFixtures.archive(entries, at: url)
                do {
                    _ = try DocumentLibrary(url: url)
                    Issue.record("Erreur attendue pour \(name)")
                } catch {
                    #expect(error.localizedDescription.contains(message), "\(name) : \(error.localizedDescription)")
                }
            }
        }
    }

    @Test func decompressesSnappyChunksWithinBounds() throws {
        var budget = 1_000
        // A literal "ab", then a copy of 4 bytes from 2 bytes back.
        let chunk: [UInt8] = [6, 0x04, 0x61, 0x62, 0x01, 0x02]
        let data = try IWorkArchive.decompress([0, UInt8(chunk.count), 0, 0] + chunk, budget: &budget)
        #expect(String(decoding: data, as: UTF8.self) == "ababab")
        #expect(budget == 994)
        var small = 1_000
        #expect(throws: DocumentError.self) {
            // Announces 2^28 bytes: refused before anything is allocated.
            try IWorkArchive.decompress([0, 5, 0, 0, 0x80, 0x80, 0x80, 0x80, 0x01], budget: &small)
        }
        var other = 1_000
        #expect(throws: DocumentError.self) {
            // A copy reaching before the start of the block.
            try IWorkArchive.decompress([0, 3, 0, 0, 4, 0x01, 0x09], budget: &other)
        }
        #expect(PagesDocumentReader.columnName(0) == "A")
        #expect(PagesDocumentReader.columnName(25) == "Z")
        #expect(PagesDocumentReader.columnName(26) == "AA")
        #expect(PagesDocumentReader.columnName(701) == "ZZ")
        #expect(PagesDocumentReader.clean("a\u{2028}b\u{FFFC}\rc\u{4}d\te") == "a\nb\nc\nd\te")
    }
}

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import Testing
@testable import LocalLLM

struct DocumentLibraryTests {
    @Test func indexesLargeTextAndReadsNeighbors() throws {
        try DocumentFixtures.withDirectory { root in
            let text = (1...700).map { "Ligne \($0) du document." }.joined(separator: "\n")
                + "\nCode final : CONSTELLATION-829."
            let url = root.appending(path: "rapport.txt")
            try DocumentFixtures.write(text, to: url)
            let library = try DocumentLibrary(url: url)
            #expect(library.passageCount > 5)
            let passages = try (1...library.passageCount).map { try library.read(id: "S\($0)") }
            #expect(passages.allSatisfy { $0.text.count <= 1800 })
            let found = try library.search("CONSTELLATION 829")
            #expect(found.first?.text.contains("CONSTELLATION-829") == true)
            let first = try library.read(id: "S1")
            let next = try library.read(id: "S1", offset: 1)
            #expect(first.id != next.id)
            #expect(first.location.contains("lignes 1-"))
            #expect(throws: DocumentError.self) { try library.read(id: "../../secret.txt") }
            #expect(throws: DocumentError.self) { try library.read(id: "S1", offset: -1) }
            #expect(throws: DocumentError.self) { try library.read(id: "S1", offset: Int.max) }
        }
    }

    @Test func indexesNestedDirectoryWithoutFollowingSymlinks() throws {
        try DocumentFixtures.withDirectory { root in
            try DocumentFixtures.withDirectory { outside in
                try DocumentFixtures.write("SECRET EXTERIEUR", to: outside.appending(path: "secret.txt"))
                try DocumentFixtures.write("Contenu autorisé", to: root.appending(path: "sub/note.txt"))
                try FileManager.default.createSymbolicLink(at: root.appending(path: "outside"), withDestinationURL: outside)
                try FileManager.default.createSymbolicLink(at: root.appending(path: "link.txt"),
                    withDestinationURL: outside.appending(path: "secret.txt"))
                let library = try DocumentLibrary(url: root)
                #expect(library.fileCount == 1)
                let first = try library.read(id: "S1")
                let secret = try library.search("SECRET")
                #expect(first.file == "sub/note.txt")
                #expect(secret.isEmpty)
                #expect(throws: DocumentError.self) { try DocumentLibrary(url: root.appending(path: "link.txt")) }
            }
        }
    }

    @Test func refusesCrossFileOffsetsAndInvalidPagination() throws {
        try DocumentFixtures.withDirectory { root in
            try DocumentFixtures.write("Alpha", to: root.appending(path: "a.txt"))
            try DocumentFixtures.write("Beta", to: root.appending(path: "b.txt"))
            let library = try DocumentLibrary(url: root)
            #expect(throws: DocumentError.self) { try library.read(id: "S1", offset: 1) }
            #expect(throws: DocumentError.self) { try library.list(offset: -1) }
            #expect(throws: DocumentError.self) { try library.list(offset: Int.max) }
            let listing = try library.list(offset: 0)
            #expect(listing.contains("a.txt") && listing.contains("b.txt"))
            #expect(!listing.contains(root.path))
        }
    }

    @Test func warnsAboutUnreadableAndUnsupportedFiles() throws {
        try DocumentFixtures.withDirectory { root in
            try DocumentFixtures.write("Document valide", to: root.appending(path: "good.txt"))
            try Data([0, 1, 255]).write(to: root.appending(path: "bad.txt"))
            try Data([1, 2]).write(to: root.appending(path: "unsupported.bin"))
            let library = try DocumentLibrary(url: root)
            #expect(library.fileCount == 1)
            #expect(library.notices.count == 2)
        }
    }

    @Test func normalizesAccentsAndHandlesLongLines() throws {
        let library = try DocumentFixtures.library(text: String(repeating: "a", count: 20_000) + "\nÉchéance février.")
        let passages = try (1...library.passageCount).map { try library.read(id: "S\($0)") }
        let found = try library.search("echeance fevrier")
        let absent = try library.search("inexistant")
        #expect(passages.allSatisfy { $0.text.count <= 1800 })
        #expect(found.first?.text.contains("Échéance") == true)
        #expect(absent.isEmpty)
    }

    @Test func readsUTF16AndRejectsEmptyOrOversizedFiles() throws {
        try DocumentFixtures.withDirectory { root in
            let utf16 = root.appending(path: "utf16.txt")
            let data = try #require("Bonjour été".data(using: .utf16))
            try data.write(to: utf16)
            let library = try DocumentLibrary(url: utf16)
            let found = try library.search("ete")
            #expect(found.first?.text.contains("été") == true)
            let empty = root.appending(path: "empty.txt")
            try Data().write(to: empty)
            #expect(throws: DocumentError.self) { try DocumentLibrary(url: empty) }
            let oversized = root.appending(path: "large.txt")
            try Data().write(to: oversized)
            let handle = try FileHandle(forWritingTo: oversized)
            try handle.truncate(atOffset: UInt64(DocumentExtractor.maximumBytes + 1))
            try handle.close()
            #expect(throws: DocumentError.self) { try DocumentLibrary(url: oversized) }
        }
    }

    @Test func imageOCRAndScannedPDFKeepSourceLocations() throws {
        try DocumentFixtures.withDirectory { root in
            try DocumentFixtures.writePNG(at: root.appending(path: "image.png"))
            try DocumentFixtures.writeScannedPDF(at: root.appending(path: "scan.pdf"))
            let library = try DocumentLibrary(url: root)
            #expect(library.fileCount == 2)
            #expect(library.notices.isEmpty)
            let passages = try library.search("ORION 947")
            #expect(Set(passages.map(\.file)) == ["image.png", "scan.pdf"])
            #expect(passages.allSatisfy { $0.location.contains("OCR") })
            #expect(passages.contains { $0.file == "scan.pdf" && $0.location.contains("page 1") })
        }
    }

    @Test func readsTextOfFiguresOnPagesThatAlsoHaveText() throws {
        try DocumentFixtures.withDirectory { root in
            try DocumentFixtures.writeMixedPDF(at: root.appending(path: "rapport.pdf"))
            let library = try DocumentLibrary(url: root)
            let figure = try #require(try library.search("ORION 947").first)
            #expect(figure.location.contains("page 1, OCR des images"))
            #expect(figure.text.contains("HELIOS"))
            #expect(figure.text.components(separatedBy: "HELIOS").count == 2, "Le texte déjà présent n'est pas dupliqué")
        }
    }

    @Test func rendersPageImagesOnlyForPDFAndPictures() throws {
        try DocumentFixtures.withDirectory { root in
            try DocumentFixtures.writeScannedPDF(at: root.appending(path: "scan.pdf"))
            try DocumentFixtures.writePNG(at: root.appending(path: "photo.png"))
            try DocumentFixtures.write("Note ORION en texte.", to: root.appending(path: "note.txt"))
            let library = try DocumentLibrary(url: root)
            for file in ["scan.pdf", "photo.png"] {
                let passage = try #require(try library.search("ORION", file: file).first)
                let page = try library.pageImage(id: passage.id)
                #expect(page.passage.file == file)
                #expect(page.jpeg.starts(with: [0xFF, 0xD8]))
                let source = try #require(CGImageSourceCreateWithData(page.jpeg as CFData, nil))
                let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? 0) <= 1280)
            }
            let text = try #require(try library.search("ORION", file: "note").first)
            #expect(throws: DocumentError.self) { try library.pageImage(id: text.id) }
        }
    }

    @Test func searchCanBeLimitedToOneFile() throws {
        try DocumentFixtures.withDirectory { root in
            try DocumentFixtures.write("Budget alpha 100 euros.", to: root.appending(path: "alpha.txt"))
            try DocumentFixtures.write("Budget bêta 200 euros.", to: root.appending(path: "Dossiers/Beta.txt"))
            let library = try DocumentLibrary(url: root)
            #expect(try library.search("budget").count == 2)
            let scoped = try library.search("budget", file: "dossiers/BETA")
            #expect(scoped.map(\.file) == ["Dossiers/Beta.txt"])
            #expect(try library.search("budget", file: "100%_").isEmpty)
        }
    }

    @Test func readsDOCXParagraphsAndXLSXCells() throws {
        try DocumentFixtures.withDirectory { root in
            let docx = root.appending(path: "note.docx")
            try DocumentFixtures.archive(["word/document.xml": """
                <w:document xmlns:w="urn:word"><w:body><w:p><w:r><w:t>Projet NEBULA</w:t></w:r></w:p>
                <w:p><w:r><w:t>Responsable Camille.</w:t></w:r></w:p></w:body></w:document>
                """], at: docx)
            let xlsx = root.appending(path: "budget.xlsx")
            try DocumentFixtures.archive([
                "xl/workbook.xml": "<workbook xmlns:r='urn:rels'><sheets><sheet name='Budget' r:id='rId1'/></sheets></workbook>",
                "xl/_rels/workbook.xml.rels": "<Relationships><Relationship Id='rId1' Target='worksheets/sheet1.xml'/></Relationships>",
                "xl/sharedStrings.xml": "<sst><si><t>NEBULA</t></si></sst>",
                "xl/worksheets/sheet1.xml": """
                <worksheet><sheetData><row r='1'><c r='A1' t='s'><v>0</v></c><c r='B1'><v>42000</v></c>
                <c r='C1' t='inlineStr'><is><t>euros</t></is></c></row></sheetData></worksheet>
                """
            ], at: xlsx)
            let library = try DocumentLibrary(url: root)
            #expect(library.fileCount == 2)
            #expect(library.notices.isEmpty)
            let responsible = try library.search("Camille")
            let budgets = try library.search("42000")
            #expect(responsible.first?.file == "note.docx")
            let budget = try #require(budgets.first)
            #expect(budget.text.contains("B1 = 42000"))
            #expect(budget.text.contains("A1 = NEBULA"))
            #expect(budget.text.contains("C1 = euros"))
            #expect(budget.location.contains("feuille Budget"))
        }
    }

    @Test func readsNativePDFTextWithoutOCR() throws {
        try DocumentFixtures.withDirectory { root in
            let url = root.appending(path: "native.pdf")
            var box = CGRect(x: 0, y: 0, width: 300, height: 200)
            let graphics = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
            graphics.beginPDFPage(nil)
            graphics.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Reference AZUR-742")), graphics)
            graphics.endPDFPage()
            graphics.closePDF()
            let library = try DocumentLibrary(url: url)
            let found = try library.search("AZUR 742")
            let passage = try #require(found.first)
            #expect(passage.location.contains("page 1"))
            #expect(!passage.location.contains("OCR"))
        }
    }

    @Test func rejectsOfficeExternalEntitiesAndTraversal() throws {
        try DocumentFixtures.withDirectory { root in
            let docx = root.appending(path: "malicious.docx")
            try DocumentFixtures.archive(["word/document.xml": """
                <!DOCTYPE document [<!ENTITY local SYSTEM 'file:///etc/passwd'>]>
                <document><p><t>&local;</t></p></document>
                """], at: docx)
            #expect(throws: DocumentError.self) { try DocumentLibrary(url: docx) }
            #expect(throws: DocumentError.self) {
                try OfficeDocumentReader.member("../../secret", in: docx)
            }
            #expect(throws: DocumentError.self) {
                try OfficeDocumentReader.member("word/*", in: docx)
            }
        }
    }
}

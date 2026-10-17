import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import LocalLLM

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LOCALMENU_LARGE_TESTS"] == "1",
    "Activer LOCALMENU_LARGE_TESTS=1 pour les fichiers volumineux synthétiques"))
struct LargeDocumentTests {
    @Test func findsAnswerAtEndOfDocumentLargerThan32MB() throws {
        try DocumentFixtures.withDirectory { root in
            let url = root.appending(path: "large.txt")
            try Data().write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            let block = Data(String(repeating: "Le projet est suivi avec un budget documenté et une livraison prévue.\n", count: 1000).utf8)
            for _ in 0..<512 { try handle.write(contentsOf: block) }
            try handle.write(contentsOf: Data("Le contrat INTERSTELLAIRE-7319 prévoit la livraison le 27 avril 2029.\n".utf8))
            try handle.close()
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            #expect(size > 32 * 1024 * 1024)
            let start = ContinuousClock.now
            let cache = root.appending(path: "index.sqlite")
            let library = try DocumentLibrary(url: url, indexURL: cache)
            let found = try library.search("7319")
            #expect(found.first?.text.contains("27 avril 2029") == true)
            print("Large text: \(size) bytes, \(library.passageCount) passages, \(start.duration(to: .now))")
            let reused = try DocumentLibrary(url: url, indexURL: cache)
            #expect(reused.indexedFileCount == 0)
        }
    }

    @Test func readsMoreThan1000PDFPagesWithLastPageReference() throws {
        try DocumentFixtures.withDirectory { root in
            let url = root.appending(path: "large.pdf")
            var box = CGRect(x: 0, y: 0, width: 500, height: 200)
            let graphics = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
            for page in 1...1101 {
                graphics.beginPDFPage(nil)
                graphics.textPosition = CGPoint(x: 20, y: 100)
                let text = page == 1101 ? "ORBITAL-902 budget 57300 euros" : "Document de contrôle page \(page)"
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text)), graphics)
                graphics.endPDFPage()
            }
            graphics.closePDF()
            let start = ContinuousClock.now
            let library = try DocumentLibrary(url: url)
            let found = try library.search("ORBITAL 902")
            #expect(found.first?.location.contains("page 1101,") == true)
            #expect(found.first?.text.contains("57300") == true)
            print("Large PDF: \(library.passageCount) passages, \(start.duration(to: .now))")
        }
    }
}

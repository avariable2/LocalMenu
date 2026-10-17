import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import LocalLLM

struct DocumentFixtures {
    static func withDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func library(text: String = "Projet AZUR-742. Livraison le 18 novembre 2026. Responsable Camille Morel.") throws -> DocumentLibrary {
        try withDirectory { root in
            try write(text, to: root.appending(path: "planning.txt"))
            return try DocumentLibrary(url: root)
        }
    }

    static func archive(_ entries: [String: String], at url: URL) throws {
        try withDirectory { directory in
            for (path, content) in entries { try write(content, to: directory.appending(path: path)) }
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/zip")
            process.currentDirectoryURL = directory
            process.arguments = ["-q", "-r", url.path, "."]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw DocumentError.unreadable("fixture ZIP") }
        }
    }

    static func image() throws -> CGImage {
        guard let context = CGContext(data: nil, width: 1000, height: 300, bitsPerComponent: 8,
            bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw DocumentError.empty }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 300))
        context.textPosition = CGPoint(x: 40, y: 160)
        let text = NSAttributedString(string: "ORION 947 - Livraison le 25 novembre 2026", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 34, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        guard let image = context.makeImage() else { throw DocumentError.empty }
        return image
    }

    static func writePNG(at url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw DocumentError.empty
        }
        CGImageDestinationAddImage(destination, try image(), nil)
        guard CGImageDestinationFinalize(destination) else { throw DocumentError.empty }
    }

    static func writeScannedPDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 1000, height: 300)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw DocumentError.empty }
        context.beginPDFPage(nil)
        context.draw(try image(), in: box)
        context.endPDFPage()
        context.closePDF()
    }

    /// A two-page report whose quarterly figures exist only as pixels of a bar chart on page 2.
    static func writeChartReport(at url: URL) throws {
        func draw(_ text: String, _ context: CGContext, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])), context)
        }
        guard let chart = CGContext(data: nil, width: 1200, height: 700, bitsPerComponent: 8, bytesPerRow: 4800,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DocumentError.empty
        }
        chart.setFillColor(CGColor(gray: 1, alpha: 1))
        chart.fill(CGRect(x: 0, y: 0, width: 1200, height: 700))
        draw("Chiffre d'affaires Heliodore 2025 (k EUR)", chart, 60, 640, 34)
        for (index, (quarter, value)) in [("T1", 120), ("T2", 185), ("T3", 90), ("T4", 240)].enumerated() {
            let x = CGFloat(120 + index * 260)
            chart.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            chart.fill(CGRect(x: x, y: 100, width: 150, height: CGFloat(value * 2)))
            draw("\(value)", chart, x + 40, CGFloat(110 + value * 2), 36)
            draw(quarter, chart, x + 50, 50, 36)
        }
        guard let image = chart.makeImage() else { throw DocumentError.empty }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw DocumentError.empty }
        pdf.beginPDFPage(nil)
        draw("Rapport annuel 2025 - Societe Heliodore", pdf, 50, 720, 20)
        draw("Le detail par trimestre figure dans le graphique de la page 2.", pdf, 50, 680, 12)
        pdf.endPDFPage()
        pdf.beginPDFPage(nil)
        draw("Figure 1 : evolution trimestrielle", pdf, 50, 720, 16)
        pdf.draw(image, in: CGRect(x: 50, y: 360, width: 512, height: 299))
        pdf.endPDFPage()
        pdf.closePDF()
    }

    /// A report page whose text layer only holds the caption: the figure's values exist only in the picture.
    static func writeMixedPDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 1000, height: 500)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw DocumentError.empty }
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: 440)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Figure 1 HELIOS calendrier", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 30, nil)
        ])), context)
        context.draw(try image(), in: CGRect(x: 0, y: 60, width: 1000, height: 300))
        context.endPDFPage()
        context.closePDF()
    }
}

import Foundation
import ImageIO
import PDFKit
import Vision

struct DocumentExtractor {
    static let maximumBytes = 512 * 1024 * 1024
    // Office XML and one PDF page remain bounded; this is no longer a whole-document text limit.
    static let maximumCharacters = 2_000_000
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "xml", "html", "htm",
        "yaml", "yml", "toml", "ini", "log", "tex", "rst", "swift", "py", "js", "ts",
        "jsx", "tsx", "css", "scss", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go",
        "java", "kt", "rb", "php", "sh", "bash", "zsh", "sql", "r", "vue", "svelte"
    ]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "webp", "bmp"]

    static func supports(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return textExtensions.contains(ext) || imageExtensions.contains(ext)
            || ["pdf", "docx", "xlsx", "pages"].contains(ext) || ext.isEmpty
    }

    /// Pages can save a document as a package folder instead of a single file; it is still one document.
    static func isDocumentPackage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pages"
            && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func forEachSection(url: URL, emit: (ExtractedSection) throws -> Void) throws {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true || isDocumentPackage(url), values.isSymbolicLink != true else {
            throw DocumentError.unsupported
        }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw DocumentError.tooLarge }
        guard supports(url) else { throw DocumentError.unsupported }
        let ext = url.pathExtension.lowercased()
        if ext == "pages" { try pages(url: url, emit: emit); return }
        if ext == "docx" || ext == "xlsx" {
            guard (values.fileSize ?? 0) <= 32 * 1024 * 1024 else { throw DocumentError.tooLarge }
            let sections = try ext == "docx" ? OfficeDocumentReader.docx(url: url) : OfficeDocumentReader.xlsx(url: url)
            for section in sections { try Task.checkCancellation(); try emit(section) }
            return
        }
        let handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: 5) ?? Data()
        try handle.close()
        if header.starts(with: Data("%PDF-".utf8)) { try pdf(url: url, emit: emit); return }
        if imageExtensions.contains(ext) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw DocumentError.unreadable("image invalide")
            }
            let count = CGImageSourceGetCount(source)
            guard count <= 10_000 else { throw DocumentError.tooLarge }
            for index in 0..<count {
                try Task.checkCancellation()
                try autoreleasepool {
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2400
                    ] as CFDictionary) else { throw DocumentError.unreadable("image invalide") }
                    try emit(ExtractedSection(location: "image \(index + 1), OCR", text: recognize(image)))
                }
            }
            return
        }
        try TextDocumentReader.forEach(url: url, emit: emit)
    }

    private static func pages(url: URL, emit: (ExtractedSection) throws -> Void) throws {
        let archive = try IWorkArchive(url: url)
        for section in try PagesDocumentReader.sections(of: archive) {
            try Task.checkCancellation()
            try emit(section)
        }
        let names = try PagesDocumentReader.imageNames(in: archive.container)
        guard names.count <= 10_000 else { throw DocumentError.tooLarge }
        for (index, name) in names.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                // Pictures carry text the document does not, such as a pasted chart; decorations are too small to read.
                guard let image = try? PagesDocumentReader.image(name, in: archive.container),
                      image.width >= 150, image.height >= 100 else { return }
                let text = try recognize(image)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                try emit(ExtractedSection(location: "image \(index + 1), OCR", text: text))
            }
        }
    }

    private static func pdf(url: URL, emit: (ExtractedSection) throws -> Void) throws {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            throw DocumentError.unreadable("PDF invalide ou protégé")
        }
        guard document.pageCount <= 10_000 else { throw DocumentError.tooLarge }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = document.page(at: index) else { throw DocumentError.unreadable("page PDF manquante") }
                guard let reference = page.pageRef else { throw DocumentError.unreadable("page PDF invalide") }
                var text = page.string ?? ""
                var location = "page \(index + 1)"
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = try recognize(render(reference))
                    location += ", OCR"
                } else if containsRasterImage(reference) {
                    // Charts and figures pasted as pictures carry text the PDF text layer does not have.
                    let known = fold(text)
                    let lines = try recognize(render(reference)).split(whereSeparator: \.isNewline).filter { line in
                        let folded = fold(String(line)).trimmingCharacters(in: .whitespaces)
                        return folded.count > 1 && !known.contains(folded)
                    }
                    if !lines.isEmpty {
                        text += "\n[Texte lu dans les images et graphiques de la page (OCR)]\n" + lines.joined(separator: "\n")
                        location += ", OCR des images"
                    }
                }
                guard text.count <= maximumCharacters else { throw DocumentError.tooLarge }
                try emit(ExtractedSection(location: location, text: text))
            }
        }
    }

    static func render(_ page: CGPDFPage, maximumPixels: CGFloat = 2400) throws -> CGImage {
        let box = page.getBoxRect(.mediaBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
            throw DocumentError.unreadable("dimensions PDF invalides")
        }
        let scale = min(3, maximumPixels / max(box.width, box.height))
        let width = max(1, Int(box.width * scale))
        let height = max(1, Int(box.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DocumentError.unreadable("rendu PDF impossible")
        }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw DocumentError.unreadable("rendu PDF impossible") }
        return image
    }

    /// Small decorations such as logos and bullets are ignored; only picture-sized images trigger OCR.
    static func containsRasterImage(_ page: CGPDFPage) -> Bool {
        guard let dictionary = page.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return false }
        return containsRasterImage(resources: resources, depth: 0)
    }

    private static func containsRasterImage(resources: CGPDFDictionaryRef, depth: Int) -> Bool {
        var objects: CGPDFDictionaryRef?
        guard depth < 4, CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return false }
        var found = false
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let info = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(info, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image":
                var width: CGPDFInteger = 0
                var height: CGPDFInteger = 0
                _ = CGPDFDictionaryGetInteger(info, "Width", &width)
                _ = CGPDFDictionaryGetInteger(info, "Height", &height)
                found = width >= 150 && height >= 100
            case "Form":
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(info, "Resources", &nested), let nested {
                    found = containsRasterImage(resources: nested, depth: depth + 1)
                }
            default: break
            }
            return !found
        }, nil)
        return found
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

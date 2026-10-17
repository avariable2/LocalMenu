import Foundation

struct PassageChunker {
    static func forEach(_ section: ExtractedSection, emit: (String, String) throws -> Void) throws {
        var chunk = ""
        var startLine = section.startLine
        var endLine = startLine
        func flush() throws {
            guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { chunk = ""; return }
            try emit("\(section.location), lignes \(startLine)-\(endLine)", chunk)
            chunk = ""
        }
        // A section is a bounded text block or one page, never the whole corpus.
        for (offset, line) in section.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            try Task.checkCancellation()
            var remaining = line
            repeat {
                var piece = remaining.prefix(1600)
                if let boundary = piece.lastIndex(where: \.isWhitespace),
                   piece.distance(from: piece.startIndex, to: boundary) > 800 { piece = piece[..<boundary] }
                if !chunk.isEmpty, chunk.count + piece.count + 1 > 1800 { try flush() }
                if chunk.isEmpty { startLine = section.startLine + offset }
                endLine = section.startLine + offset
                chunk += piece + "\n"
                remaining = remaining.dropFirst(piece.count)
            } while !remaining.isEmpty
        }
        try flush()
    }
}

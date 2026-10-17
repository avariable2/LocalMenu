import Foundation

struct TextDocumentReader {
    static func forEach(url: URL, emit: (ExtractedSection) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        var encoding = String.Encoding.utf8
        var first = true
        var bytes = 0
        var line = 1
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            let final = data.isEmpty
            bytes += data.count
            guard bytes <= DocumentExtractor.maximumBytes else { throw DocumentError.tooLarge }
            pending.append(data)
            if first {
                first = false
                if pending.starts(with: [0xFF, 0xFE]) { encoding = .utf16LittleEndian; pending.removeFirst(2) }
                else if pending.starts(with: [0xFE, 0xFF]) { encoding = .utf16BigEndian; pending.removeFirst(2) }
                else if pending.starts(with: [0xEF, 0xBB, 0xBF]) { pending.removeFirst(3) }
            }
            if pending.isEmpty, final { return }
            if !final, pending.count < 64 * 1024 { continue }
            var decoded: String?
            var consumed = pending.count
            for dropped in 0...(final ? 0 : min(3, pending.count)) {
                if let text = String(data: pending.prefix(pending.count - dropped), encoding: encoding) {
                    decoded = text
                    consumed = pending.count - dropped
                    break
                }
            }
            guard var text = decoded, !text.contains("\0") else { throw DocumentError.unsupported }
            if !final {
                // Keep the incomplete last line (or word on a very long line) for the next block.
                let minimum = text.count / 2
                if let boundary = text.lastIndex(where: \.isNewline), text[boundary] != "\r",
                   text.distance(from: text.startIndex, to: boundary) >= minimum {
                    text = String(text[...boundary])
                } else if let boundary = text.lastIndex(where: \.isWhitespace),
                          text.distance(from: text.startIndex, to: boundary) >= minimum {
                    text = String(text[..<boundary])
                }
                if text.hasSuffix("\r") { text.removeLast() }
                consumed = text.lengthOfBytes(using: encoding)
            }
            if !text.isEmpty {
                try emit(ExtractedSection(location: "texte", text: text, startLine: line))
                line += text.filter(\.isNewline).count
                pending.removeFirst(consumed)
            }
            if final { return }
        }
    }
}

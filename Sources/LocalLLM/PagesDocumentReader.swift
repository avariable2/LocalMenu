import Foundation
import ImageIO

/// Text, table cells and chart data of a Pages document. Pages lays pages out only when it opens the document,
/// so locations name the part of the document (body, table, chart…) instead of a page number.
struct PagesDocumentReader {
    private enum Kind: UInt64 {
        case body = 0, header, footnote, textbox, note, cell, unclassified, tableCell
    }

    private static let storageType: UInt32 = 2001
    private static let chartType: UInt32 = 5021
    private static let tableType: UInt32 = 6001
    private static let tileType: UInt32 = 6002
    private static let dataListType: UInt32 = 6005
    // Long bodies are split so that one section stays bounded; line numbers continue across the parts.
    private static let sectionCharacters = 200_000

    static func sections(of archive: IWorkArchive) throws -> [ExtractedSection] {
        var body: [String] = []
        var others: [Kind: [String]] = [:]
        for identifier in archive.identifiers(ofType: storageType) {
            try Task.checkCancellation()
            guard let storage = archive.object(identifier) else { continue }
            let message = try ProtoMessage(storage.payload)
            // The kind is omitted for text boxes, its default.
            let kind = Kind(rawValue: message.varint(1) ?? Kind.textbox.rawValue) ?? .unclassified
            let text = clean(message.strings(3).joined())
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            switch kind {
            case .body: body.append(text)
            // Cells are read with their table, which gives them a reference.
            case .cell, .tableCell: continue
            default:
                // Headers and footers repeat in every section of the document.
                if others[kind, default: []].contains(text) == false { others[kind, default: []].append(text) }
            }
        }
        var sections = split(body.joined(separator: "\n"), location: "texte")
        for identifier in archive.identifiers(ofType: tableType) {
            try Task.checkCancellation()
            if let table = try table(identifier, in: archive) { sections.append(table) }
        }
        for (index, identifier) in archive.identifiers(ofType: chartType).enumerated() {
            if let chart = try chart(identifier, in: archive, number: index + 1) { sections.append(chart) }
        }
        let labels: [(Kind, String)] = [(.textbox, "zones de texte"), (.unclassified, "autres textes"),
            (.header, "en-têtes et pieds de page"), (.footnote, "notes de bas de page"), (.note, "commentaires")]
        for (kind, location) in labels {
            if let texts = others[kind] { sections += split(texts.joined(separator: "\n"), location: location) }
        }
        return sections
    }

    /// Pictures stored in the document, in a stable order so that "image N" can be found again; Pages also keeps
    /// reduced copies of them, which are skipped.
    static func imageNames(in container: IWorkArchive.Container) throws -> [String] {
        try container.names().filter { name in
            name.hasPrefix("Data/") && !name.contains("-small-")
                && DocumentExtractor.imageExtensions.contains((name as NSString).pathExtension.lowercased())
        }.sorted()
    }

    static func image(_ name: String, in container: IWorkArchive.Container, maximumPixels: Int = 2400) throws -> CGImage {
        let data = try container.data(name, maximumBytes: 64 * 1024 * 1024)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixels
              ] as CFDictionary) else { throw DocumentError.unreadable("image invalide") }
        return image
    }

    /// Paragraphs end with a line feed, line breaks with U+2028; page, column and section breaks are control
    /// characters, and U+FFFC marks an anchored object such as a table, a picture or a page number.
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            switch scalar.value {
            case 0x09, 0x0A: scalar
            case 0x00...0x1F, 0x2028, 0x2029, 0x85: "\n"
            case 0xFFFC, 0x7F...0x9F: nil
            default: scalar
            }
        }))
    }

    private static func split(_ text: String, location: String) -> [ExtractedSection] {
        var sections: [ExtractedSection] = []
        var part = ""
        var startLine = 1
        var line = 1
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !part.isEmpty, part.count + paragraph.count > sectionCharacters {
                sections.append(ExtractedSection(location: location, text: part, startLine: startLine))
                part = ""
                startLine = line
            }
            part += paragraph + "\n"
            line += 1
        }
        if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(ExtractedSection(location: location, text: part, startLine: startLine))
        }
        return sections
    }

    // MARK: Tables

    /// TST.TableModelArchive: cells live in tiles of 256 rows; text cells point into the table's string list.
    private static func table(_ identifier: UInt64, in archive: IWorkArchive) throws -> ExtractedSection? {
        guard let object = archive.object(identifier) else { return nil }
        let model = try ProtoMessage(object.payload)
        guard let store = try model.message(4), let tiles = try store.message(3) else { return nil }
        let rowCount = Int(model.varint(6) ?? 0)
        let columnCount = Int(model.varint(7) ?? 0)
        guard rowCount <= 1_000_000, columnCount <= 1_000 else { throw DocumentError.tooLarge }
        let strings = try dataList(store.reference(4), in: archive)
        let richTexts = try dataList(store.reference(17), in: archive)
        let tileSize = Int(tiles.varint(2) ?? 256)
        var cells: [(row: Int, column: Int, value: String)] = []
        var characters = 0
        for tile in try tiles.messages(1) {
            try Task.checkCancellation()
            guard let tileID = tile.varint(1).flatMap(Int.init(exactly:)), tileID <= 1_000_000 / max(1, tileSize),
                  let tileObject = archive.object(try tile.reference(2), type: tileType) else { continue }
            for row in try ProtoMessage(tileObject.payload).messages(5) {
                guard let index = row.varint(1), let buffer = row.bytes(6), let offsets = row.bytes(7) else { continue }
                let rowNumber = tileID * tileSize + Int(index)
                let wide = row.varint(8) == 1
                for column in 0..<(offsets.count / 2) {
                    let raw = Int(offsets[offsets.startIndex + 2 * column]) | Int(offsets[offsets.startIndex + 2 * column + 1]) << 8
                    guard raw != 0xFFFF, rowNumber < rowCount, column < columnCount,
                          let value = cell(buffer.dropFirst(wide ? raw * 4 : raw), strings: strings, richTexts: richTexts),
                          !value.isEmpty else { continue }
                    characters += value.count
                    guard characters <= DocumentExtractor.maximumCharacters else { throw DocumentError.tooLarge }
                    cells.append((rowNumber, column, value))
                }
            }
        }
        guard !cells.isEmpty else { return nil }
        let text = cells.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
            .map { "\(columnName($0.column))\($0.row + 1) = \($0.value)" }.joined(separator: "\n")
        let name = clean(model.string(8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ExtractedSection(location: "tableau \(name.isEmpty ? "sans nom" : name), cellules (valeurs enregistrées)", text: text)
    }

    /// TST.TableDataList: shared strings, or rich text that refers to a text storage.
    private static func dataList(_ identifier: UInt64?, in archive: IWorkArchive) throws -> [UInt64: String] {
        guard let object = archive.object(identifier, type: dataListType) else { return [:] }
        var values: [UInt64: String] = [:]
        for entry in try ProtoMessage(object.payload).messages(3) {
            guard let key = entry.varint(1) else { continue }
            if let string = entry.string(3) {
                values[key] = clean(string)
            } else if let reference = try entry.reference(9) ?? entry.reference(4),
                      let text = try storageText(reference, in: archive, depth: 0) {
                values[key] = text
            }
        }
        return values
    }

    /// Follows a rich text payload to the storage holding its text.
    private static func storageText(_ identifier: UInt64, in archive: IWorkArchive, depth: Int) throws -> String? {
        guard depth < 3, let object = archive.object(identifier) else { return nil }
        let message = try ProtoMessage(object.payload)
        if object.type == storageType { return clean(message.strings(3).joined()).trimmingCharacters(in: .whitespacesAndNewlines) }
        return try message.reference(1).flatMap { try storageText($0, in: archive, depth: depth + 1) }
    }

    /// Cell storage, version 5: type at byte 1, a flag word at byte 8, then the fields its flags announce, in order.
    private static func cell(_ buffer: ArraySlice<UInt8>, strings: [UInt64: String], richTexts: [UInt64: String]) -> String? {
        guard buffer.count >= 12, buffer[buffer.startIndex] == 5 else { return nil }
        let type = buffer[buffer.startIndex + 1]
        var index = buffer.startIndex + 8
        func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard buffer.endIndex - index >= count else { return nil }
            defer { index += count }
            return buffer[index..<(index + count)]
        }
        func integer(_ bytes: ArraySlice<UInt8>) -> UInt64 {
            bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
        }
        guard let flagBytes = take(4) else { return nil }
        let flags = integer(flagBytes)
        var decimal: Decimal?
        var double: Double?
        var seconds: Double?
        var string: String?
        if flags & 0x1 != 0 { guard let bytes = take(16) else { return nil }; decimal = decimal128(bytes) }
        if flags & 0x2 != 0 { guard let bytes = take(8) else { return nil }; double = Double(bitPattern: integer(bytes)) }
        if flags & 0x4 != 0 { guard let bytes = take(8) else { return nil }; seconds = Double(bitPattern: integer(bytes)) }
        if flags & 0x8 != 0 { guard let bytes = take(4) else { return nil }; string = strings[integer(bytes)] }
        if flags & 0x10 != 0 { guard let bytes = take(4) else { return nil }; string = string ?? richTexts[integer(bytes)] }
        switch type {
        case 3, 9: return string
        case 5: return seconds.map(date)
        case 6: return (double ?? decimal.map { NSDecimalNumber(decimal: $0).doubleValue }).map { $0 == 0 ? "FAUX" : "VRAI" }
        case 7: return (double ?? decimal.map { NSDecimalNumber(decimal: $0).doubleValue }).map { "\(number($0)) s" }
        case 8: return "#ERREUR"
        default: return decimal.map { "\($0)" } ?? double.map(number) ?? string
        }
    }

    /// IEEE 754 decimal128 as iWork writes it: a 113-bit binary coefficient and a 14-bit exponent biased by 6176.
    private static func decimal128(_ bytes: ArraySlice<UInt8>) -> Decimal? {
        let byte = { (offset: Int) in bytes[bytes.startIndex + offset] }
        let exponent = (Int(byte(15) & 0x7F) << 7 | Int(byte(14) >> 1)) - 6176
        var coefficient = Decimal(Int(byte(14) & 1))
        for offset in stride(from: 13, through: 0, by: -1) { coefficient = coefficient * 256 + Decimal(Int(byte(offset))) }
        guard (-128...127).contains(exponent) else { return nil }
        return Decimal(sign: byte(15) & 0x80 == 0 ? .plus : .minus, exponent: exponent, significand: coefficient)
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    /// Dates are floating: Pages shows the stored seconds as GMT whatever the Mac's time zone.
    private static func date(_ seconds: Double) -> String {
        let date = Date(timeIntervalSinceReferenceDate: seconds)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = .gmt
        formatter.dateFormat = calendar.startOfDay(for: date) == date ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func columnName(_ index: Int) -> String {
        var index = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(UInt8(65 + index % 26))) + name
            index = index / 26 - 1
        } while index >= 0
        return name
    }

    // MARK: Charts

    /// TSCH.ChartArchive, an extension of the chart drawable: its grid has row and column names and the values.
    private static func chart(_ identifier: UInt64, in archive: IWorkArchive, number: Int) throws -> ExtractedSection? {
        guard let object = archive.object(identifier), let chart = try ProtoMessage(object.payload).message(10000),
              let grid = try chart.message(7) else { return nil }
        let rowNames = grid.strings(1).map(clean)
        let columnNames = grid.strings(2).map(clean)
        var lines: [String] = []
        for (row, values) in try grid.messages(3).enumerated() {
            for (column, value) in try values.messages(1).enumerated() {
                guard let figure = value.double(1) ?? value.double(2) ?? value.double(3) else { continue }
                let series = rowNames.indices.contains(row) ? rowNames[row] : "série \(row + 1)"
                let category = columnNames.indices.contains(column) ? columnNames[column] : "valeur \(column + 1)"
                lines.append("\(series) · \(category) = \(Self.number(figure))")
            }
        }
        guard !lines.isEmpty else { return nil }
        return ExtractedSection(location: "graphique \(number), données", text: lines.joined(separator: "\n"))
    }
}

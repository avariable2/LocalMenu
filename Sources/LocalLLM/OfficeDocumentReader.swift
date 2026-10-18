import Foundation

struct OfficeDocumentReader {
    static let maximumXMLBytes = 8 * 1024 * 1024

    // Fixed archive members only; nothing is extracted onto the filesystem.
    static func member(_ name: String, in url: URL, optional: Bool = false,
                       maximumBytes: Int = maximumXMLBytes) throws -> Data {
        guard !name.contains(".."), !name.hasPrefix("/"), !name.contains("\\"),
              !name.contains("["), !name.contains("*"), !name.contains("?") else {
            throw DocumentError.unreadable("chemin Office invalide")
        }
        let (data, status) = try unzip(["-p", url.path, name], maximumBytes: maximumBytes)
        guard status == 0 else {
            if optional && status == 11 { return Data() }
            throw DocumentError.unreadable("archive Office invalide ou membre manquant")
        }
        return data
    }

    static func memberNames(in url: URL) throws -> [String] {
        let (data, status) = try unzip(["-Z1", url.path], maximumBytes: maximumXMLBytes)
        guard status == 0 else { throw DocumentError.unreadable("archive invalide") }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func unzip(_ arguments: [String], maximumBytes: Int) throws -> (Data, Int32) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? pipe.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        var data = Data()
        while let part = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !part.isEmpty {
            try Task.checkCancellation()
            data.append(part)
            guard data.count <= maximumBytes else { throw DocumentError.tooLarge }
        }
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }

    static func docx(url: URL) throws -> [ExtractedSection] {
        let data = try member("word/document.xml", in: url)
        var result = ""
        var capturing = false
        let xml = OfficeXML(start: { tag, _ in
            if tag == "t" { capturing = true }
            if tag == "tab" { result += "\t" }
            if tag == "br" { result += "\n" }
        }, end: { tag in
            if tag == "t" { capturing = false }
            if tag == "p" { result += "\n" }
        }, text: { text in
            if capturing { result += text }
        })
        try xml.parse(data)
        guard result.count <= DocumentExtractor.maximumCharacters else { throw DocumentError.tooLarge }
        return [ExtractedSection(location: "paragraphes", text: result)]
    }

    static func xlsx(url: URL) throws -> [ExtractedSection] {
        let workbook = try member("xl/workbook.xml", in: url)
        let relationships = try member("xl/_rels/workbook.xml.rels", in: url)
        var sheets: [(String, String)] = []
        try OfficeXML(start: { tag, attributes in
            if tag == "sheet", let name = attributes["name"], let id = attributes["r:id"] {
                sheets.append((name, id))
            }
        }).parse(workbook)
        var targets: [String: String] = [:]
        try OfficeXML(start: { tag, attributes in
            if tag == "Relationship", attributes["TargetMode"] != "External",
               let id = attributes["Id"], let target = attributes["Target"] { targets[id] = target }
        }).parse(relationships)
        var shared: [String] = []
        let sharedData = try member("xl/sharedStrings.xml", in: url, optional: true)
        if !sharedData.isEmpty {
            var value = ""
            var capturing = false
            try OfficeXML(start: { tag, _ in
                if tag == "si" { value = "" }
                if tag == "t" { capturing = true }
            }, end: { tag in
                if tag == "t" { capturing = false }
                if tag == "si" { shared.append(value) }
            }, text: { if capturing { value += $0 } }).parse(sharedData)
        }
        guard sheets.count <= 200 else { throw DocumentError.tooLarge }
        var result: [ExtractedSection] = []
        var totalCharacters = 0
        for (name, id) in sheets {
            try Task.checkCancellation()
            guard let target = targets[id] else { throw DocumentError.unreadable("feuille XLSX non locale") }
            let path = target.hasPrefix("/xl/") ? String(target.dropFirst()) : "xl/" + target
            guard path.hasPrefix("xl/worksheets/") else { throw DocumentError.unreadable("chemin de feuille XLSX invalide") }
            let data = try member(path, in: url)
            var rows: [String] = []
            var reference = ""
            var type = ""
            var value = ""
            var capturing = false
            var invalidCell = false
            try OfficeXML(start: { tag, attributes in
                if tag == "c" {
                    reference = attributes["r"] ?? "?"
                    type = attributes["t"] ?? "n"
                    value = ""
                }
                if tag == "v" || tag == "t" { capturing = true }
            }, end: { tag in
                if tag == "v" || tag == "t" { capturing = false }
                if tag == "c", !value.isEmpty {
                    if type == "s" {
                        if let index = Int(value), shared.indices.contains(index) { value = shared[index] }
                        else { invalidCell = true }
                    }
                    rows.append("\(reference) = \(value)")
                }
            }, text: { if capturing { value += $0 } }).parse(data)
            guard !invalidCell else { throw DocumentError.unreadable("index de cellule XLSX invalide") }
            let text = rows.joined(separator: "\n")
            totalCharacters += text.count
            guard totalCharacters <= DocumentExtractor.maximumCharacters else { throw DocumentError.tooLarge }
            result.append(ExtractedSection(location: "feuille \(name), cellules (valeurs enregistrées)", text: text))
        }
        return result
    }
}

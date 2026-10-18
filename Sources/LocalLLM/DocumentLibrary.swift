import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct DocumentLibrary: Sendable {
    public let name: String
    public let fileCount: Int
    public let passageCount: Int
    public let notices: [String]
    public let indexedFileCount: Int
    private let index: DocumentIndex
    private let root: URL
    private let isDirectory: Bool
    // Bumped when extraction improves, so cached indexes are rebuilt with the richer text.
    private static let extractionVersion = 2

    public init(url: URL, indexURL: URL? = nil, onProgress: @Sendable (String) -> Void = { _ in }) throws {
        let selected = url.standardizedFileURL
        let values = try selected.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw DocumentError.unsupported }
        let root = selected.resolvingSymlinksInPath().standardizedFileURL
        let isDirectory = values.isDirectory == true && !DocumentExtractor.isDocumentPackage(root)
        var files: [URL] = []
        var notices: [String] = []
        if isDirectory {
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { file, error in
                    notices.append("\(file.lastPathComponent) : \(error.localizedDescription)")
                    return true
                }) else { throw DocumentError.unreadable("dossier inaccessible") }
            var entries = 0
            for case let file as URL in enumerator {
                try Task.checkCancellation()
                entries += 1
                guard entries <= 50_000 else { throw DocumentError.indexLimit }
                let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard metadata.isSymbolicLink != true else { continue }
                if DocumentExtractor.isDocumentPackage(file) {
                    enumerator.skipDescendants()
                } else if metadata.isRegularFile != true { continue }
                guard DocumentExtractor.supports(file) else {
                    notices.append("\(file.lastPathComponent) : format ignoré")
                    continue
                }
                let resolved = file.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(root.path + "/") else {
                    notices.append("\(file.lastPathComponent) : lien hors périmètre ignoré")
                    continue
                }
                files.append(resolved)
                guard files.count <= 10_000 else { throw DocumentError.indexLimit }
            }
        } else { files = [root] }
        let index = try DocumentIndex(url: indexURL)
        let db = try IndexDatabase(url: index.url, writable: true)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL,
                path_terms TEXT NOT NULL, fingerprint TEXT NOT NULL, error TEXT);
            CREATE TABLE IF NOT EXISTS passages(id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL, location TEXT NOT NULL, text TEXT NOT NULL, file_terms TEXT NOT NULL);
            CREATE UNIQUE INDEX IF NOT EXISTS passage_order ON passages(file_id, ordinal);
            CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(text, file_terms,
                content='passages', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
            CREATE TRIGGER IF NOT EXISTS passage_insert AFTER INSERT ON passages BEGIN
                INSERT INTO search(rowid,text,file_terms) VALUES(new.id,new.text,new.file_terms); END;
            CREATE TRIGGER IF NOT EXISTS passage_delete AFTER DELETE ON passages BEGIN
                INSERT INTO search(search,rowid,text,file_terms) VALUES('delete',old.id,old.text,old.file_terms); END;
            """)
        try db.execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.execute("ROLLBACK") } }
        if try db.count("PRAGMA user_version") < Self.extractionVersion {
            try db.execute("DELETE FROM files; PRAGMA user_version=\(Self.extractionVersion)")
        }
        var previous = Dictionary(uniqueKeysWithValues: try db.rows("SELECT path,fingerprint,coalesce(error,'') FROM files")
            .map { ($0[0], ($0[1], $0[2])) })
        var indexedFiles = 0
        for (position, file) in files.sorted(by: { $0.path < $1.path }).enumerated() {
            try Task.checkCancellation()
            let filename = isDirectory ? String(file.path.dropFirst(root.path.count + 1)) : file.lastPathComponent
            onProgress("Indexation \(position + 1)/\(files.count) · \(file.lastPathComponent)")
            let old = previous.removeValue(forKey: filename)
            let fingerprint = try Self.fingerprint(file)
            if let old, old.0 == fingerprint, old.1.isEmpty { continue }
            try db.rows("INSERT INTO files(path,path_terms,fingerprint,error) VALUES(?,?,?,NULL) ON CONFLICT(path) DO UPDATE SET fingerprint=excluded.fingerprint,error=NULL",
                [filename, Self.fold(filename), fingerprint])
            let fileID = try db.count("SELECT id FROM files WHERE path=?", [filename])
            try db.rows("DELETE FROM passages WHERE file_id=?", [String(fileID)])
            try db.execute("SAVEPOINT document")
            do {
                var ordinal = 0
                try DocumentExtractor.forEachSection(url: file) { section in
                    try Task.checkCancellation()
                    if ordinal.isMultiple(of: 100) { onProgress("\(file.lastPathComponent) · \(section.location)") }
                    try PassageChunker.forEach(section) { location, text in
                        try db.rows("INSERT INTO passages(file_id,ordinal,location,text,file_terms) VALUES(?,?,?,?,?)",
                            [String(fileID), String(ordinal), location, text, filename])
                        ordinal += 1
                        if ordinal.isMultiple(of: 1000) { try Self.checkBudget(db) }
                    }
                }
                guard ordinal > 0 else { throw DocumentError.empty }
                guard try Self.fingerprint(file) == fingerprint else {
                    throw DocumentError.unreadable("le fichier a changé pendant sa lecture ; actualisez les sources")
                }
                try db.execute("RELEASE document")
                indexedFiles += 1
            } catch is CancellationError { throw CancellationError() }
            catch DocumentError.indexLimit { throw DocumentError.indexLimit }
            catch {
                try db.execute("ROLLBACK TO document; RELEASE document")
                if !isDirectory { throw error }
                try db.rows("UPDATE files SET error=? WHERE id=?", [error.localizedDescription, String(fileID)])
                notices.append("\(filename) : \(error.localizedDescription)")
            }
        }
        // Deleted and renamed files must not remain searchable in the cached index.
        for path in previous.keys { try db.rows("DELETE FROM files WHERE path=?", [path]) }
        try Self.checkBudget(db)
        let passageCount = try db.count("SELECT count(*) FROM passages")
        guard passageCount > 0 else { throw DocumentError.empty }
        let fileCount = try db.count("SELECT count(*) FROM files WHERE EXISTS(SELECT 1 FROM passages WHERE file_id=files.id)")
        try Task.checkCancellation()
        try db.execute("COMMIT")
        committed = true
        self.name = root.lastPathComponent
        self.fileCount = fileCount
        self.passageCount = passageCount
        self.notices = notices
        self.indexedFileCount = indexedFiles
        self.index = index
        self.root = root
        self.isDirectory = isDirectory
    }

    public func search(_ query: String, limit: Int = 5, file: String? = nil) throws -> [DocumentPassage] {
        let terms = Set(Self.fold(query).split { !$0.isLetter && !$0.isNumber }.prefix(64).map(String.init))
        guard !terms.isEmpty, (file?.count ?? 0) <= 500 else { return [] }
        let expression = terms.sorted().map { "\"\($0)\"" }.joined(separator: " OR ")
        let db = try IndexDatabase(url: index.url)
        return try db.rows("""
            SELECT p.id,f.path,p.location,p.text FROM search JOIN passages p ON p.id=search.rowid
            JOIN files f ON f.id=p.file_id WHERE search MATCH ? AND f.path_terms LIKE ? ESCAPE '\\'
            ORDER BY bm25(search,1,2),p.id LIMIT ?
            """, [expression, Self.likePattern(file), String(max(0, min(limit, 5)))]).map(Self.passage)
    }

    /// Renders the PDF page or picture an extract comes from, for vision-capable models.
    public func pageImage(id: String, maximumPixels: Int = 1280) throws -> (passage: DocumentPassage, jpeg: Data) {
        let passage = try read(id: id)
        let file = isDirectory ? root.appending(path: passage.file).standardizedFileURL : root
        guard !isDirectory || file.path.hasPrefix(root.path + "/"),
              try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw DocumentError.invalidTool
        }
        let image: CGImage
        if file.pathExtension.lowercased() == "pages" {
            let container = try IWorkArchive.Container(url: file)
            guard let match = passage.location.firstMatch(of: /^image ([0-9]+)/), let number = Int(match.1), number > 0,
                  let name = try PagesDocumentReader.imageNames(in: container).dropFirst(number - 1).first else {
                throw DocumentError.noPageImage
            }
            image = try PagesDocumentReader.image(name, in: container, maximumPixels: maximumPixels)
        } else if let match = passage.location.firstMatch(of: /^page ([0-9]+)/), let number = Int(match.1) {
            guard let document = PDFDocument(url: file), !document.isLocked,
                  let page = document.page(at: number - 1)?.pageRef else { throw DocumentError.noPageImage }
            image = try DocumentExtractor.render(page, maximumPixels: CGFloat(maximumPixels))
        } else if let match = passage.location.firstMatch(of: /^image ([0-9]+)/), let number = Int(match.1),
                  let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, number - 1, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumPixels
                  ] as CFDictionary) {
            image = thumbnail
        } else { throw DocumentError.noPageImage }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw DocumentError.noPageImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DocumentError.noPageImage }
        return (passage, data as Data)
    }

    public func read(id: String, offset: Int = 0) throws -> DocumentPassage {
        guard (-3...3).contains(offset), id.hasPrefix("S"),
              let number = Int64(id.dropFirst()), number > 0 else { throw DocumentError.invalidTool }
        let db = try IndexDatabase(url: index.url)
        guard let origin = try db.rows("SELECT file_id,ordinal FROM passages WHERE id=?", [String(number)]).first,
              let ordinal = Int(origin[1]), let row = try db.rows("""
                SELECT p.id,f.path,p.location,p.text FROM passages p JOIN files f ON f.id=p.file_id
                WHERE p.file_id=? AND p.ordinal=?
                """, [origin[0], String(ordinal + offset)]).first else { throw DocumentError.invalidTool }
        return Self.passage(row)
    }

    /// Writes the indexed text of the documents with these extensions under `directory`, at their relative path plus
    /// ".txt", each extract headed by its location; returns the paths written. Documents beyond the budget are left out.
    public func writeExtractedTexts(to directory: URL, extensions: Set<String>,
                                    maximumCharacters: Int = 50_000_000) throws -> [String] {
        guard !extensions.isEmpty else { return [] }
        let db = try IndexDatabase(url: index.url)
        let condition = extensions.sorted().map { _ in "lower(f.path) LIKE ?" }.joined(separator: " OR ")
        let files = try db.rows("SELECT f.id,f.path FROM files f WHERE (\(condition)) AND f.error IS NULL ORDER BY f.path",
            extensions.sorted().map { "%." + $0.lowercased() })
        let base = directory.standardizedFileURL.path + "/"
        var written: [String] = []
        var characters = 0
        for file in files {
            try Task.checkCancellation()
            let passages = try db.rows("SELECT location,text FROM passages WHERE file_id=? ORDER BY ordinal", [file[0]])
            let text = passages.map { "[\($0[0])]\n\($0[1])" }.joined(separator: "\n")
            characters += text.count
            guard characters <= maximumCharacters else { break }
            let target = directory.appending(path: file[1] + ".txt").standardizedFileURL
            guard target.path.hasPrefix(base) else { continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: target, options: .withoutOverwriting)
            written.append(file[1])
        }
        return written
    }

    func list(offset: Int, query: String? = nil) throws -> String {
        guard offset >= 0, (query?.count ?? 0) <= 500 else { throw DocumentError.invalidTool }
        let db = try IndexDatabase(url: index.url)
        let filter = Self.likePattern(query)
        let condition = "path_terms LIKE ? ESCAPE '\\' AND EXISTS(SELECT 1 FROM passages WHERE file_id=files.id)"
        let count = try db.count("SELECT count(*) FROM files WHERE \(condition)", [filter])
        guard offset <= count else { throw DocumentError.invalidTool }
        if offset == count { return "Fin de la liste des \(count) fichiers correspondants." }
        let rows = try db.rows("""
            SELECT path,(SELECT min(id) FROM passages WHERE file_id=files.id) FROM files
            WHERE \(condition) ORDER BY path LIMIT 30 OFFSET ?
            """, [filter, String(offset)])
        let items = rows.map { ["file": $0[0], "first_source_id": "S\($0[1])"] }
        return "Fichiers \(offset + 1)-\(offset + items.count) / \(count). Suite : offset=\(offset + items.count).\n"
            + String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
    }

    private static func likePattern(_ fragment: String?) -> String {
        "%" + fold(fragment ?? "").replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_") + "%"
    }

    private static func passage(_ row: [String]) -> DocumentPassage {
        DocumentPassage(id: "S\(row[0])", file: row[1], location: row[2], text: row[3])
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    private static func fingerprint(_ url: URL) throws -> String {
        let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isSymbolicLinkKey])
        guard metadata.isSymbolicLink != true else { throw DocumentError.unsupported }
        let own = "\(metadata.fileSize ?? -1):\(metadata.contentModificationDate?.timeIntervalSince1970 ?? 0):\(metadata.creationDate?.timeIntervalSince1970 ?? 0)"
        // A package folder keeps its dates when Pages rewrites the files inside it.
        guard DocumentExtractor.isDocumentPackage(url) else { return own }
        return own + "/" + (try fingerprint(url.appending(path: "Index/Document.iwa")))
    }

    private static func checkBudget(_ db: IndexDatabase) throws {
        let pages = try db.count("PRAGMA page_count")
        let size = try db.count("PRAGMA page_size")
        guard pages * size <= 2 * 1024 * 1024 * 1024,
              try db.count("SELECT count(*) FROM passages") <= 500_000 else { throw DocumentError.indexLimit }
    }
}

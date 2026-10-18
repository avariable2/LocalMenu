import Foundation

/// The objects of an iWork document saved by Pages 5 or later: a ZIP file, or a package folder, whose Index/*.iwa
/// members are chunks of Snappy-compressed protobuf messages. Nothing is extracted onto the filesystem.
struct IWorkArchive {
    private static let maximumMemberBytes = 64 * 1024 * 1024
    private static let maximumDecodedBytes = 256 * 1024 * 1024
    // Styles, view state and metadata hold no document content.
    private static let ignoredPrefixes = ["Index/DocumentStylesheet", "Index/ViewState", "Index/Metadata",
                                          "Index/DocumentMetadata", "Index/AnnotationAuthorStorage"]

    struct Object {
        let type: UInt32
        let payload: ArraySlice<UInt8>
    }

    let container: Container
    private(set) var objects: [UInt64: Object] = [:]

    init(url: URL) throws {
        container = try Container(url: url)
        let names = try container.names()
        if names.contains(".iwpv2") || names.contains(".iwph") {
            throw DocumentError.unreadable("document Pages protégé par un mot de passe ; retirez le mot de passe dans Pages pour l'indexer")
        }
        guard names.contains("Index/Document.iwa") else {
            throw DocumentError.unreadable(names.contains(where: { $0.hasPrefix("index.xml") })
                ? "ancien format Pages '09 ; ouvrez le document dans Pages puis enregistrez-le pour le convertir"
                : "document Pages invalide")
        }
        var budget = Self.maximumDecodedBytes
        for name in names.sorted() where name.hasPrefix("Index/") && name.hasSuffix(".iwa")
            && !Self.ignoredPrefixes.contains(where: name.hasPrefix) {
            try Task.checkCancellation()
            let compressed = [UInt8](try container.data(name, maximumBytes: Self.maximumMemberBytes))
            try read(Self.decompress(compressed, budget: &budget))
        }
    }

    func object(_ identifier: UInt64?, type: UInt32? = nil) -> Object? {
        guard let identifier, let object = objects[identifier], type == nil || object.type == type else { return nil }
        return object
    }

    /// Identifiers in ascending order, which follows the order objects were created in.
    func identifiers(ofType type: UInt32) -> [UInt64] {
        objects.filter { $0.value.type == type }.keys.sorted()
    }

    /// Each archive is a varint-prefixed TSP.ArchiveInfo (identifier, then the type and length of its messages)
    /// followed by those messages.
    private mutating func read(_ data: [UInt8]) throws {
        var index = 0
        while index < data.count {
            let length = try Int(exactly: ProtoMessage.varint(data, at: &index)) ?? Int.max
            guard length <= data.count - index else { throw Self.invalid }
            let info = try ProtoMessage(data[index..<(index + length)])
            index += length
            guard let identifier = info.varint(1) else { throw Self.invalid }
            for message in try info.messages(2) {
                guard let type = message.varint(1).flatMap(UInt32.init(exactly:)),
                      let size = message.varint(3).flatMap(Int.init(exactly:)), size <= data.count - index else {
                    throw Self.invalid
                }
                // A later message for the same identifier only merges into the first; the first holds the content.
                if objects[identifier] == nil { objects[identifier] = Object(type: type, payload: data[index..<(index + size)]) }
                index += size
            }
        }
    }

    static let invalid = DocumentError.unreadable("document Pages invalide")

    /// IWA files are a sequence of chunks: a zero byte, a 24-bit little-endian length, then a raw Snappy block.
    static func decompress(_ data: [UInt8], budget: inout Int) throws -> [UInt8] {
        var output: [UInt8] = []
        var index = 0
        while index < data.count {
            guard data[index] == 0, data.count - index >= 4 else { throw invalid }
            let length = Int(data[index + 1]) | Int(data[index + 2]) << 8 | Int(data[index + 3]) << 16
            index += 4
            guard length <= data.count - index else { throw invalid }
            try snappy(data[index..<(index + length)], into: &output, budget: &budget)
            index += length
        }
        return output
    }

    private static func snappy(_ block: ArraySlice<UInt8>, into output: inout [UInt8], budget: inout Int) throws {
        var index = block.startIndex
        let expected = try Int(exactly: ProtoMessage.varint(block, at: &index)) ?? Int.max
        guard expected <= budget else { throw DocumentError.tooLarge }
        budget -= expected
        let start = output.count
        output.reserveCapacity(start + min(expected, block.count * 8))
        func little(_ count: Int) throws -> Int {
            guard block.endIndex - index >= count else { throw invalid }
            let value = (0..<count).reduce(0) { $0 | Int(block[index + $1]) << (8 * $1) }
            index += count
            return value
        }
        while index < block.endIndex {
            let tag = block[index]
            index += 1
            if tag & 3 == 0 {
                var length = Int(tag >> 2)
                if length >= 60 { length = try little(length - 59) }
                length += 1
                guard length <= block.endIndex - index, output.count - start + length <= expected else { throw invalid }
                output.append(contentsOf: block[index..<(index + length)])
                index += length
                continue
            }
            let length: Int
            let offset: Int
            switch tag & 3 {
            case 1:
                length = Int(tag >> 2 & 7) + 4
                offset = try Int(tag >> 5) << 8 | little(1)
            case 2:
                length = Int(tag >> 2) + 1
                offset = try little(2)
            default:
                length = Int(tag >> 2) + 1
                offset = try little(4)
            }
            guard offset > 0, offset <= output.count - start, output.count - start + length <= expected else { throw invalid }
            // Copies may overlap their own output, so they go byte by byte.
            for _ in 0..<length { output.append(output[output.count - offset]) }
        }
        guard output.count - start == expected else { throw invalid }
    }

    /// A ZIP file is read through unzip; a package folder only for regular files inside it.
    struct Container {
        let url: URL
        let isPackage: Bool

        init(url: URL) throws {
            self.url = url
            isPackage = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }

        func names() throws -> [String] {
            guard isPackage else { return try OfficeDocumentReader.memberNames(in: url) }
            let root = url.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard let enumerator = FileManager.default.enumerator(at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw IWorkArchive.invalid }
            var names: [String] = []
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                let path = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard values.isSymbolicLink != true, values.isRegularFile == true, path.hasPrefix(root) else { continue }
                names.append(String(path.dropFirst(root.count)))
                guard names.count <= 100_000 else { throw DocumentError.tooLarge }
            }
            return names
        }

        func data(_ name: String, maximumBytes: Int) throws -> Data {
            guard isPackage else { return try OfficeDocumentReader.member(name, in: url, maximumBytes: maximumBytes) }
            guard !name.split(separator: "/").contains(".."), !name.hasPrefix("/") else { throw IWorkArchive.invalid }
            let file = url.appending(path: name)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw IWorkArchive.invalid }
            guard (values.fileSize ?? 0) <= maximumBytes else { throw DocumentError.tooLarge }
            return try Data(contentsOf: file)
        }
    }
}

/// A decoded protobuf message; fields keep their wire order and repeated fields their repetitions.
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(ArraySlice<UInt8>)
        case fixed32(UInt32)
    }

    let fields: [(number: Int, value: Value)]

    init(_ bytes: ArraySlice<UInt8>) throws {
        var fields: [(Int, Value)] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let key = try Self.varint(bytes, at: &index)
            guard let number = Int(exactly: key >> 3), number > 0 else { throw IWorkArchive.invalid }
            switch key & 7 {
            case 0: fields.append((number, .varint(try Self.varint(bytes, at: &index))))
            case 1:
                guard bytes.endIndex - index >= 8 else { throw IWorkArchive.invalid }
                fields.append((number, .fixed64((0..<8).reduce(0) { $0 | UInt64(bytes[index + $1]) << (8 * $1) })))
                index += 8
            case 2:
                let length = try Int(exactly: Self.varint(bytes, at: &index)) ?? Int.max
                guard length <= bytes.endIndex - index else { throw IWorkArchive.invalid }
                fields.append((number, .bytes(bytes[index..<(index + length)])))
                index += length
            case 5:
                guard bytes.endIndex - index >= 4 else { throw IWorkArchive.invalid }
                fields.append((number, .fixed32((0..<4).reduce(0) { $0 | UInt32(bytes[index + $1]) << (8 * $1) })))
                index += 4
            default: throw IWorkArchive.invalid
            }
        }
        self.fields = fields
    }

    static func varint<C: Collection<UInt8>>(_ bytes: C, at index: inout C.Index) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 7) {
            guard index < bytes.endIndex else { break }
            let byte = bytes[index]
            bytes.formIndex(after: &index)
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
        }
        throw IWorkArchive.invalid
    }

    func varint(_ number: Int) -> UInt64? {
        for field in fields where field.number == number { if case .varint(let value) = field.value { return value } }
        return nil
    }

    func double(_ number: Int) -> Double? {
        for field in fields where field.number == number {
            if case .fixed64(let bits) = field.value { return Double(bitPattern: bits) }
        }
        return nil
    }

    func allBytes(_ number: Int) -> [ArraySlice<UInt8>] {
        fields.compactMap { field in
            guard field.number == number, case .bytes(let bytes) = field.value else { return nil }
            return bytes
        }
    }

    func bytes(_ number: Int) -> ArraySlice<UInt8>? { allBytes(number).first }

    func strings(_ number: Int) -> [String] { allBytes(number).map { String(decoding: $0, as: UTF8.self) } }

    func string(_ number: Int) -> String? { strings(number).first }

    func messages(_ number: Int) throws -> [ProtoMessage] { try allBytes(number).map(ProtoMessage.init) }

    func message(_ number: Int) throws -> ProtoMessage? { try bytes(number).map(ProtoMessage.init) }

    /// TSP.Reference: a message whose field 1 is the identifier of another object.
    func reference(_ number: Int) throws -> UInt64? { try message(number)?.varint(1) }
}

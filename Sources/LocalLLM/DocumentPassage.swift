import Foundation

public struct DocumentPassage: Codable, Sendable, Identifiable {
    public let id: String
    public let file: String
    public let location: String
    public let text: String
}

public struct SourceReference: Sendable, Identifiable {
    public let id: String
    public let file: String
    public let location: String
}

public struct DocumentAnswer: Sendable {
    public let text: String
    public let sources: [SourceReference]
    public let toolsUsed: [String]
}

struct ExtractedSection {
    let location: String
    let text: String
    var startLine = 1
}

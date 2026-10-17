import Foundation

final class OfficeXML: NSObject, XMLParserDelegate {
    private let start: (String, [String: String]) -> Void
    private let end: (String) -> Void
    private let text: (String) -> Void
    private var nodes = 0

    init(start: @escaping (String, [String: String]) -> Void = { _, _ in },
         end: @escaping (String) -> Void = { _ in }, text: @escaping (String) -> Void = { _ in }) {
        self.start = start
        self.end = end
        self.text = text
    }

    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else { throw DocumentError.unreadable("XML Office invalide ou trop complexe") }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        nodes += 1
        guard nodes <= 500_000 else { parser.abortParsing(); return }
        start(elementName.components(separatedBy: ":").last ?? elementName, attributeDict)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        end(elementName.components(separatedBy: ":").last ?? elementName)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text(string) }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                publicID: String?, systemID: String?) { parser.abortParsing() }
}

import Foundation
import Testing
@testable import LocalLLM

struct DocumentAgentTests {
    private func client(scenario: String = "normal") -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DocumentAgentStub.self]
        configuration.httpAdditionalHeaders = ["X-Test-Scenario": scenario]
        return OllamaClient(session: URLSession(configuration: configuration))
    }

    @Test func executesListReadAndSearchWithVerifiedReferences() async throws {
        let library = try DocumentFixtures.library()
        let result = try await client().answer(question: "Date de livraison ?", library: library)
        #expect(result.text.contains("18 novembre 2026"))
        #expect(result.sources.count == 1)
        #expect(result.sources.first?.file == "planning.txt")
        #expect(result.sources.first?.id == "S1")
        #expect(result.toolsUsed == ["list_documents", "read_passage", "search_documents"])
    }

    @Test(arguments: ["unknownCitation", "noCitation", "noLookup", "noTools", "cloud", "loop"])
    func rejectsUnsafeOrUnusableModelResponses(scenario: String) async throws {
        let library = try DocumentFixtures.library()
        await #expect(throws: DocumentError.self) {
            try await client(scenario: scenario).answer(question: "Date ?", library: library)
        }
    }

    @Test func visionModelsCanLookAtTheChartPage() async throws {
        // The page is rendered from the original file, which must outlive the library here.
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try DocumentFixtures.writeMixedPDF(at: root.appending(path: "rapport.pdf"))
        let library = try DocumentLibrary(url: root)
        let result = try await client(scenario: "vision").answer(question: "Date de la figure 1 ?", library: library)
        #expect(result.toolsUsed == ["view_page"])
        #expect(result.sources.first?.file == "rapport.pdf")
        #expect(result.sources.first?.location.contains("page 1") == true)
    }

    @Test(arguments: [true, false])
    func pointsVisionModelsFromChartOCRToThePage(vision: Bool) async throws {
        let library = try DocumentFixtures.withDirectory { root in
            try DocumentFixtures.writeMixedPDF(at: root.appending(path: "rapport.pdf"))
            return try DocumentLibrary(url: root)
        }
        let result = try await client(scenario: vision ? "ocrHint" : "ocrNoHint").answer(question: "Date ?", library: library)
        #expect(result.toolsUsed == ["search_documents"])
    }

    @Test func repairsMissingCitationOnceBeforeAcceptingAnswer() async throws {
        let library = try DocumentFixtures.library()
        let result = try await client(scenario: "repair").answer(question: "Date ?", library: library)
        #expect(result.sources.first?.id == "S1")
    }

    @Test func invalidToolsCannotReadOutsideSelectedScope() async throws {
        let library = try DocumentFixtures.library()
        let result = try await client(scenario: "badTool").answer(question: "Date ?", library: library)
        #expect(result.toolsUsed == ["search_documents"])
        #expect(result.sources.first?.file == "planning.txt")
    }

    @Test func rejectsOversizedQuestionsBeforeContactingModel() async throws {
        let library = try DocumentFixtures.library()
        await #expect(throws: DocumentError.self) {
            try await client(scenario: "noNetwork").answer(question: String(repeating: "a", count: 8001), library: library)
        }
    }

    @Test func rejectsCloudAliasesEvenWithoutDocuments() async {
        await #expect(throws: DocumentError.self) {
            try await client(scenario: "cloud").answer(question: "Question privée")
        }
    }

    @Test func propagatesCancellation() async throws {
        let library = try DocumentFixtures.library()
        do {
            _ = try await client(scenario: "cancel").answer(question: "Date ?", library: library)
            Issue.record("Annulation attendue")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
    }

    @Test func refusesHTTPRedirects() throws {
        let delegate = LocalOnlySessionDelegate()
        let url = try #require(URL(string: "http://127.0.0.1:11434/api/chat"))
        let task = URLSession.shared.dataTask(with: url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil))
        let external = try #require(URL(string: "https://example.com"))
        delegate.urlSession(.shared, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: external)) { redirected in
                #expect(redirected == nil)
            }
        task.cancel()
    }
}

private final class DocumentAgentStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let scenario = request.value(forHTTPHeaderField: "X-Test-Scenario") ?? "normal"
            if scenario == "noNetwork" {
                Issue.record("Aucune requête attendue pour une question trop longue")
                throw URLError(.notConnectedToInternet)
            }
            if scenario == "cancel" {
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
            let url = try #require(request.url)
            #expect(url.host == "127.0.0.1")
            let output: [String: Any]
            switch url.path {
            case "/api/tags": output = ["models": [["name": "qwen3:4b"]]]
            case "/api/show":
                output = scenario == "cloud" ? ["capabilities": ["tools"], "remote_host": "https://example.com"]
                    : ["capabilities": scenario == "noTools" ? ["completion"]
                        : ["vision", "ocrHint"].contains(scenario) ? ["tools", "vision"] : ["tools"]]
            case "/api/chat":
                #expect(scenario != "cloud" && scenario != "noTools")
                let payload = try body()
                #expect(payload["think"] as? Bool == false)
                let messages = try #require(payload["messages"] as? [[String: Any]])
                let tools = try #require(payload["tools"] as? [[String: Any]]).compactMap {
                    ($0["function"] as? [String: Any])?["name"] as? String
                }
                #expect(tools.contains("view_page") == ["vision", "ocrHint"].contains(scenario))
                let results = messages.filter { $0["role"] as? String == "tool" }
                var tool: (String, [String: Any])?
                var text = "La livraison est le 18 novembre 2026 [S1]."
                if scenario == "vision" {
                    if results.isEmpty { tool = ("view_page", ["source_id": "S1"]) }
                    else {
                        let page = try #require(messages.last)
                        #expect(page["role"] as? String == "user")
                        let image = try #require((page["images"] as? [String])?.first.flatMap { Data(base64Encoded: $0) })
                        #expect(image.starts(with: [0xFF, 0xD8]))
                        text = "La figure indique le 25 novembre 2026 [S1]."
                    }
                } else if scenario.hasPrefix("ocr") {
                    if results.isEmpty { tool = ("search_documents", ["query": "ORION"]) }
                    else {
                        let content = results[0]["content"] as? String ?? ""
                        #expect(content.contains("ORION"))
                        #expect(content.contains("regarde la page avec view_page") == (scenario == "ocrHint"))
                    }
                } else if scenario == "loop" { tool = ("search_documents", ["query": "AZUR"]) }
                else if scenario == "noLookup" { text = "Je devine : demain." }
                else if scenario == "badTool" {
                    if results.isEmpty { tool = ("read_passage", ["source_id": "/etc/passwd"]) }
                    else if results.count == 1 {
                        #expect((results[0]["content"] as? String)?.contains("non autorisé") == true)
                        tool = ("run_shell", ["query": "cat /etc/passwd"])
                    } else if results.count == 2 {
                        #expect((results[1]["content"] as? String)?.contains("non autorisé") == true)
                        tool = ("search_documents", ["query": "AZUR"])
                    }
                } else if results.count == 0 { tool = ("list_documents", [:]) }
                else if results.count == 1 { tool = ("read_passage", ["source_id": "S1"]) }
                else if results.count == 2 { tool = ("search_documents", ["query": "AZUR"]) }
                if scenario == "unknownCitation" { text = "Date [S9999]." }
                if scenario == "noCitation" { text = "Date sans référence." }
                if scenario == "repair" && !messages.contains(where: {
                    ($0["content"] as? String)?.contains("Réponse rejetée") == true
                }) { text = "Date sans référence." }
                if let (name, arguments) = tool {
                    output = ["message": ["role": "assistant", "content": "", "tool_calls": [
                        ["function": ["name": name, "arguments": arguments]]
                    ]]]
                } else { output = ["message": ["role": "assistant", "content": text]] }
            default:
                Issue.record("Unexpected endpoint: \(url.path)")
                throw DocumentError.invalidTool
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: output))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func body() throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

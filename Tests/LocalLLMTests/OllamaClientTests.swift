import Foundation
import Testing
@testable import LocalLLM

struct OllamaClientTests {
    private func client() -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStub.self]
        return OllamaClient(session: URLSession(configuration: configuration))
    }

    @Test func sendsLocalNonStreamingRequest() async throws {
        let result = try await client().answer(question: " Bonjour ", model: " qwen3:4b ")
        #expect(result == "Réponse locale")
    }

    @Test func sendsLongPastedTextWithoutDocumentCitationRequirements() async throws {
        #expect(OllamaStub.longQuestion.count > 8000)
        let result = try await client().answer(question: OllamaStub.longQuestion)
        #expect(result == "Résumé du texte collé")
    }

    @Test func automaticallyUsesInstalledModel() async throws {
        let result = try await client().answer(question: "Bonjour")
        #expect(result == "Réponse locale")
    }

    @Test func rejectsMissingOrAmbiguousModels() throws {
        let empty = try JSONDecoder().decode(InstalledModels.self, from: Data("{\"models\":[]}".utf8))
        #expect(throws: OllamaError.self) { try empty.onlyModel() }
        let multiple = try JSONDecoder().decode(InstalledModels.self, from: Data(
            "{\"models\":[{\"name\":\"one\"},{\"name\":\"two\"}]}".utf8
        ))
        #expect(throws: OllamaError.self) { try multiple.onlyModel() }
    }

    @Test func prefersInstallerManagedAliasWithoutDeletingOtherModels() throws {
        let models = try JSONDecoder().decode(InstalledModels.self, from: Data(
            "{\"models\":[{\"name\":\"other\"},{\"name\":\"localmenu-assistant:latest\"}]}".utf8
        ))
        let selected = try models.onlyModel()
        #expect(selected == "localmenu-assistant:latest")
    }

    @Test func rejectsEmptyInput() async {
        await #expect(throws: OllamaError.self) {
            try await client().answer(question: " \n", model: "qwen3:4b")
        }
        await #expect(throws: OllamaError.self) {
            try await client().answer(question: "Bonjour", model: " ")
        }
    }

    @Test func reportsMissingModel() async {
        do {
            _ = try await client().answer(question: "missing", model: "qwen3:4b")
            Issue.record("Une erreur 404 était attendue")
        } catch OllamaError.http(404) {
        } catch {
            Issue.record("Erreur inattendue : \(error)")
        }
    }

    @Test func rejectsMalformedResponse() async {
        await #expect(throws: DecodingError.self) {
            try await client().answer(question: "malformed", model: "qwen3:4b")
        }
    }

    @Test func rejectsEmptyResponse() async {
        await #expect(throws: OllamaError.self) {
            try await client().answer(question: "empty", model: "qwen3:4b")
        }
    }
}

private final class OllamaStub: URLProtocol, @unchecked Sendable {
    static let longQuestion = "Résume ce texte :\n" + Array(repeating: "Le projet prépare une livraison pour décembre.", count: 400).joined(separator: "\n")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            if request.url?.path == "/api/show" {
                #expect(request.httpMethod == "POST")
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                ))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{\"capabilities\":[\"completion\",\"tools\"]}".utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            if request.url?.path == "/api/tags" {
                #expect(request.httpMethod == "GET")
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                ))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{\"models\":[{\"name\":\"qwen3:4b\"}]}".utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/generate")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(payload["stream"] as? Bool == false)
            #expect(payload["model"] as? String == "qwen3:4b")
            let prompt = try #require(payload["prompt"] as? String)
            let status = prompt == "missing" ? 404 : 200
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil
            ))
            let output: String
            switch prompt {
            case "missing": output = "{\"error\":\"not found\"}"
            case "malformed": output = "not json"
            case "empty": output = "{\"response\":\"  \"}"
            case Self.longQuestion: output = "{\"response\":\"Résumé du texte collé\"}"
            default:
                #expect(prompt == "Bonjour")
                output = "{\"response\":\"Réponse locale\"}"
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(output.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

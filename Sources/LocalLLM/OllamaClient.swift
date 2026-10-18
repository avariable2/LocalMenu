import Foundation

public struct OllamaClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func answer(question: String) async throws -> String {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OllamaError.invalidInput
        }
        return try await answer(question: question, model: selectedModel())
    }

    public func answer(question: String, model: String) async throws -> String {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !model.isEmpty else { throw OllamaError.invalidInput }
        guard !model.lowercased().contains("cloud") else { throw DocumentError.cloudModel }
        _ = try await localDetails(model: model)
        let result: GenerateResponse = try await request(path: "generate", body:
            JSONEncoder().encode(GenerateRequest(model: model, prompt: question)))
        let answer = result.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw OllamaError.invalidResponse }
        return answer
    }

    func selectedModel() async throws -> String {
        let models: InstalledModels = try await request(path: "tags")
        let name = try models.onlyModel()
        guard !name.lowercased().contains("cloud") else { throw DocumentError.cloudModel }
        return name
    }

    func localDetails(model: String) async throws -> ModelDetails {
        let details: ModelDetails = try await request(path: "show", body: JSONEncoder().encode(["model": model]))
        guard (details.remote_host ?? "").isEmpty, (details.remote_model ?? "").isEmpty else {
            throw DocumentError.cloudModel
        }
        return details
    }

    func request<Response: Decodable>(path: String, body: Data? = nil) async throws -> Response {
        guard let url = URL(string: "http://127.0.0.1:11434/api/\(path)") else { throw OllamaError.invalidInput }
        var request = URLRequest(url: url, timeoutInterval: body == nil ? 5 : 300)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request, delegate: LocalOnlySessionDelegate())
        guard let response = response as? HTTPURLResponse else { throw OllamaError.invalidResponse }
        guard response.statusCode == 200 else { throw OllamaError.http(response.statusCode) }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private struct GenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream = false
    let think = false
    let system = AnswerStyle.concise + " Aucun document n'est joint et tu n'as pas accès au Mac. Pour une question sur un fichier, demande de le joindre avec le trombone ; n'invente jamais son contenu."
}

private struct GenerateResponse: Decodable {
    let response: String
}

public enum OllamaError: LocalizedError {
    case invalidInput
    case invalidResponse
    case http(Int)
    case noModel
    case multipleModels

    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Saisissez une question."
        case .noModel: "Aucun modèle installé. Téléchargez-en un avec ollama pull <modèle>."
        case .multipleModels: "Plusieurs modèles sont installés sans modèle LocalMenu configuré. Relancez scripts/install.sh."
        case .invalidResponse: "Réponse Ollama vide ou invalide."
        case .http(404): "Modèle introuvable. Installez-le avec ollama pull <modèle>."
        case .http(let status): "Ollama a renvoyé une erreur HTTP \(status)."
        }
    }
}

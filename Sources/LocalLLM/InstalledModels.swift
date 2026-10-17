import Foundation

struct InstalledModels: Decodable {
    let models: [Model]

    struct Model: Decodable {
        let name: String
    }

    func onlyModel() throws -> String {
        if models.contains(where: { $0.name == "localmenu-assistant:latest" }) {
            return "localmenu-assistant:latest"
        }
        guard let model = models.first else { throw OllamaError.noModel }
        guard models.count == 1 else { throw OllamaError.multipleModels }
        guard !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OllamaError.invalidResponse
        }
        return model.name
    }
}

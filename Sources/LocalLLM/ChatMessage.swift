import Foundation

struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
    var tool_calls: [ToolCall]?
    var tool_name: String?
    var images: [String]?

    struct ToolCall: Codable, Sendable {
        let id: String?
        let function: Function

        struct Function: Codable, Sendable {
            let name: String
            let arguments: Arguments
        }

        struct Arguments: Codable, Sendable {
            let query: String?
            let source_id: String?
            let offset: Int?
            let file: String?
        }
    }
}

struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let tools: [DocumentTool]
    let stream = false
    let think = false
    let options = Options()

    struct Options: Encodable {
        let temperature = 0
        let num_ctx = 16384
        let num_predict = 4096
    }
}

struct ChatResponse: Decodable {
    let message: ChatMessage
}

struct DocumentTool: Encodable {
    let type = "function"
    let function: Function

    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: Parameters
    }

    struct Parameters: Encodable {
        let type = "object"
        let properties: [String: Property]
        let required: [String]
        let additionalProperties = false
    }

    struct Property: Encodable {
        let type: String
        let description: String
    }

    static func available(vision: Bool) -> [DocumentTool] { vision ? all + [viewPage] : all }

    static let viewPage = DocumentTool(function: Function(name: "view_page",
        description: "Regarder l'image de la page PDF ou de l'image d'où vient un extrait : graphiques, schémas, tableaux, photos. À utiliser quand la question porte sur une figure ou quand le texte extrait est incomplet.",
        parameters: Parameters(properties: [
            "source_id": Property(type: "string", description: "Identifiant S1, S2… d'un extrait de la page à regarder")
        ], required: ["source_id"])))

    static let all: [DocumentTool] = [
        DocumentTool(function: Function(name: "list_documents",
            description: "Trouver un fichier autorisé par un fragment de son nom ou chemin relatif (query), ou lister les fichiers sans filtre. Pages de 30 fichiers avec premier source_id.",
            parameters: Parameters(properties: [
                "offset": Property(type: "integer", description: "Index du premier fichier, 0 par défaut"),
                "query": Property(type: "string", description: "Fragment du nom du fichier, facultatif")
            ], required: []))),
        DocumentTool(function: Function(name: "search_documents",
            description: "Chercher des extraits par mots-clés dans les fichiers autorisés, y compris le texte lu dans les images et graphiques. Utiliser des termes distinctifs, noms ou références. Réessayer avec d'autres mots si nécessaire.",
            parameters: Parameters(properties: [
                "query": Property(type: "string", description: "Mots-clés à rechercher"),
                "file": Property(type: "string", description: "Fragment du nom de fichier pour limiter la recherche à ce document, facultatif")
            ], required: ["query"]))),
        DocumentTool(function: Function(name: "read_passage",
            description: "Lire un extrait par son source_id, ou un extrait voisin du même fichier.",
            parameters: Parameters(properties: [
                "source_id": Property(type: "string", description: "Identifiant S1, S2… fourni par un outil"),
                "offset": Property(type: "integer", description: "Décalage entre -3 et 3, 0 par défaut, 1 pour l'extrait suivant")
            ], required: ["source_id"])))
    ]
}

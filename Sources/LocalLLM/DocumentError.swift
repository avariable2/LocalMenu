import Foundation

public enum DocumentError: LocalizedError {
    case unsupported
    case tooLarge
    case unreadable(String)
    case empty
    case indexLimit
    case invalidTool
    case invalidCitation
    case toolLimit
    case toolsUnsupported
    case cloudModel
    case questionTooLong
    case indexStorage(String)
    case noPageImage

    public var errorDescription: String? {
        switch self {
        case .unsupported: "Format non pris en charge ou lien symbolique : texte, code, PDF, image, DOCX, XLSX ou CSV requis."
        case .tooLarge: "Document hors limites : 512 Mo et 10 000 pages maximum ; Office reste limité à 32 Mo et 2 millions de caractères, une page PDF à 2 millions de caractères."
        case .unreadable(let detail): "Lecture impossible : \(detail)"
        case .empty: "Aucun texte exploitable dans les sources choisies."
        case .indexLimit: "Index trop volumineux : maximum 10 000 fichiers, 50 000 entrées, 500 000 extraits ou 2 Go. Choisissez un sous-dossier."
        case .invalidTool: "Outil ou extrait demandé non autorisé."
        case .invalidCitation: "Références aux sources non vérifiables. Pour analyser uniquement du texte collé, désactivez Rechercher dans les sources dans le menu Actions, puis réessayez."
        case .toolLimit: "Recherche interrompue : limite d'appels d'outils atteinte. Précisez votre question."
        case .toolsUnsupported: "Ce modèle ne prend pas en charge les appels d'outils. Choisissez un modèle compatible dans Ollama."
        case .cloudModel: "Utilisez un modèle local, pas un modèle cloud."
        case .questionTooLong: "Question trop longue : maximum 8 000 caractères."
        case .indexStorage(let detail): "Erreur de l'index local : \(detail)"
        case .noPageImage: "Aucune image de page pour cet extrait : seuls les PDF et les images en ont une."
        }
    }
}

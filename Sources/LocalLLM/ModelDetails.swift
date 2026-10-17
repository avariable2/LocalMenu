import Foundation

struct ModelDetails: Decodable {
    let capabilities: [String]
    let remote_host: String?
    let remote_model: String?
}

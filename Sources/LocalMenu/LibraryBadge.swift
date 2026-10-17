import SwiftUI
import LocalLLM

struct LibraryBadge: View {
    let library: DocumentLibrary
    let isLoading: Bool
    let isActive: Bool
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(library.name, systemImage: "doc")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(library.name)
                Spacer()
                Text(isActive ? (library.fileCount == 1 ? "1 fichier" : "\(library.fileCount) fichiers") : "En pause")
                Button("Oublier les sources et effacer les index", systemImage: "xmark", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                    .help("Oublier les sources et effacer les index locaux")
            }
            if !library.notices.isEmpty {
                Text("\(library.notices.count) fichier(s) ou accès ignoré(s)")
                    .foregroundStyle(.orange)
                    .help(library.notices.prefix(30).joined(separator: "\n"))
                    .accessibilityHint(library.notices.prefix(10).joined(separator: ". "))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

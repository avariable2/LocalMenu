import SwiftUI
import LocalLLM

struct AnswerView: View {
    let text: String
    let sources: [SourceReference]
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(formattedText)
                    .font(.body)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !sources.isEmpty {
                    Divider()
                    ForEach(sources) { source in
                        Text("[\(source.id)] \(source.file) · \(source.location)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                contentHeight = height
            }
        }
        .frame(height: min(contentHeight, 280))
        .environment(\.openURL, OpenURLAction { _ in .discarded })
    }

    private var formattedText: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

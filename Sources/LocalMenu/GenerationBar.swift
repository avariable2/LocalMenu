import SwiftUI

/// A hairline along the bottom of the question field: it sweeps while the answer is generated,
/// then fills the whole width for a moment once the complete answer is ready.
struct GenerationBar: View {
    let isGenerating: Bool
    let showsCompletion: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if isGenerating {
                if reduceMotion {
                    Rectangle().fill(.tint.opacity(0.35))
                } else {
                    TimelineView(.animation) { timeline in
                        let period = 1.4
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        let width = proxy.size.width * 0.3
                        Capsule()
                            .fill(.tint)
                            .frame(width: width)
                            .offset(x: (proxy.size.width + width) * phase - width)
                    }
                }
            } else if showsCompletion {
                Rectangle()
                    .fill(.tint)
                    .transition(.opacity)
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.4), value: showsCompletion)
    }
}

/// Copies the answer; after any copy, automatic or manual, it shows a checkmark for a moment.
struct CopyAnswerButton: View {
    let showsCopied: Bool
    let copy: () -> Void

    var body: some View {
        Button(showsCopied ? "Réponse copiée" : "Copier la réponse",
               systemImage: showsCopied ? "checkmark" : "doc.on.doc", action: copy)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .contentTransition(.symbolEffect(.replace))
            // The symbol is a point taller than the text field; keep the row, and so the panel, from growing.
            .frame(height: 16)
            .help(showsCopied ? "Réponse copiée dans le presse-papiers" : "Copier la réponse dans le presse-papiers")
    }
}

import SwiftUI

struct ChatView: View {
    @Bindable var chat: ChatModel
    @FocusState private var isInputFocused: Bool
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Choisir un fichier ou dossier", systemImage: "paperclip", action: chat.chooseSource)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(!chat.canChooseSource)
                    .help("Changer les sources, même pendant une indexation")
                TextField(chat.usesDocuments ? "Question sur les sources…" : "Une question…", text: $chat.question)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(chat.usesDocuments
                        ? "Question sur les sources jointes. Entrée pour envoyer."
                        : "Votre question. Entrée pour envoyer.")
                    .focused($isInputFocused)
                    .onSubmit(chat.submit)
                    .disabled(chat.isLoading)
                if chat.engine == .claudeCode {
                    Image(systemName: "cloud")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .help("Claude Code : la question et les extraits lus sont envoyés à Anthropic")
                        .accessibilityLabel("Moteur Claude Code, hors du Mac")
                }
                if chat.isLoading {
                    if !(chat.autoCopy && chat.isAnswering) {
                        ProgressView(chat.activity)
                            .labelsHidden()
                            .controlSize(.small)
                            .help(chat.activity)
                    }
                    Button("Annuler", systemImage: "stop.circle", action: chat.cancel)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Annuler la réponse")
                } else if chat.autoCopy, !chat.answer.isEmpty {
                    CopyAnswerButton(showsCopied: chat.justCopied, copy: chat.copyAnswer)
                }
                Menu("Actions", systemImage: "ellipsis") {
                    Toggle("Rechercher dans les sources", isOn: $chat.useSources)
                        .disabled(chat.isLoading || chat.attachment == nil)
                    Toggle("Copier automatiquement la réponse", isOn: $chat.autoCopy)
                    Picker("Moteur", selection: $chat.engine) {
                        ForEach(Engine.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(chat.isLoading)
                    Button("Actualiser les sources", systemImage: "arrow.clockwise", action: chat.refreshSources)
                        .disabled(!chat.canRefreshSources)
                    Button("Tout effacer (sources et index)", systemImage: "trash", action: chat.clear)
                        .disabled(chat.isLoading)
                    Divider()
                    Button("Quitter LocalMenu", action: quit)
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Actions")
            }
            .padding(10)
            .background(.background, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                if chat.autoCopy {
                    GenerationBar(isGenerating: chat.isAnswering, showsCompletion: chat.justCompleted)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .clipShape(.rect(cornerRadius: 10))
                }
            }

            if chat.isLoading {
                Text(chat.activity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
            }

            if let attachment = chat.attachment {
                LibraryBadge(library: attachment, isLoading: chat.isLoading, isActive: chat.useSources, remove: chat.removeAttachment)
            }

            if let error = chat.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 4)
            }

            // In copy mode the answer goes straight to the clipboard; the panel only confirms it.
            if !chat.answer.isEmpty, !chat.autoCopy {
                Divider()
                    .padding(.horizontal, 2)
                AnswerView(text: chat.answer, sources: chat.sources)
            }
        }
        .padding(10)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PanelHeightFitter(height: contentHeight))
        .onAppear(perform: focusInput)
        .onChange(of: chat.isLoading) { _, isLoading in
            if !isLoading { focusInput() }
        }
    }

    private func focusInput() {
        isInputFocused = true
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

import AppKit

@MainActor
final class SourcePicker {
    private var panel: NSOpenPanel?

    func choose(completion: @escaping @MainActor (URL) -> Void) {
        if let panel {
            NSApplication.shared.activate()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Sources documentaires"
        panel.message = "Lecture seule. Les extraits seront indexés sur ce Mac et les sources mémorisées. Retirez les sources avec la croix pour effacer l’index et l’autorisation enregistrée."
        panel.prompt = "Choisir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        self.panel = panel
        NSApplication.shared.activate()
        Task {
            let result = await panel.begin()
            self.panel = nil
            if result == .OK, let url = panel.url { completion(url) }
        }
    }
}

import SwiftUI

@main
struct LocalMenuApp: App {
    @State private var chat = ChatModel()

    var body: some Scene {
        MenuBarExtra {
            ChatView(chat: chat)
        } label: {
            Image(systemName: "circle")
                .imageScale(.small)
                .accessibilityLabel("LocalMenu")
                .help("LocalMenu")
        }
        .menuBarExtraStyle(.window)
    }
}

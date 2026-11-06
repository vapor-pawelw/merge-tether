import SwiftUI

struct AssistantContextMenu: View {
    let mergeRequestURL: URL
    let title: String
    var workspace: String = ""
    @State private var destinations: [AssistantContextLauncher.Destination] = []
    @State private var isOpening = false
    @State private var openFailed = false

    @MainActor
    init(mergeRequestURL: URL, title: String, workspace: String = "") {
        self.mergeRequestURL = mergeRequestURL
        self.title = title
        self.workspace = workspace
        // Native nested menu content may never run its SwiftUI task before opening.
        _destinations = State(initialValue: AssistantContextLauncher.availableDestinations())
    }

    var body: some View {
        Menu {
            ForEach(destinations) { destination in
                Button {
                    isOpening = true
                    Task {
                        defer { isOpening = false }
                        do {
                            try await AssistantContextLauncher.open(destination,
                                context: .init(url: mergeRequestURL, title: title), workspace: workspace)
                        } catch { openFailed = true }
                    }
                } label: { Text(destination.label) }
            }
            if destinations.isEmpty { Text(.AssistantContext.assistantContextNone) }
            Divider()
            Button {
                AssistantAutomationRunner.copyPrompt(AssistantLaunchContext(url: mergeRequestURL, title: title).prompt)
            } label: { Text(.AssistantContext.assistantContextCopy) }
        } label: {
            Label { Text(.AssistantContext.assistantContextOpen) } icon: { Image(systemName: "ellipsis.circle") }
        }
        .disabled(isOpening)
        .task { destinations = AssistantContextLauncher.availableDestinations() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            destinations = AssistantContextLauncher.availableDestinations()
        }
        .alert(Text(.AssistantContext.assistantContextFailed), isPresented: $openFailed) {
            Button(role: .cancel) {} label: { Text(.AssistantContext.assistantContextOk) }
        }
        .help(Text(.AssistantContext.assistantContextHelp))
    }
}

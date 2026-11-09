import AppKit
import SwiftUI

struct AssistantContextMenu: View {
    let mergeRequestURL: URL
    let title: String
    let settings: SettingsManager
    @State private var isOpening = false

    private var context: AssistantLaunchContext { .init(url: mergeRequestURL, title: title) }

    var body: some View {
        Group {
            if #available(macOS 15, *) {
                defaultAction.modifierKeyAlternate(.option) { chooseAction }
            } else {
                defaultAction
            }
        }
        .disabled(isOpening)
        .help(Text(.AssistantContext.assistantContextHelp))
    }

    private var defaultAction: some View {
        Button {
            if NSEvent.modifierFlags.contains(.option)
                || !AssistantContextLauncher.availableDestinations().contains(settings.conversationDestination) {
                choose()
            } else {
                open(settings.conversationDestination)
            }
        } label: {
            Label {
                Text(.AssistantContext.assistantContextStartIn(String(localized: settings.conversationDestination.label)))
            } icon: { Image(systemName: "bubble.left.and.bubble.right") }
        }
    }

    private var chooseAction: some View {
        Button(action: choose) {
            Label { Text(.AssistantContext.assistantContextOpen) } icon: { Image(systemName: "bubble.left.and.bubble.right") }
        }
    }

    private func choose() {
        Task {
            // Native menus dispose their SwiftUI content when dismissed. An AppKit sheet
            // keeps the chooser alive independently of that temporary menu presenter.
            let destinations = AssistantContextLauncher.availableDestinations()
            let alert = NSAlert()
            alert.messageText = String(localized: .AssistantContext.assistantContextOpen)
            alert.informativeText = String(localized: destinations.isEmpty
                ? .AssistantContext.assistantContextNone : .AssistantContext.assistantContextChooseHelp)
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28), pullsDown: false)
            picker.addItems(withTitles: destinations.map { String(localized: $0.label) })
            if let index = destinations.firstIndex(of: settings.conversationDestination) { picker.selectItem(at: index) }
            alert.accessoryView = destinations.isEmpty ? nil : picker
            let openButton = alert.addButton(withTitle: String(localized: .AssistantContext.assistantContextChooseOpen))
            openButton.isEnabled = !destinations.isEmpty
            alert.addButton(withTitle: String(localized: .AssistantContext.assistantContextCancel))
            alert.addButton(withTitle: String(localized: .AssistantContext.assistantContextCopy))
            let response = await present(alert)
            if response == .alertFirstButtonReturn, destinations.indices.contains(picker.indexOfSelectedItem) {
                open(destinations[picker.indexOfSelectedItem])
            } else if response == .alertThirdButtonReturn {
                AssistantAutomationRunner.copyPrompt(context.prompt)
            }
        }
    }

    private func open(_ destination: AssistantContextLauncher.Destination) {
        isOpening = true
        Task {
            defer { isOpening = false }
            do {
                var message = ""
                if destination.isCLI {
                    guard let input = await terminalMessage() else { return }
                    message = input
                }
                try await AssistantContextLauncher.open(destination, context: context,
                    workspace: settings.automation.assistantWorkspace, message: message)
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: .AssistantContext.assistantContextFailed)
                alert.addButton(withTitle: String(localized: .AssistantContext.assistantContextOk))
                _ = await present(alert)
            }
        }
    }

    private func terminalMessage() async -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: .AssistantContext.assistantContextMessageTitle)
        alert.informativeText = String(localized: .AssistantContext.assistantContextMessageHelp)
            + "\n\n" + context.prompt
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 120)
        guard let input = scroll.documentView as? NSTextView else { return nil }
        input.isRichText = false
        input.font = .systemFont(ofSize: NSFont.systemFontSize)
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        scroll.documentView = input
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = input
        alert.addButton(withTitle: String(localized: .AssistantContext.assistantContextChooseOpen))
        alert.addButton(withTitle: String(localized: .AssistantContext.assistantContextCancel))
        guard await present(alert) == .alertFirstButtonReturn,
              !input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return input.string
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        NSApp.activate()
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }
}

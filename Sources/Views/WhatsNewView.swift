import SwiftUI

struct WhatsNewView: View {
    let updates: UpdateService

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if updates.allowsWhatsNew {
            releaseNotes
        } else {
            Color.clear.task { dismissWindow(id: "whats-new") }
        }
    }

    private var releaseNotes: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let entry = updates.whatsNewEntry {
                        ExtraContextMarkdown(source: entry.body)
                    } else {
                        Text(.Menu.whatsNewEmpty)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }

            Divider()

            footer
        }
        .frame(minWidth: 520, minHeight: 420)
        .onDisappear {
            if updates.whatsNewEntry != nil { updates.acknowledgeCurrentVersion() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.Menu.whatsNewTitle)
                .font(.title2.weight(.semibold))
            Text(.Menu.whatsNewVersion(updates.currentVersion))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                dismissWindow(id: "whats-new")
            } label: {
                Text(.Menu.whatsNewDismiss)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

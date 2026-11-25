import MergeTetherRemote
import SwiftUI

struct MREventLogGitLabRow: View {
    let event: MRGitLabActivity
    let appEvent: MRAutomationEvent?
    let mergeRequestURL: URL
    let openDiscussion: ((Int, String?) -> Bool)?
    @Environment(\.openURL) private var openURL
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let body = event.body, !body.isEmpty {
                    Text(SafeInlineMarkdown.render(body) ?? AttributedString(body))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Text(event.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    .foregroundStyle(.secondary)
                if let noteID = event.noteID, let url = noteURL(noteID) {
                    if case .comment = event.kind, let openDiscussion {
                        Button {
                            if !openDiscussion(noteID, event.discussionID) { openURL(url) }
                        } label: { Text(.AutomationHistory.automationHistoryOpenDiscussion) }
                        .buttonStyle(.link)
                    }
                    Link(destination: url) { Text(.CommandCenter.commandCenterOpenGitLab) }
                }
            }
            .font(.caption)
            .padding(.vertical, 5)
        } label: {
            MREventLogRowHeader(title: title, context: context, createdAt: event.createdAt,
                source: appEvent == nil ? .gitLab : .mergeTether, isAutomatic: appEvent?.origin == .automatic)
        }
        .padding(.vertical, 3)
    }

    private var title: Text {
        if let headline = event.systemHeadline { Text(verbatim: headline) }
        else { Text(event.title) }
    }

    private var context: Text? {
        let parts: [String?]
        switch event.kind {
        case .comment: parts = [event.actor, event.summary]
        case .systemNote where event.systemHeadline != nil: parts = []
        default: parts = [event.actor]
        }
        let context = parts.compactMap { $0 }.joined(separator: " · ")
        return context.isEmpty ? nil : Text(verbatim: context)
    }

    private func noteURL(_ id: Int) -> URL? {
        var components = URLComponents(url: mergeRequestURL, resolvingAgainstBaseURL: false)
        components?.fragment = "note_\(id)"
        return components?.url
    }
}

struct MREventLogRowHeader: View {
    enum Source { case gitLab, mergeTether }
    let title: Text
    let context: Text?
    let createdAt: Date
    let source: Source
    let isAutomatic: Bool

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                title.fontWeight(.medium).lineLimit(1)
                    .layoutPriority(1)
                if let context {
                    context.foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            badge(source == .gitLab ? .AutomationHistory.automationHistorySourceGitLab
                : .AutomationHistory.automationHistorySourceMergeTether, color: source == .gitLab ? .secondary : .blue)
            if isAutomatic {
                badge(.AutomationHistory.automationHistoryAutomated, color: .purple)
            }
            Text(createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .foregroundStyle(.secondary).monospacedDigit().fixedSize()
                .help(Text(createdAt, format: .dateTime.year().month().day().hour().minute().second()))
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func badge(_ title: LocalizedStringResource, color: Color) -> some View {
        Text(title).font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

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
                if let publication = appEvent?.publication, let original = publication.body,
                   original != event.body.map(GlabService.redactWorkflowEvidence) {
                    MREventLogPublishedText(publication: publication)
                }
                if let location = event.location ?? appEvent?.publication?.location {
                    Text(verbatim: location).monospaced().textSelection(.enabled)
                }
                Text(event.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    .foregroundStyle(.secondary)
                if let updatedAt = event.updatedAt {
                    HStack {
                        Text(.AutomationHistory.automationHistoryUpdatedAt)
                        Text(updatedAt, format: .dateTime.year().month().day().hour().minute().second())
                    }
                    .foregroundStyle(.secondary)
                }
                if let appEvent {
                    Text(appEvent.origin == .automatic ? .AutomationHistory.automationHistoryOriginAutomatic
                        : .AutomationHistory.automationHistoryOriginManual)
                        .foregroundStyle(.secondary)
                }
                if let noteID = event.noteID, let url = mergeRequestURL.gitLabNoteURL(noteID) {
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
                source: appEvent == nil ? .gitLab : .mergeTether, isAutomatic: appEvent?.origin == .automatic,
                person: event.person, personFirst: event.systemHeadline != nil)
        }
        .environment(\.gitLabPersonSourceURL, mergeRequestURL)
        .padding(.vertical, 3)
    }

    private var title: Text {
        if let appEvent, appEvent.publicationBasedOnAuthorTrust == true { Text(appEvent.title) }
        else if case .systemNote = event.kind, let summary = event.summary { Text(verbatim: summary) }
        else { Text(event.title) }
    }

    private var context: Text? {
        guard case .comment = event.kind, let summary = event.summary else { return nil }
        return Text(verbatim: summary)
    }
}

struct MREventLogPublishedText: View {
    let publication: MRAutomationEvent.Publication

    var body: some View {
        if let body = publication.body, !body.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(.AutomationHistory.automationHistoryPublishedText).fontWeight(.medium)
                Text(SafeInlineMarkdown.render(body) ?? AttributedString(body))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if publication.bodyTruncated == true {
                    Text(.AutomationHistory.automationHistoryPublishedTextTruncated).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct MREventLogRowHeader: View {
    enum Source { case gitLab, mergeTether }
    let title: Text
    let context: Text?
    let createdAt: Date
    let source: Source
    let isAutomatic: Bool
    var person: PersonIdentity? = nil
    var personFirst = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                if personFirst { personLabel }
                title.fontWeight(.medium).lineLimit(1)
                    .layoutPriority(personFirst ? 0 : 1)
                if !personFirst { personLabel }
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
        .accessibilityElement(children: person == nil ? .combine : .contain)
    }

    @ViewBuilder private var personLabel: some View {
        if let person {
            PersonLabel(person: person, showsAvatar: false, showsHandleWhenUnnamed: true)
                .layoutPriority(1)
        }
    }

    private func badge(_ title: LocalizedStringResource, color: Color) -> some View {
        Text(title).font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

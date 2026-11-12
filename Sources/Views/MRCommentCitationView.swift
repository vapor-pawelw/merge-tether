import SwiftUI

struct MRCommentCitationView: View {
    let authorName: String?
    let authorUsername: String?
    let authorID: Int
    let quote: String
    let url: URL?
    let relation: LocalizedStringResource
    @State private var isExpanded = false

    init(citation: MRCommentCitation, relation: LocalizedStringResource) {
        authorName = citation.note.author?.name
        authorUsername = citation.note.author?.username
        authorID = citation.note.author?.id ?? 0
        quote = citation.note.body ?? ""
        url = citation.url
        self.relation = relation
    }

    init(decision: IgnoredFeedbackSuggestion, mergeRequestURL: URL) {
        authorName = decision.sourceAuthorName
        authorUsername = decision.sourceAuthorUsername
        authorID = decision.sourceAuthorID
        quote = decision.sourceBody
        relation = .FeedbackSuggestions.feedbackSuggestionsSourceSaved
        var components = URLComponents(url: mergeRequestURL, resolvingAgainstBaseURL: false)
        components?.fragment = "note_\(decision.sourceNoteID)"
        url = decision.sourceNoteID > 0 && mergeRequestURL.isGitLabMergeRequest(
            host: decision.target.host, iid: decision.target.iid ?? 0) ? components?.url : nil
    }

    private var author: String {
        let name = authorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let username = authorUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty && !username.isEmpty && name != username { return "\(name) (@\(username))" }
        if !username.isEmpty { return "@\(username)" }
        if !name.isEmpty { return name }
        return String(localized: .FeedbackSuggestions.feedbackSuggestionsAuthorIdentifier(authorID))
    }

    /// Short comments need no expand control.
    private var isLong: Bool { quote.count > 220 || quote.filter(\.isNewline).count > 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // The relation stays available as help and to VoiceOver instead of as a separate heading.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "text.bubble").foregroundStyle(.secondary).imageScale(.small)
                Text(verbatim: author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let url {
                    Link(destination: url) { Text(.FeedbackSuggestions.feedbackSuggestionsOpenComment) }
                        .font(.caption)
                }
            }
            .help(Text(relation))
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text(relation))
            Text(verbatim: quote).font(.callout).foregroundStyle(.primary.opacity(0.85)).textSelection(.enabled)
                .lineLimit(isExpanded || !isLong ? nil : 2).fixedSize(horizontal: false, vertical: true)
            if isLong || isExpanded {
                Button { isExpanded.toggle() } label: {
                    Text(isExpanded ? .FeedbackSuggestions.feedbackSuggestionsCollapseComment
                        : .FeedbackSuggestions.feedbackSuggestionsExpandComment)
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                .accessibilityValue(Text(isExpanded ? .FeedbackSuggestions.feedbackSuggestionsCommentExpanded
                    : .FeedbackSuggestions.feedbackSuggestionsCommentCollapsed))
            }
        }
        .padding(.leading, 10).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2) }
        .onChange(of: quote) { _, _ in isExpanded = false }
        .onChange(of: url) { _, _ in isExpanded = false }
    }
}

struct IgnoredFeedbackSuggestionsView: View {
    let entries: [IgnoredFeedbackSuggestion]
    let mergeRequestURL: URL
    let isUpdating: Bool
    let onRestore: (IgnoredFeedbackSuggestion) -> Void
    let onReset: () -> Void

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(.FeedbackSuggestions.feedbackSuggestionsIgnored).font(.subheadline.weight(.semibold))
                ForEach(entries) { decision in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Text(verbatim: decision.concernSummary).textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button { onRestore(decision) } label: { Text(.FeedbackSuggestions.feedbackSuggestionsRestore) }
                                .disabled(isUpdating)
                        }
                        if decision.concernReason != decision.concernSummary {
                            AgentDiagnosticDetails(reason: decision.concernReason)
                        }
                        MRCommentCitationView(decision: decision, mergeRequestURL: mergeRequestURL)
                    }
                }
                Button(role: .destructive, action: onReset) { Text(.FeedbackSuggestions.feedbackSuggestionsReset) }
                    .disabled(isUpdating)
            }
            .font(.subheadline).padding(.top, 12)
        }
    }
}

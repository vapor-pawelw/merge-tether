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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(relation).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: author).font(.caption.weight(.medium))
                Spacer(minLength: 8)
                if let url {
                    Link(destination: url) { Text(.FeedbackSuggestions.feedbackSuggestionsOpenComment) }
                        .font(.caption)
                }
            }
            Text(verbatim: quote).textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 4).fixedSize(horizontal: false, vertical: true)
            Button { isExpanded.toggle() } label: {
                Text(isExpanded ? .FeedbackSuggestions.feedbackSuggestionsCollapseComment
                    : .FeedbackSuggestions.feedbackSuggestionsExpandComment)
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            .accessibilityValue(Text(isExpanded ? .FeedbackSuggestions.feedbackSuggestionsCommentExpanded
                : .FeedbackSuggestions.feedbackSuggestionsCommentCollapsed))
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
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

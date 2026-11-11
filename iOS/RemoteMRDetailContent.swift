import SwiftUI
import MergeTetherRemote

struct RemoteMRDetailContent: View {
    let details: RemoteMRDetails
    let card: RemoteCard
    @State private var showingApprovals = false
    @State private var descriptionExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            section(.RemoteDetail.remoteDetailOverview) {
                ForEach(Array(details.metadata.enumerated()), id: \.offset) { _, field in
                    fieldView(field)
                }
                if let description = details.description, !description.isEmpty {
                    Divider()
                    Text(.RemoteDetail.remoteDetailDescription).font(.subheadline.weight(.medium))
                    Text(verbatim: description).font(.callout).lineSpacing(3).textSelection(.enabled)
                        .lineLimit(descriptionExpanded ? nil : 6)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { descriptionExpanded.toggle() } label: {
                        Text(descriptionExpanded ? .RemoteDetail.remoteDetailShowLess : .RemoteDetail.remoteDetailShowMore)
                            .frame(minHeight: 44)
                    }.font(.callout)
                }
                if !details.reasons.isEmpty {
                    Divider()
                    ForEach(Array(details.reasons.enumerated()), id: \.offset) { _, reason in
                        Label { Text(verbatim: reason) } icon: { Image(systemName: "info.circle") }
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            section(.RemoteDetail.remoteDetailApprovals) {
                if let approvals = details.approvals {
                    RemoteApprovalSummary(details: approvals)
                    Button { showingApprovals = true } label: {
                        Label(.RemoteDetail.remoteDetailPeopleAndRules, systemImage: "person.2")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("remote.details.approvals")
                } else { unavailable }
            }
            .id(RemoteDetailAnchor.approvals)
            if let dependencies = card.dependencies {
                section(.RemoteDetail.remoteDetailDependencies) {
                    if let position = dependencies.stackPosition { Text(.MRDependencies.mrDependenciesStackPosition(position)).font(.callout) }
                    ForEach(Array(dependencies.predecessors.enumerated()), id: \.offset) { _, predecessor in
                        VStack(alignment: .leading, spacing: 5) {
                            if ["https", "http"].contains(predecessor.url.scheme?.lowercased() ?? ""), predecessor.url.host == card.url?.host {
                                Link(destination: predecessor.url) {
                                    Text(verbatim: predecessor.reference + " · " + predecessor.title)
                                        .frame(minHeight: 44, alignment: .leading)
                                }.font(.callout)
                            } else { Text(verbatim: predecessor.reference + " · " + predecessor.title).font(.callout) }
                            if !predecessor.isCurrent {
                                Text(.MRDependencies.mrDependenciesLastKnown).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let notice = dependencies.notice { Text(verbatim: notice).font(.callout).foregroundStyle(.secondary) }
                }
            }
            if !details.policy.isEmpty {
                section(.RemoteDetail.remoteDetailPolicy) {
                    ForEach(Array(details.policy.enumerated()), id: \.offset) { _, message in
                        Text(verbatim: message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            section(.RemoteDetail.remoteDetailFeedback) {
                if details.feedback.isEmpty {
                    Text(.RemoteDetail.remoteDetailNoFeedback).font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(details.feedback.enumerated()), id: \.offset) { _, field in fieldView(field) }
                }
            }
            .id(RemoteCardCTA.Destination.feedback)
            section(.RemoteDetail.remoteDetailDiscussions) {
                if let threads = details.threads {
                    if threads.isEmpty {
                        Text(details.truncated ? .RemoteDetail.remoteDetailTruncated : .RemoteDetail.remoteDetailNoDiscussions)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(threads) { thread in
                        RemoteDiscussionCard(thread: thread, mergeRequestURL: card.url)
                    }
                } else { unavailable }
            }
            .id(RemoteDetailAnchor.discussions)
            section(.RemoteDetail.remoteDetailActivity) {
                Text(.RemoteDetail.remoteDetailHistoryHelp).font(.caption).foregroundStyle(.secondary)
                if details.activity.isEmpty { Text(.RemoteDetail.remoteDetailNoActivity).font(.callout).foregroundStyle(.secondary) }
                ForEach(details.activity) { activity in
                    DisclosureGroup {
                        if let summary = activity.summary {
                            Text(verbatim: summary).font(.callout).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                        }
                        if let head = activity.head {
                            Text(.RemoteSecurity.remoteSecurityCommit).font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: head).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: activity.title).font(.subheadline.weight(.medium))
                            Text(verbatim: activity.status).font(.callout).foregroundStyle(.secondary)
                            Text(activity.createdAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: 44, alignment: .leading)
                    }
                    Divider()
                }
            }
            .id(RemoteCardCTA.Destination.assistantRuns)
            section(.RemoteDetail.remoteDetailUsage) {
                if let usage = details.usage {
                    ForEach(Array(usage.enumerated()), id: \.offset) { _, field in fieldView(field) }
                } else { unavailable }
            }
        }
        .sheet(isPresented: $showingApprovals) {
            RemoteApprovalDetailsView(details: details.approvals ?? .init(progress: nil), mergeRequestURL: card.url)
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private func fieldView(_ field: RemoteDetailField) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let url = safeLink(field.url, to: card.url) {
                Link(destination: url) { Label { Text(verbatim: field.label) } icon: { Image(systemName: "arrow.up.right.square") } }
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44, alignment: .leading)
            } else { Text(verbatim: field.label).font(.subheadline.weight(.medium)).foregroundStyle(.secondary) }
            Text(verbatim: field.value).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var unavailable: some View { Text(.RemoteDetail.remoteDetailUnavailable).font(.callout).foregroundStyle(.secondary) }
    private func section<Content: View>(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

enum RemoteDetailAnchor: Hashable { case approvals, discussions }

private struct RemoteDiscussionCard: View {
    let thread: RemoteDetailThread
    let mergeRequestURL: URL?
    @State private var expanded = false
    private var color: Color {
        switch thread.state { case .open: .orange; case .resolved: .green; case .general: .secondary }
    }
    private var state: LocalizedStringResource {
        switch thread.state {
        case .open: .RemoteDetail.remoteDetailThreadOpen
        case .resolved: .RemoteDetail.remoteDetailThreadResolved
        case .general: .RemoteDetail.remoteDetailThreadGeneral
        }
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 18) {
                if thread.truncated { Text(.RemoteDetail.remoteDetailTruncated).font(.caption).foregroundStyle(.orange) }
                ForEach(Array(thread.notes.enumerated()), id: \.offset) { index, note in
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            if index > 0 {
                                noteAuthor(note)
                            }
                            if let origin = note.origin, index > 0 || origin != thread.origin { originBadge(origin) }
                            if index > 0, let date = note.createdAt {
                                Text(date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let location = note.location, location != thread.location { RemoteFullContextLabel(full: location) }
                        Text(verbatim: note.body).font(.callout).lineSpacing(3).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = safeLink(note.url, to: mergeRequestURL) {
                            Link(destination: url) { Label(.RemoteDetail.remoteDetailOpenComment, systemImage: "arrow.up.right.square") }
                                .font(.caption).frame(minHeight: 44)
                        }
                    }
                    if note.id != thread.notes.last?.id { Divider() }
                }
            }.padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                StatusFlowLayout {
                    Label(state, systemImage: thread.state == .resolved ? "checkmark.bubble" : "bubble.left")
                        .font(.caption.weight(.medium)).foregroundStyle(color)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(color.opacity(0.07), in: Capsule())
                    feedbackBadge
                    Text(replyTitle).font(.caption)
                        .foregroundStyle(thread.reply == .published || thread.reply == .earlier ? Color.blue : Color.secondary)
                    if thread.draftCount > 0 {
                        HStack(spacing: 5) {
                            Label(.RemoteDetail.remoteDetailDraft, systemImage: "square.and.pencil")
                            Text(thread.draftCount, format: .number)
                        }.font(.caption).foregroundStyle(.tint)
                    }
                    if let origin = thread.origin { originBadge(origin) }
                }
                StatusFlowLayout {
                    if let location = thread.location { RemoteFullContextLabel(full: location) }
                    if let date = thread.notes.first?.createdAt {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let first = thread.notes.first {
                    noteAuthor(first)
                    if !expanded { Text(verbatim: first.body).font(.callout).lineLimit(3).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .tint(.secondary)
        .padding(12)
        .background(color.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.12), lineWidth: 0.5) }
    }
    private func noteAuthor(_ note: RemoteDetailNote) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: note.author ?? note.username ?? String(localized: .RemoteDetail.remoteDetailUnknownAuthor))
                .font(.callout.weight(.medium))
            if let username = note.username, username != note.author {
                Text(verbatim: "@" + username).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var feedbackBadge: some View {
        let feedback = thread.feedback ?? .needsVerification
        let title: LocalizedStringResource = switch feedback {
        case .addressed: .RemoteDetail.remoteDetailFeedbackAddressed
        case .pending: .RemoteDetail.remoteDetailFeedbackPending
        case .needsVerification: .RemoteDetail.remoteDetailFeedbackNeedsVerification
        case .informational: .RemoteDetail.remoteDetailFeedbackInformational
        case .ignored: .RemoteDetail.remoteDetailFeedbackIgnored
        case .partlyIgnored: .RemoteDetail.remoteDetailFeedbackPartlyIgnored
        case .notApplicable: .RemoteDetail.remoteDetailFeedbackNotApplicable
        }
        let color: Color = switch feedback {
        case .addressed: .green
        case .pending, .needsVerification: .orange
        case .informational, .ignored, .partlyIgnored, .notApplicable: .secondary
        }
        let symbol: String = switch feedback {
        case .addressed: "checkmark.seal"
        case .pending: "exclamationmark.bubble"
        case .needsVerification: "questionmark.circle"
        case .informational, .notApplicable: "info.circle"
        case .ignored, .partlyIgnored: "minus.circle"
        }
        return Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.08), in: Capsule())
            .accessibilityHint(Text(.RemoteDetail.remoteDetailFeedbackHelp))
    }
    private var replyTitle: LocalizedStringResource {
        switch thread.reply {
        case .none: .RemoteDetail.remoteDetailReplyNone
        case .published: .RemoteDetail.remoteDetailReplyPublished
        case .earlier: .RemoteDetail.remoteDetailReplyEarlier
        case .unknown, .unavailable: .RemoteDetail.remoteDetailReplyUnknown
        }
    }
    private func originBadge(_ origin: RemoteDetailNote.Origin) -> some View {
        let title: LocalizedStringResource = switch origin {
        case .ai: .RemoteDetail.remoteDetailOriginAI
        case .uncertain: .RemoteDetail.remoteDetailOriginUncertain
        case .human: .RemoteDetail.remoteDetailOriginHuman
        }
        let color: Color = switch origin { case .ai: .purple; case .uncertain: .orange; case .human: .teal }
        return Label(title, systemImage: origin == .ai ? "sparkles" : origin == .human ? "person" : "questionmark.circle")
            .font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.08), in: Capsule())
    }
}

private struct RemoteFullContextLabel: View {
    let full: String
    var body: some View {
        Text(verbatim: full).font(.caption.monospaced()).foregroundStyle(.secondary)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}

private func safeLink(_ url: URL?, to mergeRequest: URL?) -> URL? {
    guard let url, let mergeRequest, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
          url.host == mergeRequest.host, url.path == mergeRequest.path else { return nil }
    return url
}

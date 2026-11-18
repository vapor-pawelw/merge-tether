import SwiftUI
import MergeTetherRemote

struct RemoteApprovalDetailsView: View {
    let details: RemoteApprovalDetails
    let mergeRequestURL: URL?
    let approvedWithOpenFindings: Bool
    @Environment(\.dismiss) private var dismiss
    init(details: RemoteApprovalDetails, mergeRequestURL: URL? = nil, approvedWithOpenFindings: Bool = false) {
        self.details = details; self.mergeRequestURL = mergeRequestURL
        self.approvedWithOpenFindings = approvedWithOpenFindings
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        RemoteApprovalSummary(details: details)
                        if approvedWithOpenFindings { RemoteOpenFindingsApprovalNote() }
                    }
                    if details.truncated { Text(.RemoteDetail.remoteDetailTruncated).font(.callout).foregroundStyle(.orange) }
                    VStack(alignment: .leading, spacing: 14) {
                        Text(.RemoteDetail.remoteDetailPeople).font(.headline).accessibilityAddTraits(.isHeader)
                        if details.progress == nil { unavailable }
                        if !details.historyAvailable {
                            Text(.RemoteDetail.remoteDetailReviewHistoryUnavailable).font(.callout).foregroundStyle(.secondary)
                        }
                        if details.people.isEmpty, !details.truncated {
                            Text(.Board.boardApprovalsNoPeople).font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(details.orderedPeople) { person in
                            RemoteApprovalPersonRow(person: person, isViewer: person.id == details.viewerApproval?.id)
                            Divider()
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text(.RemoteDetail.remoteDetailRules).font(.headline).accessibilityAddTraits(.isHeader)
                        if let rules = details.rules {
                            if rules.isEmpty, !details.truncated { Text(.RemoteDetail.remoteDetailNoRules).font(.callout).foregroundStyle(.secondary) }
                            ForEach(rules) { rule in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(verbatim: rule.name).font(.body.weight(.medium))
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(.RemoteDetail.remoteDetailRequired)
                                        Text(rule.required, format: .number).monospacedDigit()
                                    }.font(.callout).foregroundStyle(.secondary)
                                    if rule.required == 0 { Text(.RemoteDetail.remoteDetailOptional).foregroundStyle(.secondary) }
                                    else if let approved = rule.approved {
                                        Label(approved ? .RemoteDetail.remoteDetailSatisfied : .RemoteDetail.remoteDetailNotSatisfied,
                                            systemImage: approved ? "checkmark.circle" : "exclamationmark.circle")
                                            .foregroundStyle(approved ? Color.green : .orange)
                                    } else { unavailable }
                                    if !rule.approvedBy.isEmpty {
                                        Text(verbatim: rule.approvedBy.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                        } else { unavailable }
                    }
                }
                .frame(maxWidth: 640).frame(maxWidth: .infinity).padding(20)
            }
            .navigationTitle(Text(.RemoteDetail.remoteDetailApprovals)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let url = mergeRequestURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .accessibilityLabel(Text(.Remote.remoteOpen))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button(.Remote.remoteClose) { dismiss() } }
            }
        }
    }
    private var unavailable: some View { Text(.RemoteDetail.remoteDetailUnavailable).font(.callout).foregroundStyle(.secondary) }
}

struct RemoteOpenFindingsApprovalNote: View {
    var body: some View {
        Text(.RemoteDetail.remoteDetailApprovedWithOpenFindings)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct RemoteApprovalSummary: View {
    let details: RemoteApprovalDetails
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let viewer = details.viewerApproval {
                Label(viewer.status == .approved ? .Board.boardApprovalsViewerApproved : .Board.boardApprovalsViewerNoLongerCounts,
                    systemImage: viewer.status == .approved ? "checkmark.circle.fill" : "arrow.counterclockwise.circle.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(viewer.status == .approved ? Color.green : .orange)
            }
            if let progress = details.progress {
                let received = progress.received ?? progress.completed
                Text(progress.required == 0 ? .Board.boardApprovalsReceived(received) : .Board.boardApprovalsHelp(received, progress.required))
                    .font(.callout)
            } else { Text(.Board.boardApprovalsUnavailable).font(.callout).foregroundStyle(.secondary) }
            if let satisfied = details.requirementsSatisfied {
                Label(satisfied ? .RemoteDetail.remoteDetailSatisfied : .RemoteDetail.remoteDetailNotSatisfied,
                    systemImage: satisfied ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.callout.weight(.medium)).foregroundStyle(satisfied ? Color.green : .orange)
            } else {
                Text(.RemoteDetail.remoteDetailRequirementsUnknown).font(.callout).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct RemoteApprovalPersonRow: View {
    let person: RemoteApprovalPerson
    var isViewer = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PersonLabel(person: .init(name: person.name, username: person.username, avatarURL: person.avatarURL), avatarSize: 24)
                    .font(.body.weight(.medium))
                if isViewer { Text(.Board.boardApprovalsViewerSuffix).font(.callout).foregroundStyle(.secondary) }
            }
            Label(person.status.title, systemImage: person.status.symbol)
                .font(.callout).foregroundStyle(person.status == .approved ? Color.green : isViewer && person.status == .previouslyApproved ? .orange : .secondary)
            if let changedAt = person.changedAt {
                Text(changedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

extension RemoteApprovalPerson.Status {
    var title: LocalizedStringResource {
        switch self {
        case .approved: .Board.boardApprovalsApproved
        case .previouslyApproved: .Board.boardApprovalsPreviouslyApproved
        case .commented: .Board.boardApprovalsCommented
        case .assigned: .RemoteDetail.remoteDetailAssigned
        }
    }
    var symbol: String {
        switch self {
        case .approved: "checkmark.seal.fill"
        case .previouslyApproved: "checkmark.seal"
        case .commented: "bubble.left"
        case .assigned: "person"
        }
    }
}

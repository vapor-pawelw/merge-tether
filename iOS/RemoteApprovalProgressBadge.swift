import SwiftUI
import MergeTetherRemote

struct RemoteApprovalProgressBadge: View {
    let progress: RemoteApprovalProgress?
    var people: [RemoteApprovalPerson]? = nil
    var viewerApprovalID: Int? = nil
    var assignedReviewerCount: Int? = nil
    var approvedWithOpenFindings = false
    @State private var showingPeople = false

    private var details: RemoteApprovalDetails {
        .init(progress: progress, people: people ?? [], viewerApprovalID: viewerApprovalID)
    }
    private var viewer: RemoteApprovalPerson? { details.viewerApproval }
    private var received: Int { progress?.received ?? progress?.completed ?? 0 }
    private var complete: Bool {
        progress.map { received > 0 && ($0.requirementsSatisfied ?? ($0.required == 0 || received >= $0.required)) } ?? false
    }
    private var approvalColor: ApprovalBadgeColor {
        .init(received: received, required: progress?.required, isSatisfied: complete)
    }
    private var requiredApprovalPending: Bool {
        guard let progress, progress.required > 0 else { return false }
        return !(progress.requirementsSatisfied ?? (received >= progress.required))
    }
    private var explanation: Text {
        let count = if let progress, progress.required == 0 { Text(.Board.boardApprovalsReceived(received)) }
            else if let progress { Text(.Board.boardApprovalsHelp(received, progress.required)) }
            else { Text(.Board.boardApprovalsUnavailable) }
        let reviewerDetails = assignedReviewerCount.map {
            count + Text(verbatim: " · ") + Text(.Board.boardApprovalsAssignedReviewers($0))
        } ?? count
        let status = requiredApprovalPending
            ? reviewerDetails + Text(verbatim: " · ") + Text(.Board.boardApprovalsRequiredPending)
            : reviewerDetails
        if let viewer {
            return Text(viewer.status == .approved ? .Board.boardApprovalsViewerApproved : .Board.boardApprovalsViewerNoLongerCounts)
                + Text(verbatim: " · ") + status
        }
        return status
    }

    var body: some View {
        if progress.map({ $0.required > 0 || received > 0 }) ?? true || viewer != nil || assignedReviewerCount != nil {
            Button { showingPeople = true } label: {
                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        Image(systemName: complete ? "checkmark.seal.fill" : "checkmark.seal")
                        if let progress, progress.required == 0 { Text(verbatim: "\(received)") }
                        else if let progress { Text(.Board.boardApprovalRatio(received, progress.required)) }
                        else { Text(.Board.boardApprovalsUnknownRatio) }
                        if let assignedReviewerCount {
                            Text(.Board.boardApprovalsReviewerCountBadge(assignedReviewerCount))
                        }
                    }
                    .font(.caption2).monospacedDigit().foregroundStyle(approvalColor)
                    if let viewer {
                        Divider().frame(height: 10)
                        PersonAvatar(url: viewer.avatarURL, size: 16)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: viewer.status == .approved ? "checkmark.circle.fill" : "arrow.counterclockwise.circle.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white, viewer.status == .approved ? Color.green : .orange)
                                    .background(Circle().fill(.background).padding(-1))
                                    .offset(x: 3, y: 2)
                            }
                            .padding(.trailing, 2)
                    }
                }
                .fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(.interaction, CardControlHitArea(anchor: .top))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(explanation)
            .accessibilityIdentifier("remote.approvals.badge")
            .popover(isPresented: $showingPeople) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(.RemoteDetail.remoteDetailPeople).font(.headline)
                        if approvedWithOpenFindings { RemoteOpenFindingsApprovalNote() }
                        if progress == nil || people == nil {
                            Text(.Board.boardApprovalsUnavailable).font(.callout).foregroundStyle(.secondary)
                        }
                        if people?.isEmpty == true, progress != nil {
                            Text(.Board.boardApprovalsNoPeople).font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(details.orderedPeople) { person in
                            RemoteApprovalPersonRow(person: person, isViewer: person.id == viewer?.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .frame(width: 300, height: min(380, CGFloat(max(people?.count ?? 0, 1)) * 80 + (approvedWithOpenFindings ? 120 : 60)))
                .presentationCompactAdaptation(.popover)
                .accessibilityIdentifier("remote.approvals.people")
            }
        }
    }
}

struct CardControlHitArea: Shape {
    var anchor: UnitPoint = .center

    func path(in rect: CGRect) -> Path {
        let height = max(44, rect.height)
        let top = rect.minY - (height - rect.height) * anchor.y
        return Rectangle().path(in: CGRect(x: rect.minX, y: top, width: rect.width, height: height))
    }
}

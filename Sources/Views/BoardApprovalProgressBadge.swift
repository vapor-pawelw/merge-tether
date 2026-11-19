import SwiftUI

struct BoardApprovalProgressBadge: View {
    let progress: MergeRequestApprovalProgress?
    var reviewers: [Todo.Author]? = nil
    /// Signed-in username; the viewer's own approval is shown only on MRs they review.
    var viewerUsername: String? = nil
    var isOwnMergeRequest = true
    var showsOpenFindingsApproval: () -> Bool = { false }
    @State private var showingPeople = false
    @State private var badgeHovered = false
    @State private var peopleHovered = false
    @State private var hoverTask: Task<Void, Never>?

    private var people: [MergeRequestApprovalProgress.Participant] {
        let reviewers = reviewers ?? []
        let all = progress?.participants(reviewers: reviewers) ?? MergeRequestApprovalProgress.participants(reviewers: reviewers)
        guard let viewer = viewerApproval?.author else { return all }
        return all.filter { $0.id == viewer.id } + all.filter { $0.id != viewer.id }
    }
    private var viewerApproval: MergeRequestApprovalProgress.ViewerApproval? {
        progress?.viewerApproval(username: viewerUsername, reviewers: reviewers ?? [], isOwnMergeRequest: isOwnMergeRequest)
    }
    private var assignedReviewerCount: Int? { MergeRequestApprovalProgress.assignedReviewerCount(reviewers) }
    private var satisfied: Bool {
        progress?.isSatisfied ?? false
    }
    var approvalColor: Color {
        if satisfied { return .green }
        guard let progress, progress.required > 0 else { return .secondary }
        let fraction = Double(progress.completed) / Double(progress.required)
        return .green.opacity(min(fraction * 0.8, 0.7))
    }
    private var requiredApprovalPending: Bool {
        guard let progress, progress.required > 0 else { return false }
        return !(progress.requirementsSatisfied ?? (progress.completed >= progress.required))
    }
    private var approvalCount: Text {
        if let progress, progress.required == 0 { Text(.Board.boardApprovalsReceived(progress.completed)) }
        else if let progress { Text(.Board.boardApprovalsHelp(progress.completed, progress.required)) }
        else { Text(.Board.boardApprovalsUnavailable) }
    }
    private var label: Text {
        let count = assignedReviewerCount.map {
            approvalCount + Text(verbatim: " · ") + Text(.Board.boardApprovalsAssignedReviewers($0))
        } ?? approvalCount
        let explanation = requiredApprovalPending
            ? count + Text(verbatim: " · ") + Text(.Board.boardApprovalsRequiredPending)
            : count
        switch viewerApproval {
        case .approved: return Text(.Board.boardApprovalsViewerApproved) + Text(verbatim: " · ") + explanation
        case .noLongerCounts: return Text(.Board.boardApprovalsViewerNoLongerCounts) + Text(verbatim: " · ") + explanation
        case nil: return explanation
        }
    }

    var body: some View {
        let assigned = assignedReviewerCount
        if progress.map({ $0.required > 0 || $0.completed > 0 }) ?? true || viewerApproval != nil || assigned != nil {
            Button { hoverTask?.cancel(); showingPeople = true } label: {
                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        Image(systemName: satisfied ? "checkmark.seal.fill" : "checkmark.seal").accessibilityHidden(true)
                        if let progress, progress.required == 0 {
                            Text(verbatim: "\(progress.completed)")
                        } else if let progress {
                            Text(.Board.boardApprovalRatio(progress.completed, progress.required))
                        } else { Text(.Board.boardApprovalsUnknownRatio) }
                        if let assigned { Text(.Board.boardApprovalsReviewerCountBadge(assigned)) }
                    }
                    .font(.caption2).monospacedDigit().foregroundStyle(approvalColor)
                    if let viewerApproval { viewerSegment(viewerApproval) }
                }
                .fixedSize()
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .help(label)
            .onHover { badgeHovered = $0; updateHover() }
            .popover(isPresented: $showingPeople, arrowEdge: .bottom) {
                approvalPopover.onHover { peopleHovered = $0; updateHover() }
            }
            .onChange(of: showingPeople) { _, visible in
                if !visible { hoverTask?.cancel(); peopleHovered = false }
            }
            .onDisappear { hoverTask?.cancel(); showingPeople = false }
        }
    }

    /// Your avatar with a corner glyph, after a divider, so it reads as part of the approvals badge.
    private func viewerSegment(_ approval: MergeRequestApprovalProgress.ViewerApproval) -> some View {
        HStack(spacing: 4) {
            Divider().frame(height: 10)
            AvatarView(url: approval.author.avatarURL, size: 14)
                .overlay(alignment: .bottomTrailing) {
                    Group {
                        switch approval {
                        case .approved:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
                        case .noLongerCounts:
                            Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(.white, .orange)
                        }
                    }
                    .font(.system(size: 8, weight: .bold))
                    .background(Circle().fill(.background).padding(-1))
                    .offset(x: 3, y: 3)
                }
                .padding(.trailing, 2)
        }
        .accessibilityHidden(true)
    }

    private var approvalPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsOpenFindingsApproval() {
                Text(.AutomationHistory.automationHistoryActionApproval)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                Divider()
            }
            peopleList
        }
        .frame(width: 280)
    }

    private var peopleList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if progress == nil {
                    Text(.Board.boardApprovalsUnavailable).font(.caption).foregroundStyle(.secondary).padding(12)
                }
                if people.isEmpty {
                    Text(.Board.boardApprovalsNoPeople).font(.callout).padding(12)
                }
                ForEach(people) { person in
                    HStack(spacing: 6) {
                        PersonLabel(person: person.author.person, avatarSize: 20)
                            .font(.callout).foregroundStyle(.primary)
                        if person.id == viewerApproval?.author.id {
                            Text(.Board.boardApprovalsViewerSuffix).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 18)
                        switch person.status {
                        case .approved:
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                .accessibilityLabel(Text(.Board.boardApprovalsApproved))
                                .help(Text(.Board.boardApprovalsApproved))
                        case .previouslyApproved:
                            Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                                .accessibilityLabel(Text(.Board.boardApprovalsPreviouslyApproved))
                                .help(Text(.Board.boardApprovalsPreviouslyApproved))
                        case .commented:
                            Image(systemName: "bubble.left").foregroundStyle(.secondary)
                                .accessibilityLabel(Text(.Board.boardApprovalsCommented))
                                .help(Text(.Board.boardApprovalsCommented))
                        case .assigned: EmptyView()
                        }
                    }
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(360, CGFloat(max(people.count, 1)) * 36 + (progress == nil ? 48 : 0)))
    }

    private func updateHover() {
        hoverTask?.cancel()
        let hovering = badgeHovered || peopleHovered
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(hovering ? 250 : 180))
            guard !Task.isCancelled else { return }
            showingPeople = hovering
        }
    }
}

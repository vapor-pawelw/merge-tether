import SwiftUI

struct BoardApprovalProgressBadge: View {
    let progress: MergeRequestApprovalProgress?
    var reviewers: [Todo.Author] = []
    @State private var showingPeople = false
    @State private var badgeHovered = false
    @State private var peopleHovered = false
    @State private var hoverTask: Task<Void, Never>?

    private var people: [MergeRequestApprovalProgress.Participant] {
        progress?.participants(reviewers: reviewers) ?? MergeRequestApprovalProgress.participants(reviewers: reviewers)
    }
    private var satisfied: Bool {
        progress?.isSatisfied ?? false
    }
    private var explanation: Text {
        if let progress, progress.required == 0 { Text(.Board.boardApprovalsReceived(progress.completed)) }
        else if let progress { Text(.Board.boardApprovalsHelp(progress.completed, progress.required)) }
        else { Text(.Board.boardApprovalsUnavailable) }
    }

    var body: some View {
        if progress.map({ $0.required > 0 || $0.completed > 0 }) ?? true {
            Button { hoverTask?.cancel(); showingPeople = true } label: {
                HStack(spacing: 3) {
                    Image(systemName: satisfied ? "checkmark.seal.fill" : "checkmark.seal").accessibilityHidden(true)
                    if let progress, progress.required == 0 {
                        Text(verbatim: "\(progress.completed)")
                    } else if let progress {
                        Text(.Board.boardApprovalRatio(progress.completed, progress.required))
                    } else { Text(.Board.boardApprovalsUnknownRatio) }
                }
                .font(.caption2).monospacedDigit().foregroundStyle(satisfied ? Color.green : .secondary)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.secondary.opacity(0.08), in: Capsule()).fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(explanation)
            .onHover { badgeHovered = $0; updateHover() }
            .popover(isPresented: $showingPeople, arrowEdge: .bottom) {
                peopleList.onHover { peopleHovered = $0; updateHover() }
            }
            .onChange(of: showingPeople) { _, visible in
                if !visible { hoverTask?.cancel(); peopleHovered = false }
            }
            .onDisappear { hoverTask?.cancel(); showingPeople = false }
        }
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
                        AvatarView(url: person.author.avatarURL, size: 20).accessibilityHidden(true)
                        Text(verbatim: person.author.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? person.author.username : person.author.name)
                            .font(.callout).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 18)
                        if person.approved {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                .accessibilityLabel(Text(.Board.boardApprovalsApproved))
                        }
                    }
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 280, height: min(360, CGFloat(max(people.count, 1)) * 36 + (progress == nil ? 48 : 0)))
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

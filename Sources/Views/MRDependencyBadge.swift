import SwiftUI
import MergeTetherRemote

struct MRDependencyBadge: View {
    let dependencies: RemoteMRDependencies
    @State private var isPresented = false
    #if os(macOS)
    @State private var pinned = false
    @State private var badgeHovered = false
    @State private var popoverHovered = false
    @State private var hoverTask: Task<Void, Never>?
    #endif

    var body: some View {
        if !dependencies.predecessors.isEmpty || dependencies.notice != nil {
            badge
                #if os(macOS)
                .onHover { badgeHovered = $0; updateHover() }
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    popover.onHover { popoverHovered = $0; updateHover() }
                }
                .onChange(of: isPresented) { _, visible in
                    if !visible { hoverTask?.cancel(); popoverHovered = false; pinned = false }
                }
                .onDisappear { hoverTask?.cancel(); isPresented = false }
                #else
                .popover(isPresented: $isPresented) {
                    popover.presentationCompactAdaptation(.popover)
                }
                #endif
        }
    }

    private var badge: some View {
        let blocked = dependencies.predecessors.contains(where: \.isCurrent)
        let tint: Color = blocked ? .red : .orange
        return Button {
            #if os(macOS)
            hoverTask?.cancel()
            pinned = true
            #endif
            isPresented = true
        } label: {
            Text(blocked ? .Board.boardCompactBlocked : .MRDependencies.mrDependenciesBadge)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(tint.opacity(0.12), in: Capsule())
                .fixedSize()
                #if os(iOS)
                .contentShape(.interaction, CardControlHitArea(anchor: .top))
                #endif
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mr.dependencies.badge")
    }

    private var popover: some View {
        ViewThatFits(in: .vertical) {
            dependencyList
            ScrollView { dependencyList }.scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 280)
        .frame(maxHeight: 340)
    }

    private var dependencyList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let position = dependencies.stackPosition {
                Text(.MRDependencies.mrDependenciesStackPosition(position))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(dependencies.predecessors, id: \.url) { predecessor in
                VStack(alignment: .leading, spacing: 3) {
                    Link(destination: predecessor.url) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(verbatim: "\(predecessor.reference) \(predecessor.title)")
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "arrow.up.right")
                                .font(.caption2).accessibilityHidden(true)
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                    Text(verbatim: description(of: predecessor))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let notice = dependencies.notice {
                Text(verbatim: notice).font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func description(of predecessor: RemoteMRPredecessor) -> String {
        var reasons: [LocalizedStringResource] = (predecessor.sources ?? []).map { source in
            switch source {
            case .stack: .MRDependencies.mrDependenciesEarlierInStack
            case .gitLab: .MRDependencies.mrDependenciesExplicitGitLab
            }
        }
        if reasons.isEmpty { reasons.append(.MRDependencies.mrDependenciesSourceUnavailable) }
        if !predecessor.isCurrent { reasons.append(.MRDependencies.mrDependenciesLastKnown) }
        return reasons.map { String(localized: $0) }.joined(separator: " · ")
    }

    #if os(macOS)
    private func updateHover() {
        hoverTask?.cancel()
        guard !pinned else { return }
        let hovering = badgeHovered || popoverHovered
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(hovering ? 250 : 180))
            guard !Task.isCancelled else { return }
            isPresented = hovering
        }
    }
    #endif
}

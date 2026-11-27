import SwiftUI

struct BoardAssigneesBadge: View {
    let assignees: [PersonIdentity]
    var contentOpacity = 1.0
    @State private var isPresented = false

    var body: some View {
        if !assignees.isEmpty {
            Button { isPresented.toggle() } label: {
                Label {
                    Text(assignees.count, format: .number).monospacedDigit()
                } icon: {
                    Image(systemName: "person.2")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(.secondary.opacity(0.08), in: Capsule())
                .opacity(contentOpacity)
                #if os(iOS)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                #endif
            }
            .buttonStyle(.plain)
            .fixedSize()
            #if os(macOS)
            .boardHeaderControlHover()
            #endif
            .accessibilityIdentifier("mr.assignees")
            .accessibilityLabel(Text(.Board.boardAssignees))
            .accessibilityValue(Text(assignees.count, format: .number))
            .help(Text(.Board.boardAssignees))
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                assigneeList
                    #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                    #endif
            }
            #if os(macOS)
            .preference(key: BoardDetailPopoverPresentedKey.self, value: isPresented)
            #endif
        }
    }

    private var assigneeList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(.Board.boardAssignees).font(.headline)
            ViewThatFits(in: .vertical) {
                people.fixedSize(horizontal: false, vertical: true)
                ScrollView { people }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 230, alignment: .leading)
        .padding(14)
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(assignees.enumerated()), id: \.offset) { _, person in
                HStack(spacing: 8) {
                    PersonAvatar(url: person.avatarURL, size: 24, initials: person.initials)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        if let name = person.displayName { Text(verbatim: name).font(.callout) }
                        if let handle = person.handle {
                            Text(verbatim: handle).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

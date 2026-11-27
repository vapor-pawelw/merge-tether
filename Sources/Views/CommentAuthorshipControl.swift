import MergeTetherRemote
import SwiftUI

struct CommentAuthorshipControl: View {
    let selection: RemoteDetailNote.Origin?
    var isManual = false
    var appGenerated = false
    var onSelect: ((RemoteDetailNote.Origin?) -> Void)?

    var body: some View {
        if appGenerated {
            Label(.CommentAuthorship.commentAuthorshipCreatedWithMergeTether, systemImage: "wand.and.stars")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.purple)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.purple.opacity(0.09), in: Capsule())
                .help(Text(.CommentAuthorship.commentAuthorshipMergeTetherHelp))
                .accessibilityHint(Text(.CommentAuthorship.commentAuthorshipMergeTetherHelp))
        } else {
            picker
        }
    }

    private var picker: some View {
        StatusFlowLayout(spacing: 8, centerRows: true) {
            Text(.CommentAuthorship.commentAuthorshipQuestion)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            HStack(spacing: 1) {
                segment(.ai, title: .CommentAuthorship.commentAuthorshipYes, emoji: "✅")
                segment(.human, title: .CommentAuthorship.commentAuthorshipNo, emoji: "❌")
                segment(.uncertain, title: .CommentAuthorship.commentAuthorshipUncertain)
            }
            .padding(2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .fixedSize(horizontal: true, vertical: false)
            .disabled(onSelect == nil)
            if let onSelect, isManual {
                Button { onSelect(nil) } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: controlHeight, minHeight: controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(.CommentAuthorship.commentAuthorshipAutomatic))
                .accessibilityLabel(Text(.CommentAuthorship.commentAuthorshipAutomatic))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(.CommentAuthorship.commentAuthorshipQuestion))
    }

    private var controlHeight: CGFloat {
        #if os(macOS)
        23
        #else
        44
        #endif
    }

    private func segment(_ choice: RemoteDetailNote.Origin, title: LocalizedStringResource, emoji: String? = nil) -> some View {
        let selected = selection == choice
        return Button { onSelect?(choice) } label: {
            HStack(spacing: 4) {
                if let emoji {
                    Text(verbatim: emoji)
                        .opacity(selected ? 1 : 0.4)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .font(.caption.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .frame(minWidth: controlHeight, minHeight: controlHeight)
            .background(Color.primary.opacity(selected ? 0.15 : 0), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ThreadPublicationMenu: View {
    typealias Preference = RemoteCardAutomation.Preference
    let preference: Preference
    var onSelect: ((Preference) -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Menu {
            ForEach(Preference.allCases, id: \.self) { choice in
                Button {
                    if choice != preference { onSelect?(choice) }
                } label: {
                    if choice == preference { Label(title(for: choice), systemImage: "checkmark") }
                    else { Text(title(for: choice)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "paperplane")
                } else {
                    Text(.CommentAuthorship.commentAuthorshipThreadPublication)
                    Text(verbatim: "·")
                }
                Text(title(for: preference))
                    .fontWeight(.medium)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
            .contentShape(Capsule())
        }
        #if os(macOS)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        #endif
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(onSelect == nil)
        .help(Text(.CommentAuthorship.commentAuthorshipThreadPublicationHelp))
        .accessibilityLabel(Text(.CommentAuthorship.commentAuthorshipThreadPublication))
        .accessibilityValue(Text(title(for: preference)))
        .accessibilityHint(Text(.CommentAuthorship.commentAuthorshipThreadPublicationHelp))
    }

    private func title(for preference: Preference) -> LocalizedStringResource {
        switch preference {
        case .default: .CommentAuthorship.commentAuthorshipThreadDefault
        case .on: .CommentAuthorship.commentAuthorshipThreadOn
        case .off: .CommentAuthorship.commentAuthorshipThreadOff
        }
    }
}

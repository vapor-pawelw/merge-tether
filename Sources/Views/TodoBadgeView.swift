import SwiftUI

struct TodoBadgeView: View {
    let todo: Todo

    var body: some View {
        let state = todo.targetState
        let identifier = todo.relativeIdentifier
        let tint: Color = state == .open ? .secondary : state.tint

        HStack(spacing: 4) {
            if !identifier.isEmpty {
                Text(identifier)
                    .font(.caption2.monospaced().weight(.semibold))
            }
            if let label = state.label, !(state == .draft && todo.targetType == .mergeRequest) {
                Text(label)
                    .font(.caption2.weight(.semibold))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .foregroundStyle(tint)
        .overlay {
            Capsule()
                .stroke(tint.opacity(0.25), lineWidth: 0.5)
        }
        .opacity(identifier.isEmpty && state == .none ? 0 : 1)
    }
}

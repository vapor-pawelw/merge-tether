import SwiftUI

struct MergeRequestAttentionCallout: View {
    let message: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .foregroundStyle(.primary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.11), in: shape)
        .overlay {
            shape.strokeBorder(.orange.opacity(0.25), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

import SwiftUI

/// Keep the repository distinct from its namespace, even when a long path is truncated.
struct RepositoryPathText: View {
    let path: String

    init(_ path: String) { self.path = path }

    var body: some View {
        let separator = path.lastIndex(of: "/")
        HStack(spacing: 0) {
            if let separator {
                Text(verbatim: String(path[...separator]))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(verbatim: separator.map { String(path[path.index(after: $0)...]) } ?? path)
                .foregroundStyle(Color.accentColor)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: path))
    }
}

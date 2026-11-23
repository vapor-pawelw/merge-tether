import SwiftUI
import MergeTetherRemote

struct MRIssueTag: View {
    let issues: [RemoteMRIssue]
    @State private var showsIssues = false

    var body: some View {
        if issues.count > 1 {
            Button { showsIssues = true } label: {
                capsule(Text(.MRIssues.mrIssuesCount(issues.count)), icon: "chevron.down", tint: .accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mr.issues.list")
            .popover(isPresented: $showsIssues, arrowEdge: .bottom) {
                popover
                    #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                    #endif
            }
            #if os(macOS)
            .preference(key: BoardDetailPopoverPresentedKey.self, value: showsIssues)
            #endif
        } else if let issue = issues.first {
            if let url = issue.linkURL {
                Link(destination: url) {
                    capsule(Text(verbatim: issue.reference), icon: "arrow.up.right", tint: .accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mr.issues.link")
                .accessibilityLabel(Text(verbatim: issue.reference))
                .accessibilityHint(Text(.MRIssues.mrIssuesOpenLink))
                .help(Text(verbatim: issue.title ?? issue.reference))
            } else {
                capsule(Text(verbatim: issue.reference), tint: .secondary)
                    .accessibilityIdentifier("mr.issues.reference")
                    .help(Text(verbatim: issue.title ?? issue.reference))
            }
        }
    }

    private func capsule(_ label: Text, icon: String? = nil, tint: Color) -> some View {
        HStack(spacing: 3) {
            label.lineLimit(1).truncationMode(.tail)
            if let icon {
                Image(systemName: icon).font(.system(size: 7, weight: .semibold)).accessibilityHidden(true)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .contentShape(Rectangle())
        .frame(maxWidth: 96)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var popover: some View {
        ViewThatFits(in: .vertical) {
            issueList
            ScrollView { issueList }.scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 260)
        .frame(maxHeight: 340)
    }

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(.MRIssues.mrIssuesInScope).font(.callout.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ForEach(Array(issues.enumerated()), id: \.offset) { index, issue in
                if index > 0 { Divider() }
                if let url = issue.linkURL {
                    Link(destination: url) { issueRow(issue, isLink: true) }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text(.MRIssues.mrIssuesOpenLink))
                } else {
                    issueRow(issue, isLink: false)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func issueRow(_ issue: RemoteMRIssue, isLink: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: issue.reference)
                .font(.callout.weight(.semibold))
                .foregroundStyle(isLink ? Color.accentColor : .secondary)
            if let title = issue.title {
                Text(verbatim: title).font(.callout).foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
            if isLink {
                Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .multilineTextAlignment(.leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI
import MergeTetherRemote
#if os(iOS)
import Accessibility
import UIKit
#endif

struct MRIssueTag: View {
    let issues: [RemoteMRIssue]
    let mergeRequestURL: URL?
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
            MRIssueReference(issue: issue, mergeRequestURL: mergeRequestURL) { label, tint in
                capsule(label, tint: tint)
            }
            .id(issue)
        }
    }

    private func capsule(_ label: Text, icon: String? = nil, tint: Color) -> some View {
        HStack(spacing: 3) {
            label.lineLimit(1).truncationMode(.head)
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
        .frame(maxWidth: 180)
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
                issueRow(issue)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func issueRow(_ issue: RemoteMRIssue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MRIssueReference(issue: issue, mergeRequestURL: mergeRequestURL) { label, tint in
                label.fontWeight(.semibold)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .font(.callout)
            .id(issue)
            if let title = issue.title {
                Text(verbatim: title).font(.callout).foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }
}

private struct MRIssueReference<ReferenceLabel: View>: View {
    let issue: RemoteMRIssue
    let mergeRequestURL: URL?
    @ViewBuilder let label: (Text, Color) -> ReferenceLabel
    #if os(iOS)
    @Environment(\.openURL) private var openURL
    @State private var showsPath = false
    #endif

    var body: some View {
        let reference = issue.displayReference(relativeTo: mergeRequestURL)
        let text = Text(verbatim: reference.label)
        let url = issue.linkURL
        let details = [reference.projectPath ?? reference.label, issue.title].compactMap { $0 }.joined(separator: "\n")
        Group {
            #if os(iOS)
            if let path = reference.projectPath {
                pathButton(text, path: path, url: url)
            } else {
                referenceControl(text, url: url)
            }
            #else
            referenceControl(text, url: url)
            #endif
        }
        .accessibilityIdentifier(url == nil ? "mr.issues.reference" : "mr.issues.link")
        .accessibilityLabel(text)
        .help(Text(verbatim: details))
    }

    @ViewBuilder private func referenceControl(_ text: Text, url: URL?) -> some View {
        if let url {
            #if os(macOS)
            Link(destination: url) { label(text, .accentColor) }
                .buttonStyle(.plain)
                .contextMenu { CopyMergeRequestLinkButton(url: url) }
            #else
            Menu { linkActions(url) } label: { label(text, .accentColor) }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityHint(Text(.MRIssues.mrIssuesLinkActions))
            #endif
        } else {
            label(text, .secondary)
        }
    }

    #if os(iOS)
    @ViewBuilder private func linkActions(_ url: URL,
                                          openLabel: LocalizedStringResource = .MRIssues.mrIssuesOpenLink) -> some View {
        Button {
            showsPath = false
            openURL(url)
        } label: {
            Label(openLabel, systemImage: "arrow.up.right.square")
        }
        Button {
            showsPath = false
            UIPasteboard.general.url = url
            AccessibilityNotification.Announcement(String(localized: .CommandCenter.commandCenterLinkCopied)).post()
        } label: {
            Label(.CommandCenter.commandCenterCopyLink, systemImage: "link")
        }
    }

    private func pathButton(_ text: Text, path: String, url: URL?) -> some View {
        Button { showsPath = true } label: { label(text, url == nil ? .secondary : .accentColor) }
            .buttonStyle(.plain)
            .accessibilityHint(Text(.Remote.remoteShowRepositoryPath))
            .popover(isPresented: $showsPath, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let url {
                        Divider()
                        linkActions(url, openLabel: .CommandCenter.commandCenterOpenGitLab)
                    }
                }
                .frame(width: 260, alignment: .leading)
                .padding(16)
                .presentationCompactAdaptation(.popover)
            }
    }
    #endif
}

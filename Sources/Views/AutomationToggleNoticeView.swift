import SwiftUI

struct AutomationToggleNoticeView: View {
    let notice: AutomationToggleNoticeCenter.Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: active ? "bolt.fill" : "bolt.slash")
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                switch notice.kind {
                case .global(let active):
                    Text(active ? .CommandCenter.commandCenterAutomationBannerGlobalActiveTitle
                         : .CommandCenter.commandCenterAutomationBannerGlobalSuspendedTitle).font(.headline)
                    Text(active ? .CommandCenter.commandCenterAutomationBannerGlobalActiveMessage
                         : .CommandCenter.commandCenterAutomationBannerGlobalSuspendedMessage).font(.subheadline)
                case .mergeRequest(let iid, let projectPath, let active):
                    Text(active ? .CommandCenter.commandCenterAutomationBannerMergeRequestActive("!\(iid)")
                         : .CommandCenter.commandCenterAutomationBannerMergeRequestPaused("!\(iid)")).font(.headline)
                    if let projectPath, !projectPath.isEmpty {
                        Text(verbatim: "\(projectPath) !\(iid)")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(.CommandCenter.commandCenterAutomationBannerDismiss))
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .task(id: notice.id) {
            do { try await Task.sleep(for: AutomationToggleNoticeCenter.displayDuration) } catch { return }
            dismiss()
        }
    }

    private var active: Bool {
        switch notice.kind {
        case .global(let active), .mergeRequest(_, _, let active): active
        }
    }
}

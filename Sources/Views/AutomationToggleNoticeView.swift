import SwiftUI

struct AutomationToggleNoticeView: View {
    let notice: AutomationToggleNoticeCenter.Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
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
                case .approvalChanged(let target, let removed):
                    Text(removed ? .Board.boardApprovalsRemoved : .Board.boardApprovalsApproved).font(.headline)
                    if removed {
                        Text(.Board.boardApprovalsAutomationOff).font(.subheadline)
                    }
                    if let iid = target.iid {
                        Text(verbatim: "!\(iid)").font(.caption).foregroundStyle(.secondary)
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

    private var symbol: String {
        switch notice.kind {
        case .global(let active), .mergeRequest(_, _, let active): active ? "play.fill" : "pause.fill"
        case .approvalChanged(_, let removed): removed ? "minus.circle" : "checkmark.seal"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .global(let active), .mergeRequest(_, _, let active): active ? .accentColor : .secondary
        case .approvalChanged(_, let removed): removed ? .orange : .accentColor
        }
    }
}

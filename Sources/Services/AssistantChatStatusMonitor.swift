import Foundation

@MainActor
final class AssistantChatStatusMonitor {
    private typealias Work = AssistantAutomationRunner.MergeRequestWork
    private var account: (host: String, username: String)?
    private var lastChecked: [Work: Date] = [:]
    private var lastStackCheck: [Int: Date] = [:]
    private var isRefreshing = false

    func refresh(glab: GlabService, host: String, username: String, settings: SettingsManager) {
        if account?.host != host || account?.username != username {
            account = (host, username)
            lastChecked = [:]
            lastStackCheck = [:]
        }
        guard !isRefreshing, CodexPluginInstaller.listenerURL() != nil else { return }
        isRefreshing = true
        let directory = CodexDesktopRelay.directory
        Task {
            defer { isRefreshing = false }
            let tracked = await Task.detached(priority: .utility) {
                CodexDesktopRelay.chatsNeedingMergeCheck(host: host, username: username, directory: directory)
            }.value
            guard glab.resolvedHost == host, glab.currentUsername == username else { return }
            let candidates = tracked.keys.sorted {
                (lastChecked[$0] ?? .distantPast, $0.projectID, $0.iid)
                    < (lastChecked[$1] ?? .distantPast, $1.projectID, $1.iid)
            }
            var openWork: Set<Work> = []
            // Check both authored and reviewed MRs. Closed MRs stay eligible for checks because they can reopen.
            for work in candidates.prefix(3) {
                lastChecked[work] = Date()
                guard let request = try? await glab.fetchMergeRequest(projectID: work.projectID, iid: work.iid, host: host),
                      glab.resolvedHost == host, glab.currentUsername == username,
                      request.projectID == work.projectID, request.iid == work.iid,
                      request.webURL.isGitLabMergeRequest(host: host, iid: work.iid),
                      let status = MRChatStatus(request: request), let chats = tracked[work] else { continue }
                if status == .open || status == .draft { openWork.insert(work) }
                var proposalThread: UUID?
                var proposal: String?
                if status == .merged, request.author.username == username,
                   settings.automation.scope.resolve(.init(host: host, username: username, projectID: work.projectID, iid: work.iid)).active,
                   let item = try? await glab.singleLinkedWorkItem(for: request, host: host) {
                    let key = AssistantAutomationRunner.ChatKey(assistant: .codex, work: work, username: username,
                                                                 workspace: "", access: .gitLabRead)
                    let recorded = key.reusableChat(in: settings.assistantChats) ?? settings.assistantHandoffs.last {
                        $0.key.work == work && $0.key.username == username && $0.key.assistant == .codex && $0.chatID != nil
                    }?.chatID
                    proposalThread = recorded.flatMap(UUID.init(uuidString:)) ?? chats.max { $0.uuidString < $1.uuidString }
                    proposal = """
                        GitLab confirmed this MR was merged: \(request.webURL.absoluteString)
                        Its linked work item is: \(item.absoluteString)

                        Follow the applicable MR skill. Read the live merged MR and linked work item using glab. Start your reply with a clickable Markdown link to the work item. Compare the merged change with the current item and propose a concise, copyable update only where the item needs one. Mention any remaining work separately. This is a proposal in this chat. Do not edit, comment on, close, or change the work item, MR, or repository without my separate instruction. If it is already current or the evidence is unavailable, say so.
                        """
                }
                guard glab.resolvedHost == host, glab.currentUsername == username else { return }
                let selectedThread = proposalThread
                let followUp = proposal
                await Task.detached(priority: .utility) {
                    for thread in chats {
                        CodexDesktopRelay.publishChatStatus(for: thread, status: status, directory: directory,
                            followUpPrompt: thread == selectedThread ? followUp : nil)
                    }
                }.value
            }
            let projects = Set(openWork.map(\.projectID)).sorted {
                (lastStackCheck[$0] ?? .distantPast, $0) < (lastStackCheck[$1] ?? .distantPast, $1)
            }
            for project in projects.prefix(3) {
                lastStackCheck[project] = Date()
                guard let snapshot = try? await glab.fetchMergeRequestStackSnapshot(projectID: project, host: host),
                      glab.resolvedHost == host, glab.currentUsername == username else { continue }
                let targets = tracked.filter {
                    openWork.contains($0.key) && $0.key.projectID == project && snapshot.openIIDs.contains($0.key.iid)
                }
                await Task.detached(priority: .utility) {
                    for (work, chats) in targets {
                        for chat in chats {
                            CodexDesktopRelay.publishStackTitle(for: chat, iid: work.iid,
                                                                position: snapshot.positions[work.iid], directory: directory)
                        }
                    }
                }.value
            }
        }
    }
}

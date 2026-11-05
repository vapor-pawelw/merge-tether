import Foundation

@MainActor
final class MergedAssistantChatMonitor {
    private typealias Work = AssistantAutomationRunner.MergeRequestWork

    private var account: (host: String, username: String)?
    private var merged: Set<Work> = []
    private var ownedBySomeoneElse: Set<Work> = []
    private var lastChecked: [Work: Date] = [:]
    private var lastStackCheck: [Int: Date] = [:]
    private var isRefreshing = false

    func refresh(todos: [Todo], glab: GlabService, host: String, username: String, settings: SettingsManager) {
        if account?.host != host || account?.username != username {
            account = (host, username)
            merged = []
            ownedBySomeoneElse = []
            lastChecked = [:]
            lastStackCheck = [:]
        }
        for todo in todos where todo.targetType == .mergeRequest && todo.target.state == "merged" {
            guard let iid = todo.target.iid, todo.targetURL.isGitLabMergeRequest(host: host, iid: iid) else { continue }
            merged.insert(.init(host: host, projectID: todo.project.id, iid: iid))
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
            // Check only MRs with a delivered chat. Give each one a turn without
            // adding an unbounded series of GitLab requests to an inbox refresh.
            let candidates = tracked.keys.filter { !merged.contains($0) && !ownedBySomeoneElse.contains($0) }
                .sorted { (lastChecked[$0] ?? .distantPast, $0.projectID, $0.iid)
                    < (lastChecked[$1] ?? .distantPast, $1.projectID, $1.iid) }
            for work in candidates.prefix(3) {
                lastChecked[work] = Date()
                guard let request = try? await glab.fetchMergeRequest(projectID: work.projectID, iid: work.iid, host: host),
                      glab.resolvedHost == host, glab.currentUsername == username,
                      request.webURL.isGitLabMergeRequest(host: host, iid: work.iid) else { continue }
                if request.author.username != username {
                    ownedBySomeoneElse.insert(work)
                } else if request.state == "merged" {
                    merged.insert(work)
                }
            }
            guard glab.resolvedHost == host, glab.currentUsername == username else { return }
            let mergedChats = tracked.filter { merged.contains($0.key) }
            var proposals: [UUID: String] = [:]
            for (work, chats) in mergedChats {
                guard settings.automation.scope.resolve(.init(host: host, username: username, projectID: work.projectID, iid: work.iid)).active,
                      let request = try? await glab.fetchMergeRequest(projectID: work.projectID, iid: work.iid, host: host),
                      request.state == "merged", request.webURL.isGitLabMergeRequest(host: host, iid: work.iid),
                      let item = try? await glab.singleLinkedWorkItem(for: request, host: host),
                      glab.resolvedHost == host, glab.currentUsername == username else { continue }
                let key = AssistantAutomationRunner.ChatKey(assistant: .codex, work: work, username: username,
                                                             workspace: "", access: .gitLabRead)
                let recorded = key.reusableChat(in: settings.assistantChats) ?? settings.assistantHandoffs.last {
                    $0.key.work == work && $0.key.username == username && $0.key.assistant == .codex && $0.chatID != nil
                }?.chatID
                let thread = recorded.flatMap(UUID.init(uuidString:)) ?? chats.max { $0.uuidString < $1.uuidString }
                guard let thread, chats.contains(thread) else { continue }
                proposals[thread] = """
                    GitLab confirmed this MR was merged: \(request.webURL.absoluteString)
                    Its linked work item is: \(item.absoluteString)

                    Follow the applicable MR skill. Read the live merged MR and linked work item using glab. Start your reply with a clickable Markdown link to the work item. Compare the merged change with the current item and propose a concise, copyable update only where the item needs one. Mention any remaining work separately. This is a proposal in this chat. Do not edit, comment on, close, or change the work item, MR, or repository without my separate instruction. If it is already current or the evidence is unavailable, say so.
                    """
            }
            guard glab.resolvedHost == host, glab.currentUsername == username else { return }
            let threadIDs = mergedChats.values.flatMap { $0 }
            let pendingProposals = proposals
            await Task.detached(priority: .utility) {
                for id in threadIDs {
                    CodexDesktopRelay.publishMergedTitle(for: id, directory: directory, followUpPrompt: pendingProposals[id])
                }
            }.value
            let openCandidates = tracked.filter { !merged.contains($0.key) }
            let projects = Set(openCandidates.keys.map(\.projectID)).sorted {
                (lastStackCheck[$0] ?? .distantPast, $0) < (lastStackCheck[$1] ?? .distantPast, $1)
            }
            for project in projects.prefix(3) {
                lastStackCheck[project] = Date()
                guard let snapshot = try? await glab.fetchMergeRequestStackSnapshot(projectID: project, host: host),
                      glab.resolvedHost == host, glab.currentUsername == username else { continue }
                let targets = openCandidates.filter {
                    $0.key.projectID == project && snapshot.openIIDs.contains($0.key.iid)
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

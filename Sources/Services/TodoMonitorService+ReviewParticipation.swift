import Foundation

enum ReviewParticipationError: Error { case persistence }

extension TodoMonitorService {
    func excludeReviewParticipant(username: String) async throws {
        guard let host = glab.resolvedHost, let account = glab.currentUsername else { throw GlabError.notAuthenticated }
        let revision = glab.accountRevision
        let identity = try await glab.resolvePublicationUser(username: username, host: host)
        guard glab.accountRevision == revision, glab.resolvedHost == host, glab.currentUsername == account else { throw CancellationError() }
        settings.reviewParticipationPreferences.exclude(identity, username: account)
        let persisted = settings.saveReviewParticipationPreferences()
        // A running worker has the old prompt; stop affected contact preparation without erasing its history.
        let active = settings.assistantHandoffs.filter {
            $0.key.work.host == host && $0.key.username == account && $0.workflow == .followUp
                && $0.pipelineReservation == nil && $0.execution?.state.isActive == true
        }
        for job in active {
            let work = job.key.work
            let discussions = try? await glab.fetchMergeRequestDiscussions(projectID: work.projectID, iid: work.iid, host: host)
            guard glab.accountRevision == revision, glab.currentUsername == account else { throw CancellationError() }
            let selected = Set(job.feedbackNoteIDs ?? discussions?.flatMap(\.notes).compactMap(\.id) ?? [])
            if discussions == nil || discussions?.flatMap(\.notes).contains(where: { $0.author?.id == identity.entityID && $0.id.map(selected.contains) == true }) == true {
                cancelAssistantJob(job.id)
            }
        }
        for item in attention.currentOpenItems {
            attention.retryAuthorFeedback(item.id)
        }
        guard persisted else { throw ReviewParticipationError.persistence }
    }

    func allowReviewParticipant(_ id: UUID) throws {
        guard let host = glab.resolvedHost, let account = glab.currentUsername,
              settings.reviewParticipationPreferences.entries.contains(where: { $0.id == id && $0.host == host && $0.username == account }) else { return }
        guard settings.removeReviewParticipationExclusion(id) else { throw ReviewParticipationError.persistence }
        for item in attention.currentOpenItems { attention.retryAuthorFeedback(item.id) }
    }
}

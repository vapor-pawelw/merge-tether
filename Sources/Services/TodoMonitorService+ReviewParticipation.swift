import Foundation

enum ReviewParticipationError: Error { case persistence, ownAccount }

extension TodoMonitorService {
    func markAutomationAuthor(username: String) async throws {
        guard let host = glab.resolvedHost, let account = glab.currentUsername,
              !host.isEmpty, !account.isEmpty else { throw GlabError.notAuthenticated }
        let revision = glab.accountRevision
        async let authenticatedUser = glab.fetchAuthenticatedUser(host: host, expectedUsername: account)
        async let resolvedIdentity = glab.resolvePublicationUser(username: username, host: host)
        let (user, identity) = try await (authenticatedUser, resolvedIdentity)
        guard !Task.isCancelled, glab.accountRevision == revision,
              glab.resolvedHost == host, glab.currentUsername == account,
              identity.host == host else { throw CancellationError() }
        guard identity.entityID != user.id else { throw ReviewParticipationError.ownAccount }
        if settings.reviewParticipationPreferences.isDeclaredAutomation(host: host, username: account, userID: identity.entityID) { return }
        guard settings.markAutomationAuthor(identity, host: host, user: user) else { throw ReviewParticipationError.persistence }
        synchronizeLocalAutomationAuthors()
        for item in attention.currentOpenItems { attention.retryAuthorFeedback(item.id) }
    }

    func unmarkAutomationAuthor(_ id: UUID) throws {
        guard let host = glab.resolvedHost, let account = glab.currentUsername,
              settings.reviewParticipationPreferences.localAutomationAuthors.contains(where: {
                  $0.id == id && $0.host == host && $0.username == account
              }) else { return }
        guard settings.unmarkAutomationAuthor(id, host: host, username: account) else { throw ReviewParticipationError.persistence }
        synchronizeLocalAutomationAuthors()
        for item in attention.currentOpenItems { attention.retryAuthorFeedback(item.id) }
    }

    func synchronizeLocalAutomationAuthors() {
        guard let host = glab.resolvedHost, let account = glab.currentUsername else { return }
        glab.updateLocalAutomationAuthors(settings.reviewParticipationPreferences.botIDs(host: host, username: account),
            host: host, username: account)
    }

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

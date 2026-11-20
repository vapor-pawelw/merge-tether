import Foundation
import Testing
import MergeTetherRemote

@MainActor @Suite struct RemotePhoneModelTests {
    @Test func detailCommentAvatarsArriveThroughTheCurrentRelayRequest() async throws {
        let f = try PhoneFixture(), model = f.model
        let url = try #require(URL(string: "https://gitlab.example.org/commenter"))
        var board = f.board
        board.lanes[0].cards[0].id = "mr:1:2"
        model.connect()
        await model.refresh()
        await f.reply(board: board, capabilities: [RemoteMessage.detailsCapability])
        let transport = f.transports[0]
        await model.requestDetails(card: board.cards[0])
        let request = try #require(transport.sent.last?.detailRequest)
        let details = RemoteMRDetails(checkedAt: f.date, threads: [
            .init(id: "thread", state: .open, notes: [.init(id: "1", body: "Comment", avatarURL: url)])
        ])
        await transport.onMessage?(.init(type: .details, detailResponse: .init(request: request, status: .current, details: details)))
        let jpeg = Data([1, 2, 3])
        let message = RemoteMessage(type: .avatarThumbnails, challenge: request.id, avatarThumbnails: [.init(url: url, jpeg: jpeg)])
        await transport.onMessage?(message)
        #expect(model.avatarThumbnails[url] == jpeg)
        model.cancelDetails()
        await transport.onMessage?(message)
        #expect(model.avatarThumbnails[url] == nil)
    }

    @Test func phoneAdvertisesBoardAvatarThumbnails() async throws {
        let fixture = try PhoneFixture()
        fixture.model.connect()
        await fixture.model.refresh()
        #expect(fixture.transports[0].sent.first?.capabilities?.contains(RemoteMessage.boardAvatarsCapability) == true)
    }

    @Test func phoneKeepsOnlyBoundedThumbnailsForTheAcceptedBoard() async throws {
        let f = try PhoneFixture(), model = f.model
        let author = try #require(URL(string: "https://gitlab.example.org/author"))
        let approver = try #require(URL(string: "https://gitlab.example.org/approver"))
        let unrelated = try #require(URL(string: "https://gitlab.example.org/unrelated"))
        let jpeg = Data([1, 2, 3])
        var board = f.board
        board.lanes[0].cards[0].presentation = .init(repository: "example", authorAvatarURL: author,
            approvalPeople: [.init(id: 1, name: "Approver", username: "approver", status: .approved, avatarURL: approver)])
        model.connect()
        await model.refresh()
        let transport = f.transports[0]
        let challenge = try #require(transport.sent.last?.challenge)
        let images: [RemoteAvatarThumbnail] = [
            .init(url: author, jpeg: jpeg), .init(url: unrelated, jpeg: jpeg),
            .init(url: approver, jpeg: Data(repeating: 0, count: RemoteAvatarThumbnail.maximumBytes + 1))
        ]
        await transport.onMessage?(.init(type: .avatarThumbnails, challenge: challenge, avatarThumbnails: images))
        #expect(model.avatarThumbnails.isEmpty)
        await f.reply(board: board)
        await transport.onMessage?(.init(type: .avatarThumbnails, challenge: UUID(), avatarThumbnails: images))
        #expect(model.avatarThumbnails.isEmpty)
        await transport.onMessage?(.init(type: .avatarThumbnails, challenge: challenge, avatarThumbnails: images))
        #expect(model.avatarThumbnails == [author: jpeg])
        await model.refresh()
        #expect(transport.sent.last?.cachedAvatarURLs == [author])
        board.account = "another-account"
        await f.reply(board: board)
        await transport.onMessage?(.init(type: .avatarThumbnails, challenge: challenge, avatarThumbnails: images))
        #expect(model.avatarThumbnails.isEmpty)
    }

    @Test(arguments: [RemoteCommandResult.Status.completed, .changed, .uncertain])
    func inboxSeenClosesOnlySuccessfulResultsAndRequestsTheUpdatedBoard(_ status: RemoteCommandResult.Status) async throws {
        let f = try PhoneFixture(), model = f.model
        var board = f.board
        board.lanes[0].cards[0].id = "completion:update"
        board.lanes[0].cards[0].actions = [.init(id: "seen", kind: .markDone, token: "checked")]
        model.connect(); await model.refresh(); await f.reply(board: board)
        let transport = f.transports[0], card = board.cards[0]
        transport.onCommand = { command in
            await transport.onMessage?(.init(type: .result, result: .init(id: command.id, status: status)))
        }
        await model.perform(card: card, action: card.actions[0])
        #expect(model.state.result?.status == (status == .completed ? nil : status))
        #expect(transport.sent.last?.type == .hello && transport.sent.last?.refresh == false)
    }

    @Test(arguments: [false, true])
    func pendingActionKeepsItsCardControlsOnlyInTheOriginalSession(_ sessionChanged: Bool) async throws {
        let f = try PhoneFixture(), model = f.model, board = f.board
        model.connect(); await model.refresh(); await f.reply(board: board)
        let transport = f.transports[0], card = board.cards[0], action = card.actions[0]
        await model.refresh()
        let challenge = try #require(transport.sent.last?.challenge)
        transport.onCommand = { command in
            #expect(model.state.pending?.actionID == action.id)
            #expect(model.pendingActionCard == card)
            var updated = board
            updated.lanes[0].cards[0].actions = []
            if sessionChanged { updated.hostSession = UUID() }
            await transport.onMessage?(.init(type: .snapshot, challenge: challenge, board: updated))
            #expect(model.state.board?.cards.first?.actions.isEmpty == true)
            #expect(model.pendingActionCard == (sessionChanged ? nil : card))
            await transport.onMessage?(.init(type: .result, result: .init(id: command.id, status: .completed)))
        }
        await model.perform(card: card, action: action)
        #expect(model.pendingActionCard == nil)
    }

    @Test(arguments: [false, true])
    func actionsReloadOpenDetailsEvenWhenTheBoardContextDoesNotChange(_ closeBeforeResult: Bool) async throws {
        let f = try PhoneFixture(), model = f.model
        var board = f.board; board.lanes[0].cards[0].id = "mr:1:2"
        let capabilities = [RemoteMessage.detailsCapability, RemoteMessage.detailContextCapability, RemoteMessage.cachedDetailsCapability]
        model.connect(); await model.refresh(); await f.reply(board: board, capabilities: capabilities)
        let transport = f.transports[0], card = board.cards[0]
        await model.requestDetails(card: card)
        let original = try #require(transport.sent.last?.detailRequest)
        #expect(original.cachedOnly == true)
        await transport.onMessage?(.init(type: .details, detailResponse: .init(request: original,
            status: .current, details: .init(checkedAt: f.date))))
        if closeBeforeResult { model.cancelDetails() }
        transport.onCommand = { command in
            await transport.onMessage?(.init(type: .result, result: .init(id: command.id, status: .completed)))
        }
        await model.perform(card: card, action: card.actions[0])
        await f.reply(board: board, capabilities: capabilities)
        #expect(transport.sent.filter { $0.type == .detailRequest }.count == (closeBeforeResult ? 1 : 2))
        if !closeBeforeResult {
            #expect(transport.sent.last?.detailRequest?.id != original.id)
            #expect(transport.sent.last?.detailRequest?.cachedOnly == true)
        }
    }

    @Test(arguments: [false, true])
    func stableDetailRequestsAreNegotiatedAndOldHostsKeepTheLegacyDigest(_ supported: Bool) async throws {
        let f = try PhoneFixture(), model = f.model
        var board = f.board; board.lanes[0].cards[0].id = "mr:1:2"
        model.connect(); await model.refresh()
        await f.reply(board: board, capabilities: [RemoteMessage.detailsCapability]
            + (supported ? [RemoteMessage.detailContextCapability] : []))
        await model.requestDetails(card: board.cards[0])
        let request = try #require(f.transports[0].sent.last?.detailRequest)
        #expect((request.contentDigest != nil) == supported)
        model.disconnect()
        #expect(!model.supportsDetailContext)
    }

    @Test(arguments: [false, true])
    func manualRefreshWaitsForTheBoardAndOpenDetailsAndCoalescesGestures(_ detailsOpen: Bool) async throws {
        let f = try PhoneFixture(), model = f.model
        var board = f.board; board.lanes[0].cards[0].id = "mr:1:2"
        let capabilities = [RemoteMessage.detailsCapability, RemoteMessage.detailContextCapability, RemoteMessage.detailPreviewCapability,
            RemoteMessage.cachedDetailsCapability]
        model.connect(); await model.refresh(); await f.reply(board: board, capabilities: capabilities)
        let transport = f.transports[0]
        #expect(transport.sent.first?.capabilities?.contains(RemoteMessage.detailPreviewCapability) == true)
        #expect(transport.sent.first?.refresh == false)
        if detailsOpen {
            await model.requestDetails(card: board.cards[0])
            let request = try #require(transport.sent.last?.detailRequest)
            #expect(request.cachedOnly == true)
            await transport.onMessage?(.init(type: .details, detailResponse: .init(request: request,
                status: .current, details: .init(checkedAt: f.date))))
        }
        var firstFinished = false, secondFinished = false
        let first = Task { await model.refreshContent(); firstFinished = true }
        let second = Task { await model.refreshContent(); secondFinished = true }
        let deadline = ContinuousClock.now + .seconds(2)
        while transport.sent.filter({ $0.type == .hello }).count < 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!firstFinished && !secondFinished)
        #expect(model.isManuallyRefreshingContent)
        #expect(transport.sent.last?.refresh == false)
        if detailsOpen { #expect(model.detailState.displayedDetails(for: board.cards[0], board: board) != nil) }
        await f.reply(board: board, capabilities: capabilities)
        if detailsOpen {
            let request = try #require(transport.sent.last?.detailRequest)
            #expect(request.contentDigest != nil && request.cachedOnly == true)
            #expect(!firstFinished && !secondFinished)
            #expect(model.detailState.pending == request)
            #expect(model.isManuallyRefreshingContent)
            await transport.onMessage?(.init(type: .details, detailResponse: .init(request: request,
                status: .current, details: .init(checkedAt: f.date, description: "Refreshed"))))
            #expect(model.detailState.displayedDetails(for: board.cards[0], board: board)?.description == "Refreshed")
        }
        await first.value; await second.value
        #expect(!model.isManuallyRefreshingContent)
        #expect(transport.sent.filter { $0.type == .hello }.count == 2)
        #expect(transport.sent.filter { $0.type == .detailRequest }.count == (detailsOpen ? 2 : 0))
        #expect(!model.isSynchronizingDetails)
    }

    @Test(arguments: [false, true])
    func explicitGitLabRefreshUsesOnlyTheRequestedScope(_ details: Bool) async throws {
        let f = try PhoneFixture(), model = f.model
        var board = f.board; board.lanes[0].cards[0].id = "mr:1:2"
        let capabilities = [RemoteMessage.detailsCapability, RemoteMessage.cachedDetailsCapability]
        model.connect(); await model.refresh(); await f.reply(board: board, capabilities: capabilities)
        let transport = f.transports[0], card = board.cards[0]
        let count = transport.sent.count
        let task = Task {
            if details { await model.refreshDetailsFromGitLab(card: card) }
            else { await model.refreshContent(fromGitLab: true) }
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while transport.sent.count == count, ContinuousClock.now < deadline { await Task.yield() }
        let sent = try #require(transport.sent.dropFirst(count).first)
        #expect(model.isManuallyRefreshingContent)
        if details {
            #expect(sent.type == .detailRequest && sent.refresh == nil)
            let request = try #require(sent.detailRequest)
            #expect(request.cardID == card.id && request.cachedOnly != true)
            await transport.onMessage?(.init(type: .details, detailResponse: .init(request: request,
                status: .current, details: .init(checkedAt: f.date, description: "From GitLab"))))
            #expect(model.detailState.details(for: card, board: board)?.description == "From GitLab")
        } else {
            #expect(sent.type == .hello && sent.refresh == true)
            await f.reply(board: board, capabilities: capabilities)
        }
        await task.value
        #expect(transport.sent.count == count + 1)
        #expect(!model.isManuallyRefreshingContent)
    }

    @Test func continuouslyChangingDetailsStopAutomaticRecoveryAfterTwoAttempts() async throws {
        let f = try PhoneFixture(), model = f.model
        var board = f.board; board.lanes[0].cards[0].id = "mr:1:2"
        model.connect(); await model.refresh(); await f.reply(board: board, capabilities: [RemoteMessage.detailsCapability])
        let transport = f.transports[0]
        await model.requestDetails(card: board.cards[0])
        for _ in 0..<2 {
            let request = try #require(transport.sent.last?.detailRequest)
            await transport.onMessage?(.init(type: .details, detailResponse: .init(request: request, status: .changed)))
            await f.reply(board: board, capabilities: [RemoteMessage.detailsCapability])
        }
        let count = transport.sent.count, request = try #require(transport.sent.last?.detailRequest)
        await transport.onMessage?(.init(type: .details, detailResponse: .init(request: request, status: .changed)))
        #expect(transport.sent.count == count)
        #expect(!model.isSynchronizingDetails)
        #expect(model.detailState.failure == .changed)
        #expect(transport.sent.allSatisfy { $0.type != .command })
    }

    @Test(arguments: [false, true])
    func changedDetailsRecoverThroughAFreshBoardWithoutAskingTheUser(_ actionRunning: Bool) async throws {
        let f = try PhoneFixture(), model = f.model
        var board = f.board; board.lanes[0].cards[0].id = "mr:1:2"
        let capabilities = [RemoteMessage.detailsCapability, RemoteMessage.cachedDetailsCapability]
        model.connect(); await model.refresh(); await f.reply(board: board, capabilities: capabilities)
        let transport = f.transports[0], card = board.cards[0]
        await model.requestDetails(card: card)
        let request = try #require(transport.sent.last?.detailRequest)
        let command = actionRunning ? model.state.command(card: card, action: card.actions[0], now: f.date) : nil
        let sends = transport.sent.count
        await transport.onMessage?(.init(type: .details, detailResponse: .init(request: request, status: .changed)))
        #expect(model.detailState.failure != .changed)
        if let command {
            #expect(transport.sent.count == sends)
            await transport.onMessage?(.init(type: .result, result: .init(id: command.id, status: .completed)))
        }
        #expect(transport.sent.last?.type == .hello)
        #expect(transport.sent.last?.refresh == false)
        board.lanes[0].cards[0].head = "after-action"
        await f.reply(board: board, capabilities: capabilities)
        let current = try #require(transport.sent.last?.detailRequest)
        #expect(current.id != request.id && current.cachedOnly == true)
        await transport.onMessage?(.init(type: .details, detailResponse: .init(request: current,
            status: .current, details: .init(checkedAt: f.date, description: "Current details"))))
        #expect(model.detailState.displayedDetails(for: board.cards[0], board: board)?.description == "Current details")
        #expect(model.detailState.failure == nil)
    }

    @Test(arguments: [RemoteCommandResult.Status.completed, .changed, .uncertain, .checked])
    func actionResultsSupersedePreActionSnapshotsWithoutRefreshingGitLab(_ status: RemoteCommandResult.Status) async throws {
        let f = try PhoneFixture(), model = f.model, board = f.board
        model.connect(); await model.refresh(); await f.reply(board: board)
        let transport = f.transports[0], card = board.cards[0]
        await model.refresh()
        let beforeAction = try #require(transport.sent.last?.challenge)
        transport.onCommand = { command in
            await transport.onMessage?(.init(type: .result, result: .init(id: command.id, status: status)))
        }
        await model.perform(card: card, action: card.actions[0])
        let refreshed = try #require(transport.sent.last { $0.type == .hello })
        #expect(refreshed.refresh == false)
        #expect(refreshed.challenge != beforeAction)
        var stale = board; stale.lanes[0].cards[0].title = "Before the action"
        await transport.onMessage?(.init(type: .snapshot, challenge: beforeAction, board: stale))
        #expect(model.state.board == board)
        var current = board; current.lanes[0].cards[0].title = "After the action"
        await f.reply(board: current)
        #expect(model.state.board == current)
        #expect(transport.sent.filter { $0.type == .command }.count == 1)
    }

    @Test func unsolicitedResultsCannotStartRefreshes() async throws {
        let f = try PhoneFixture(), model = f.model
        model.connect(); await model.refresh(); await f.reply()
        let transport = f.transports[0], count = transport.sent.count
        await transport.onMessage?(.init(type: .result, result: .init(id: UUID(), status: .completed)))
        #expect(transport.sent.count == count)
    }

    @Test(arguments: [false, true])
    func originOnlyMessagesUpdateAnOpenConversationAutomaticallyAndCloseCancelsTheCompletedSubscription(_ supported: Bool) async throws {
        let f = try PhoneFixture(), model = f.model
        model.connect(); await model.refresh()
        var board = f.board; board.lanes[0].cards[0].id = "mr:1:2"
        await f.reply(board: board, capabilities: [RemoteMessage.detailsCapability]
            + (supported ? [RemoteMessage.detailOriginsCapability] : []))
        let transport = f.transports[0], card = board.cards[0]
        await model.requestDetails(card: card)
        let request = try #require(transport.sent.last?.detailRequest)
        let note = RemoteDetailNote(id: "1", body: "Root body", authorID: 7)
        let details = RemoteMRDetails(checkedAt: f.date, threads: [.init(id: "thread", state: .open, notes: [note])])
        await transport.onMessage?(.init(type: .details, detailResponse: .init(request: request, status: .current, details: details)))
        let identity = try #require(note.originIdentity(in: "thread"))
        let update = RemoteDetailOrigins(request: request,
            changes: [.init(threadID: "thread", noteID: "1", identity: identity, origin: .ai)])
        await transport.onMessage?(.init(type: .details, detailOrigins: update))
        #expect(model.detailState.response?.details?.threads?.first?.notes.first?.origin == (supported ? .ai : nil))
        #expect(transport.sent.filter { $0.type == .detailRequest }.count == 1)
        #expect(transport.sent.allSatisfy { $0.type != .command })
        model.cancelDetails()
        let deadline = ContinuousClock.now + .seconds(3)
        while !transport.sent.contains(where: { $0.type == .cancelDetails }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(transport.sent.last?.detailRequest == request && model.detailState.openRequest == nil)
        let late = RemoteDetailOrigins(request: request,
            changes: [.init(threadID: "thread", noteID: "1", identity: identity, origin: .human, revision: 2)])
        await transport.onMessage?(.init(type: .details, detailOrigins: late))
        #expect(model.detailState.response?.details?.threads?.first?.notes.first?.origin == (supported ? .ai : nil))
        await model.requestDetails(card: card)
        let reopened = try #require(transport.sent.last?.detailRequest)
        #expect(reopened != request && model.detailState.openRequest == reopened)
    }

    @Test(arguments: [nil, "http://insecure.example.org"] as [String?])
    func unavailableRelayNeverReadsTrustOrRecoveryAndNeverConnects(_ origin: String?) throws {
        let model = RemotePhoneModel(relayConfiguration: .init(rawOrigin: origin),
            loadPairing: { Issue.record("Unconfigured build read trust"); return nil },
            savePairing: { _ in Issue.record("Unconfigured build wrote trust") },
            loadRecovery: { Issue.record("Unconfigured build read recovery"); return nil },
            makeConnection: { _ in Issue.record("Unconfigured build created transport"); return PhoneTransport() })
        model.connect(); model.reconnect()
        #expect(!model.paired)
        let host = try RemotePairing.generate(origin: URL(string: "https://relay.example.org")!, access: String(repeating: "A", count: 43))
        model.offerPairing(host.deepLink.absoluteString)
        #expect(model.pairingCandidate == nil)
        #expect(!model.acceptPairing())
    }

    @Test func savedPairingForAnotherOriginStaysUntouchedAndOffline() throws {
        let fixture = try PhoneFixture()
        let model = RemotePhoneModel(relayConfiguration: .init(rawOrigin: "https://different.example.org"),
            loadPairing: { fixture.pairing }, savePairing: { _ in Issue.record("Migrated existing trust") },
            loadRecovery: { Issue.record("Loaded recovery for mismatched relay"); return nil },
            makeConnection: { _ in Issue.record("Connected to mismatched relay"); return PhoneTransport() })
        model.connect()
        #expect(!model.paired)
        #expect(model.relayMismatch)
        #expect(model.state.board == nil)
        #expect(model.pairingCandidate == nil)
    }

    @Test func otherOriginInvitationAndDirectCandidateCannotReplaceCurrentTrust() throws {
        let fixture = try PhoneFixture(), model = fixture.model
        let host = try RemotePairing.generate(origin: URL(string: "https://relay.example.org.evil.test")!,
            access: String(repeating: "B", count: 43), now: fixture.date)
        model.offerPairing(host.deepLink.absoluteString)
        #expect(model.relayMismatch)
        #expect(model.pairingCandidate == nil)
        model.pairingCandidate = try RemotePairing(url: host.deepLink, now: fixture.date)
        #expect(!model.acceptPairing())
        #expect(model.paired)
        #expect(fixture.saved.isEmpty)
        #expect(fixture.transports.isEmpty)
    }

    @Test func refreshUsesExistingTransportAndCoalescesOutstandingRequests() async throws {
        let fixture = try PhoneFixture()
        let model = fixture.model
        model.connect()
        await model.refresh()
        await model.refresh()
        #expect(fixture.transports.count == 1)
        #expect(fixture.transports[0].sent.map(\.type) == [.hello])
        #expect(fixture.transports[0].sent[0].capabilities?.contains(RemoteMessage.markReadyCapability) == true)
        await fixture.reply()
        #expect(model.state.isConnected(now: fixture.date))
        await model.refresh()
        #expect(fixture.transports[0].sent.map(\.type) == [.hello, .hello])
        #expect(fixture.saved.isEmpty)
    }
    @Test func oldCommandSendFailureCannotDisconnectANewConnection() async throws {
        // given
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let old = fixture.transports[0], card = try #require(model.state.board?.cards.first)
        old.suspendSend = true
        let sending = Task { await model.perform(card: card, action: card.actions[0]) }
        while old.sendBarrier == nil { await Task.yield() }
        // when
        model.reconnect()
        await model.refresh(); await fixture.reply()
        #expect(model.state.result?.status == .uncertain)
        old.sendBarrier?.resume(throwing: RemoteProtocolError.invalid)
        await sending.value
        // then
        #expect(model.state.isConnected(now: fixture.date))
        #expect(fixture.transports[1].sent.map(\.type) == [.hello, .receipt])
        #expect(model.state.result?.status == .uncertain)
    }

    @Test func savedPairingConnectsThenTimesOutWithoutLosingTrustAndAcceptsALateSnapshot() async throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh()
        #expect(model.paired)
        #expect(model.connectionStatus(now: fixture.date) == .connecting)
        fixture.date += 46
        #expect(model.connectionStatus(now: fixture.date) == .offline)
        #expect(!model.state.canAct(now: fixture.date))
        await model.refresh(); await fixture.reply()
        #expect(model.connectionStatus(now: fixture.date) == .connected)
        #expect(fixture.saved.isEmpty)
    }

    @Test func reconnectReplacesOnlyTransportCoalescesAndRequiresAFreshSnapshot() async throws {
        // given
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let board = try #require(model.state.board), old = fixture.transports[0]
        // when
        model.reconnect(); model.reconnect(); model.connect()
        // then
        #expect(old.stopped)
        #expect(fixture.transports.count == 2)
        #expect(model.state.board == board)
        #expect(!model.state.canAct(now: fixture.date))
        #expect(model.connectionStatus(now: fixture.date) == .connecting)
        #expect(fixture.saved.isEmpty)
        await model.refresh(); await fixture.reply()
        #expect(model.state.canAct(now: fixture.date))
        #expect(fixture.transports[1].sent.map(\.type) == [.hello])
    }

    @Test func obsoleteCallbacksAndQueuedStatusRefreshCannotAffectReplacement() async throws {
        // given
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let old = fixture.transports[0], callback = old.onMessage, status = old.onStatus
        status?(true, false) // Schedules a refresh that must remain bound to this transport.
        // when
        model.reconnect()
        status?(false, true)
        await callback?(.init(type: .unavailable))
        await callback?(.init(type: .snapshot, challenge: old.sent.last?.challenge, board: fixture.board))
        await Task.yield()
        // then
        #expect(!model.error)
        #expect(model.connectionStatus(now: fixture.date) == .connecting)
        #expect(!model.state.canAct(now: fixture.date))
        #expect(fixture.transports[1].sent.isEmpty)
    }

    @Test func foregroundRestartsAfterBackgroundAndOldSendFailureOnSameTransportIsIgnored() async throws {
        // given
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let transport = fixture.transports[0], card = try #require(model.state.board?.cards.first)
        transport.suspendSend = true
        let sending = Task { await model.perform(card: card, action: card.actions[0]) }
        while transport.sendBarrier == nil { await Task.yield() }
        // when: automatic socket loss/recovery can reuse the same transport object.
        transport.onStatus?(false, false)
        transport.suspendSend = false
        await model.refresh(); await fixture.reply()
        transport.sendBarrier?.resume(throwing: RemoteProtocolError.invalid)
        await sending.value
        // then
        #expect(model.connectionStatus(now: fixture.date) == .connected)
        #expect(model.state.result?.status == .uncertain)
        model.disconnect(); model.connect(); model.connect()
        #expect(fixture.transports.count == 2)
        #expect(model.connectionStatus(now: fixture.date) == .connecting)
    }

    @Test func successfulTrustClosesPairingEvenWhenTransportCreationFailsAndReplacementClearsOldBoard() async throws {
        // given
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let previousState = model.state
        fixture.failConnection = true
        let replacement = try RemotePairing.generate(origin: URL(string: "https://relay.example.org")!, access: String(repeating: "B", count: 43), now: fixture.date)
        model.offerPairing(replacement.deepLink.absoluteString)
        // when
        let candidate = try #require(model.pairingCandidate)
        let oldMessage = fixture.transports[0].onMessage
        let accepted = model.acceptPairing()
        await oldMessage?(.init(type: .unavailable))
        // then
        #expect(accepted)
        #expect(model.paired)
        #expect(model.pairingCandidate == nil)
        #expect(model.state !== previousState)
        #expect(model.state.board == nil)
        #expect(fixture.saved == [candidate])
        #expect(model.connectionStatus(now: fixture.date) == .failed)
        fixture.failConnection = false
        model.reconnect(); await model.refresh(); await fixture.reply()
        #expect(model.connectionStatus(now: fixture.date) == .connected)
    }

    @Test func rejectedPairingSaveKeepsExistingBoardAndConnection() async throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let board = model.state.board
        fixture.failSave = true
        model.offerPairing(fixture.pairing.deepLink.absoluteString)
        let accepted = model.acceptPairing()
        #expect(!accepted)
        #expect(model.state.board == board)
        #expect(!fixture.transports[0].stopped)
        #expect(model.pairingCandidate != nil)
    }

    @Test func unpairedStartupAndReconnectNeverCreateATransport() throws {
        var connections = 0
        let model = RemotePhoneModel(relayConfiguration: .init(rawOrigin: "https://relay.example.org"), loadPairing: { nil }, savePairing: { _ in Issue.record("Unexpected pairing write") },
            makeConnection: { _ in connections += 1; return PhoneTransport() })
        model.connect(); model.reconnect()
        #expect(model.connectionStatus() == .unpaired)
        #expect(connections == 0)
    }

    @Test func reconnectKeepsPendingCommandUncertainAndIgnoresItsLateResultWithoutReplay() async throws {
        // given
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let old = fixture.transports[0], card = try #require(model.state.board?.cards.first)
        old.suspendSend = true
        let sending = Task { await model.perform(card: card, action: card.actions[0]) }
        while old.sendBarrier == nil { await Task.yield() }
        let command = try #require(model.state.pending), callback = old.onMessage
        await callback?(.init(type: .accepted, result: .init(id: command.id, status: .running)))
        // when
        model.reconnect()
        old.sendBarrier?.resume()
        await sending.value
        await model.refresh(); await fixture.reply()
        await callback?(.init(type: .result, result: .init(id: command.id, status: .completed)))
        await model.perform(card: card, action: card.actions[0])
        // then
        #expect(model.state.result == .init(id: command.id, status: .uncertain))
        #expect(!model.state.canAct(now: fixture.date))
        #expect(fixture.transports[1].sent.map(\.type) == [.hello, .receipt])
        model.state.acknowledgeResult()
        #expect(model.state.canAct(now: fixture.date))
    }

    @Test func expiredOrPartialSnapshotsNeverGrantWritePermission() async throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh()
        fixture.date += 46
        await fixture.reply()
        #expect(model.connectionStatus(now: fixture.date) == .offline)
        #expect(!model.state.canAct(now: fixture.date))
        await model.refresh()
        var board = fixture.board; board.partial = true
        let transport = fixture.transports[0]
        await transport.onMessage?(.init(type: .snapshot, challenge: transport.sent.last?.challenge, board: board))
        #expect(model.connectionStatus(now: fixture.date) == .connected)
        #expect(!model.state.canAct(now: fixture.date))
    }

    @Test func transportFailureIsVisibleAndExplicitReconnectCanRecover() async throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect()
        fixture.transports[0].onStatus?(false, true)
        #expect(model.connectionStatus(now: fixture.date) == .failed)
        model.reconnect(); await model.refresh(); await fixture.reply()
        #expect(model.connectionStatus(now: fixture.date) == .connected)
        await fixture.transports[1].onMessage?(.init(type: .unavailable))
        #expect(model.connectionStatus(now: fixture.date) == .failed)
        #expect(!model.state.canAct(now: fixture.date))
    }

    @Test func approvalRequiresAnExplicitSingleUseConfirmationForTheDisplayedRequest() async throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh()
        let board = fixture.approvalBoard
        await fixture.reply(board: board)
        let card = try #require(board.cards.first), action = try #require(card.actions.first)
        await model.perform(card: card, action: action)
        #expect(fixture.transports[0].sent.allSatisfy { $0.type != .command })
        let id = try #require(model.prepareApproval(card: card, action: action))
        let transport = fixture.transports[0]
        transport.onCommand = { command in await transport.onMessage?(.init(type: .result, result: .init(id: command.id, status: .completed))) }
        await model.perform(card: card, action: action, approvalID: id)
        model.state.acknowledgeResult()
        await model.perform(card: card, action: action, approvalID: id)
        #expect(transport.sent.filter { $0.type == .command }.count == 1)
    }

    @Test func expiredApprovalOffersARefreshAndRequiresNewConsentForTheCurrentCommit() async throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh()
        var board = fixture.approvalBoard
        await fixture.reply(board: board)
        let card = try #require(board.cards.first), action = try #require(card.actions.first)
        let expired = try #require(model.prepareApproval(card: card, action: action))
        let transport = fixture.transports[0]

        fixture.date += 30
        await model.perform(card: card, action: action, approvalID: expired)
        #expect(model.expiredApprovalCardID == card.id)
        #expect(model.state.result == nil)
        #expect(fixture.pendingRecovery == nil)
        #expect(transport.sent.allSatisfy { $0.type != .command })

        let reloading = Task { await model.reloadAfterApprovalExpiry(cardID: card.id) }
        defer { reloading.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while transport.sent.filter({ $0.type == .hello }).count < 2, ContinuousClock.now < deadline { await Task.yield() }
        try #require(transport.sent.last?.type == .hello && transport.sent.last?.refresh == false)
        #expect(model.prepareApproval(card: card, action: action) == nil)
        board.lanes[0].cards[0].head = "current-head"
        board.lanes[0].cards[0].actions[0].token = "current-approval-token"
        await fixture.reply(board: board)
        await reloading.value
        #expect(model.expiredApprovalCardID == nil)
        #expect(model.state.board?.cards.first?.head == "current-head")

        let current = try #require(board.cards.first), currentAction = try #require(current.actions.first)
        await model.perform(card: current, action: currentAction, approvalID: expired)
        #expect(transport.sent.allSatisfy { $0.type != .command })
        let approval = try #require(model.prepareApproval(card: current, action: currentAction))
        transport.onCommand = { command in
            await transport.onMessage?(.init(type: .result, result: .init(id: command.id, status: .completed)))
        }
        await model.perform(card: current, action: currentAction, approvalID: approval)
        #expect(transport.sent.compactMap(\.command).map(\.token) == [currentAction.token])
    }

    @Test(arguments: ["head", "account", "session", "action", "target", "title", "expiry", "disconnect", "cancel"])
    func approvalCannotOutliveOrChangeItsIntendedContext(_ change: String) async throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh()
        var board = fixture.approvalBoard
        await fixture.reply(board: board)
        let card = try #require(board.cards.first), action = try #require(card.actions.first)
        let id = try #require(model.prepareApproval(card: card, action: action))
        switch change {
        case "head": board.lanes[0].cards[0].head = "new-head"
        case "account": board.account = "different"
        case "session": board.hostSession = UUID()
        case "action": board.lanes[0].cards[0].actions[0].token = "new-token"
        case "target": board.lanes[0].cards[0].url = URL(string: "https://gitlab.example.org/other/-/merge_requests/2")
        case "title": board.lanes[0].cards[0].title = "Another request"
        case "expiry": fixture.date += 31
        case "disconnect": fixture.transports[0].onStatus?(false, false)
        case "cancel": model.cancelApproval()
        default: Issue.record("Unknown context")
        }
        await model.refresh(force: true); await fixture.reply(board: board)
        await model.perform(card: card, action: action, approvalID: id)
        #expect(fixture.transports[0].sent.allSatisfy { $0.type != .command })
    }
    @Test func pairingCandidateIsRecheckedAtAcceptanceAgainstTheInjectedClock() throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.offerPairing(fixture.pairing.deepLink.absoluteString)
        #expect(model.pairingCandidate != nil)
        fixture.date = fixture.pairing.expiresAt
        #expect(!model.acceptPairing())
        #expect(fixture.saved.isEmpty)
    }

    @Test func unsupportedInvitationClearsAnyEarlierTrustCandidate() throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.offerPairing(fixture.pairing.deepLink.absoluteString)
        #expect(model.pairingCandidate != nil)
        model.offerPairing(fixture.pairing.deepLink.absoluteString.replacingOccurrences(of: "v=2", with: "v=1"))
        #expect(model.pairingCandidate == nil)
        #expect(!model.acceptPairing())
        #expect(fixture.saved.isEmpty)
    }

    @Test(arguments: ["ignoreSuggestion:10", "restoreSuggestion:8E309183-A550-48D5-88EC-6FDBCEE90796", "markDone"],
                    [false, true])
    func commandCompletionUsesTheAppropriateRefresh(_ actionID: String, recovered: Bool) async throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh()
        var board = fixture.board
        let kind = try #require(RemoteActionKind(rawValue: String(actionID.prefix { $0 != ":" })))
        let action = RemoteAction(id: actionID, kind: kind, token: "token")
        board.lanes[0].cards[0].actions = [action]
        await fixture.reply(board: board)
        let transport = fixture.transports[0], card = try #require(board.cards.first)
        transport.onCommand = { command in
            if recovered { transport.onStatus?(false, false) }
            else { await transport.onMessage?(.init(type: .result, result: .init(id: command.id, status: .completed))) }
        }
        await model.perform(card: card, action: action)
        if recovered {
            model.disconnect()
            let restarted = fixture.makeModel()
            restarted.connect(); await restarted.refresh(); await fixture.reply(board: board)
            let current = try #require(fixture.transports.last)
            let receipt = try #require(current.sent.last)
            try #require(receipt.type == .receipt)
            let command = try #require(receipt.command)
            await current.onMessage?(.init(type: .receiptResult, challenge: receipt.challenge,
                result: .init(id: command.id, status: .completed)))
            #expect(restarted.state.result?.status == .completed)
        } else {
            #expect(model.state.result?.status == .completed)
        }
        let hello = try #require(fixture.transports.last?.sent.last)
        #expect(hello.type == .hello && hello.refresh == false)
    }

    @Test func phoneRestartQueriesTheDurableCommandWithoutSendingItAgainAndRetainsItUntilAcknowledged() async throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let transport = fixture.transports[0], card = try #require(model.state.board?.cards.first)
        transport.suspendSend = true
        let sending = Task { await model.perform(card: card, action: card.actions[0]) }
        while transport.sendBarrier == nil { await Task.yield() }
        let command = try #require(fixture.pendingRecovery?.command)
        model.disconnect(); transport.sendBarrier?.resume(); await sending.value
        let restarted = fixture.makeModel()
        #expect(restarted.state.result?.status == .uncertain)
        restarted.connect(); await restarted.refresh(); await fixture.reply()
        let current = fixture.transports.last!
        #expect(current.sent.map(\.type) == [.hello, .receipt])
        #expect(current.sent.last?.command == command)
        await current.onMessage?(.init(type: .receiptResult, challenge: UUID(), result: .init(id: command.id, status: .completed)))
        #expect(restarted.state.result?.status == .uncertain)
        await current.onMessage?(.init(type: .receiptResult, challenge: current.sent.last?.challenge, result: .init(id: command.id, status: .completed)))
        #expect(restarted.state.result?.status == .completed)
        #expect(fixture.pendingRecovery?.command == command)
        fixture.recoveryFailure = "remove"
        restarted.state.acknowledgeResult()
        #expect(restarted.state.result?.status == .completed)
        #expect(fixture.pendingRecovery != nil)
        fixture.recoveryFailure = nil
        restarted.state.acknowledgeResult()
        #expect(restarted.state.result == nil)
        #expect(fixture.pendingRecovery == nil)
    }
    @Test(arguments: ["read", "save"])
    func phoneRecoveryStorageFailureNeverAllowsAnUnrecordedCommand(_ failure: String) async throws {
        let fixture = try PhoneFixture()
        fixture.recoveryFailure = failure
        let model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let card = try #require(model.state.board?.cards.first)
        await model.perform(card: card, action: card.actions[0])
        #expect(fixture.transports[0].sent.allSatisfy { $0.type != .command })
        #expect(fixture.pendingRecovery == nil)
    }

    @Test func detailRequestsRequireHostCapabilityAndDoNotRenewTheBoardLeaseOrSendAWrite() async throws {
        let f = try PhoneFixture(), model = f.model
        model.connect(); await model.refresh()
        var board = f.board
        board.lanes[0].cards[0].id = "mr:1:2"
        board.lanes[0].cards[0].actions = []
        let card = board.cards[0]
        await f.reply(board: board)
        await model.requestDetails(card: card)
        #expect(f.transports[0].sent.allSatisfy { $0.type != .detailRequest })
        await model.refresh()
        await f.reply(board: board, capabilities: [RemoteMessage.detailsCapability])
        await model.requestDetails(card: card)
        let request = try #require(f.transports[0].sent.last?.detailRequest)
        let lease = f.date
        f.date += 46
        await f.transports[0].onMessage?(.init(type: .details, detailResponse: .init(request: request,
            status: .current, details: .init(checkedAt: f.date))))
        #expect(model.detailState.details(for: card, board: board) != nil)
        #expect(!model.state.canAct(now: f.date))
        #expect(!model.state.isConnected(now: f.date))
        #expect(model.state.canAct(now: lease))
        #expect(model.state.pending == nil && model.state.result == nil)
        #expect(f.transports[0].sent.allSatisfy { $0.type != .command })
    }

    @Test func closingDetailsCancelsOnlyTheReadAndAnObsoleteTransportCannotSupplyNewDetails() async throws {
        let f = try PhoneFixture(), model = f.model
        model.connect(); await model.refresh()
        var board = f.board; board.lanes[0].cards[0].id = "mr:1:2"
        await f.reply(board: board, capabilities: [RemoteMessage.detailsCapability])
        let old = f.transports[0], card = board.cards[0]
        await model.requestDetails(card: card)
        let request = try #require(old.sent.last?.detailRequest)
        model.cancelDetails()
        #expect(model.detailState.pending == nil)
        await old.onMessage?(.init(type: .details, detailResponse: .init(request: request, status: .current, details: .init(checkedAt: f.date))))
        #expect(model.detailState.response == nil)
        model.disconnect(); model.connect(); await model.refresh()
        await f.reply(board: board, capabilities: [RemoteMessage.detailsCapability])
        await model.requestDetails(card: card)
        let current = try #require(f.transports[1].sent.last?.detailRequest)
        await old.onMessage?(.init(type: .details, detailResponse: .init(request: current, status: .current, details: .init(checkedAt: f.date))))
        #expect(model.detailState.response == nil)
        await f.transports[1].onMessage?(.init(type: .details, detailResponse: .init(request: current, status: .current, details: .init(checkedAt: f.date))))
        #expect(model.detailState.response?.request == current)
        #expect(model.state.pending == nil && model.state.result == nil)
    }

    @Test func detailsForADifferentAccountCannotReplaceTheCurrentReadOrRearmApprovalConfirmation() async throws {
        let f = try PhoneFixture(), model = f.model
        model.connect(); await model.refresh()
        var board = f.approvalBoard; board.lanes[0].cards[0].id = "mr:1:2"
        await f.reply(board: board, capabilities: [RemoteMessage.detailsCapability])
        let card = board.cards[0], action = card.actions[0]
        let approval = try #require(model.prepareApproval(card: card, action: action))
        await model.requestDetails(card: card)
        let request = try #require(f.transports[0].sent.last?.detailRequest)
        board.account = "other@host"
        await model.refresh()
        await f.reply(board: board, capabilities: [RemoteMessage.detailsCapability])
        await f.transports[0].onMessage?(.init(type: .details, detailResponse: .init(request: request, status: .current, details: .init(checkedAt: f.date))))
        #expect(model.detailState.response == nil)
        await model.perform(card: card, action: action, approvalID: approval)
        #expect(f.transports[0].sent.allSatisfy { $0.type != .command })
    }
}

@MainActor private final class PhoneFixture {
    var date = Date()
    var transports: [PhoneTransport] = []
    var failSave = false
    var failConnection = false
    var saved: [RemotePairing] = []
    let pairing: RemotePairing
    var pendingRecovery: RemoteCommandRecovery?
    var recoveryFailure: String?
    lazy var model = makeModel()
    func makeModel() -> RemotePhoneModel {
        RemotePhoneModel(relayConfiguration: .init(rawOrigin: pairing.origin.absoluteString), loadPairing: { self.pairing }, savePairing: { if self.failSave { throw RemoteProtocolError.invalid }; self.saved.append($0) },
            loadRecovery: { if self.recoveryFailure == "read" { throw RemoteProtocolError.invalid }; return self.pendingRecovery },
            saveRecovery: { if self.recoveryFailure == "save" { throw RemoteProtocolError.invalid }; self.pendingRecovery = $0 },
            removeRecovery: { if self.recoveryFailure == "remove" { throw RemoteProtocolError.invalid }; self.pendingRecovery = nil },
            makeConnection: { _ in if self.failConnection { throw RemoteProtocolError.invalid }; let value = PhoneTransport(); self.transports.append(value); return value }, now: { self.date })
    }
    init() throws {
        let invitation = try RemotePairing.generate(origin: URL(string: "https://relay.example.org")!, access: String(repeating: "A", count: 43), now: date)
        pairing = try RemotePairing(url: invitation.deepLink, now: date)
    }
    var board: RemoteBoard {
        .init(hostSession: UUID(), account: "fixture", lanes: [.init(id: .own, cards: [
            .init(id: "card", title: "Fixture", project: "example", url: nil, head: "abc", actions: [.init(id: "done", kind: .markDone, token: "token")])
        ])])
    }
    var approvalBoard: RemoteBoard {
        var board = board
        board.lanes[0].cards[0].actions = [.init(id: "approve", kind: .approve, token: "approval-token")]
        return board
    }
    func reply(board supplied: RemoteBoard? = nil, capabilities: [String]? = nil) async {
        let transport = transports.last!
        await transport.onMessage?(.init(type: .snapshot, challenge: transport.sent.last?.challenge, board: supplied ?? board, capabilities: capabilities))
    }
}

@MainActor private final class PhoneTransport: RemotePhoneTransport {
    var onMessage: (@MainActor (RemoteMessage) async -> Void)?
    var onStatus: (@MainActor (Bool, Bool) -> Void)?
    var sent: [RemoteMessage] = []
    var stopped = false
    var onCommand: ((RemoteCommand) async -> Void)?
    var sendBarrier: CheckedContinuation<Void, any Error>?
    var suspendSend = false
    func start() {}
    func stop() { stopped = true; onStatus?(false, false) }
    func send(_ message: RemoteMessage) async throws {
        sent.append(message)
        if let command = message.command { await onCommand?(command) }
        if suspendSend { try await withCheckedThrowingContinuation { sendBarrier = $0 } }
    }
}

import Foundation
import Observation

/// Account-scoped inbox state. The monitor coordinates MR routing and automation after a successful read.
@MainActor @Observable
final class InboxTodoStore {
    struct Fetch {
        let host: String?
        let username: String?
        let revision: UInt64
        let result: Result<[Todo], GlabError>
    }

    let glab: GlabService
    private let settings: SettingsManager
    private(set) var allTodos: [Todo] = []
    var lastError: GlabError?
    private(set) var lastRefresh: Date?
    private(set) var isLoading = false
    private(set) var hasCompletedFirstFetch = false
    private(set) var host: String?
    private(set) var username: String?
    private(set) var accountRevision: UInt64?
    private(set) var optimisticallyDone: Set<Int> = []
    private var pendingMarkDoneTask: Task<Void, Never>?
    private(set) var undoableTodo: Todo?
    static let undoWindow: Duration = .seconds(4)
    private var acknowledgedDuringFetch: Set<Int> = []
    @ObservationIgnored var onAcknowledged: ((Int) -> Void)?

    init(settings: SettingsManager, glab: GlabService) {
        self.settings = settings
        self.glab = glab
    }

    var visibleTodos: [Todo] {
        allTodos.filter { !optimisticallyDone.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
    }

    var currentAccountTodos: [Todo] {
        guard let currentHost = glab.resolvedHost, let currentUsername = glab.currentUsername,
              host == currentHost, username == currentUsername, accountRevision == glab.accountRevision else { return [] }
        return visibleTodos
    }

    @discardableResult func beginRefresh() -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        return true
    }

    func finishRefresh() {
        isLoading = false
        acknowledgedDuringFetch.removeAll()
        lastRefresh = Date()
    }

    /// A stale response must not replace the inbox after any account-epoch transition.
    func fetch() async -> Fetch? {
        guard !Task.isCancelled else { return nil }
        let username = glab.currentUsername
        let host = username == nil ? nil : glab.resolvedHost
        let revision = glab.accountRevision
        let result = await glab.fetchTodos(host: host)
        guard !Task.isCancelled, glab.accountRevision == revision, glab.currentUsername == username,
              username == nil || glab.resolvedHost == host else { return nil }
        return Fetch(host: host, username: username, revision: revision,
            result: result.map { fetched in fetched.filter { !acknowledgedDuringFetch.contains($0.id) } })
    }

    func bindAccount(host: String?, username: String?, revision: UInt64) {
        self.host = host
        self.username = username
        accountRevision = revision
    }

    func accept(_ todos: [Todo]) {
        allTodos = todos
        lastError = nil
        hasCompletedFirstFetch = true
    }

    func acknowledge(_ ids: Set<Int>) {
        allTodos.removeAll { ids.contains($0.id) }
        acknowledgedDuringFetch.formUnion(ids)
    }

    func markDone(_ todo: Todo, automatically: Bool) async {
        guard optimisticallyDone.insert(todo.id).inserted else { return }
        await performMarkDone(todo, automatically: automatically)
    }

    /// Preserve the current pending action before replacing the single undo slot.
    func markDoneWithUndo(_ todo: Todo) {
        commitPendingMarkDone()
        guard optimisticallyDone.insert(todo.id).inserted else { return }
        undoableTodo = todo
        pendingMarkDoneTask = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.commitPendingMarkDone()
        }
    }

    func undoMarkDone() {
        guard let todo = undoableTodo else { return }
        pendingMarkDoneTask?.cancel()
        pendingMarkDoneTask = nil
        undoableTodo = nil
        optimisticallyDone.remove(todo.id)
    }

    private func commitPendingMarkDone() {
        guard let todo = undoableTodo else { return }
        pendingMarkDoneTask?.cancel()
        pendingMarkDoneTask = nil
        undoableTodo = nil
        Task { await performMarkDone(todo, automatically: false) }
    }

    private func performMarkDone(_ todo: Todo, automatically: Bool) async {
        guard !automatically || settings.automaticPublicWritesAllowed else {
            optimisticallyDone.remove(todo.id)
            return
        }
        let host = self.host
        let username = glab.currentUsername
        let revision = glab.accountRevision
        let result = await glab.markAsDone(id: todo.id, host: host) {
            !Task.isCancelled && self.host == host && self.username == username
                && self.glab.currentUsername == username && self.accountRevision == revision
                && self.glab.accountRevision == revision && (!automatically || self.settings.automaticPublicWritesAllowed)
        }
        optimisticallyDone.remove(todo.id)
        guard self.host == host, glab.currentUsername == username else { return }
        switch result {
        case .success:
            if isLoading { acknowledgedDuringFetch.insert(todo.id) }
            allTodos.removeAll { $0.id == todo.id }
            onAcknowledged?(todo.id)
            settings.lastSeenTodoIDs.remove(todo.id)
            if let host, let username {
                settings.pendingTodoAcknowledgements.remove(.init(host: host, username: username, todo: todo.feedbackIdentity))
            }
            settings.save()
        case .failure(let error):
            lastError = error
            Log.monitor.error("Mark-as-done failed for \(todo.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

import Foundation

/// Stores only numeric usage receipts. Recent IDs deduplicate completion callbacks;
/// older receipts become small hourly UTC totals, retaining their pricing snapshot.
actor AssistantUsageStore {
    static let didChange = Notification.Name("MergeTetherAssistantUsageDidChange")
    static let shared: AssistantUsageStore = {
        // Direct Xcode runs must not add synthetic CLI receipts to a running installation.
        let testing = Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let file = testing
            ? FileManager.default.temporaryDirectory.appending(path: "MergeTether-UsageTests-\(UUID())/usage.json")
            : URL.homeDirectory.appending(path: "Library/Application Support/com.vaporpw.GitLabTodos/Assistant Usage/usage.json")
        return AssistantUsageStore(file: file)
    }()
    let file: URL
    private var cached: State?
    private var writeFailed = false
    private let receiptLimit: Int

    private struct State: Codable {
        var version = 1
        var startedAt: Date?
        var receipts: [AssistantUsageReceipt] = []
        var archived: [AssistantUsageBucket] = []
    }
    enum StoreError: Error { case unsupportedVersion, writeFailed }

    init(file: URL, receiptLimit: Int = 4096) {
        self.file = file
        self.receiptLimit = max(1, receiptLimit)
    }

    func begin(id: UUID, role: AssistantUsageRole, assistant: AutomationAssistant, date: Date) throws {
        var state = try load()
        guard !state.receipts.contains(where: { $0.id == id }) else { return }
        state.startedAt = min(state.startedAt ?? date, date)
        state.receipts.append(.init(id: id, date: date, role: role, assistant: assistant))
        compact(&state)
        try save(state)
    }

    func finish(id: UUID, measurement: AssistantUsageMeasurement, complete: Bool) throws {
        var state = try load()
        guard let index = state.receipts.firstIndex(where: { $0.id == id }), !state.receipts[index].finished else { return }
        state.receipts[index].measurement = measurement
        state.receipts[index].complete = complete
        state.receipts[index].finished = true
        try save(state)
    }

    func discard(id: UUID) throws {
        var state = try load()
        let removed = state.receipts.first { $0.id == id }
        state.receipts.removeAll { $0.id == id }
        if state.archived.isEmpty, removed?.date == state.startedAt {
            state.startedAt = state.receipts.map(\.date).min()
        }
        try save(state)
    }

    func snapshot() throws -> AssistantUsageSnapshot {
        guard !writeFailed else { throw StoreError.writeFailed }
        let state = try load()
        let entries = state.archived.map {
            AssistantUsageEntry(date: $0.hour, role: $0.role, assistant: $0.assistant, total: $0.total)
        } + state.receipts.map {
            AssistantUsageEntry(date: $0.date, role: $0.role, assistant: $0.assistant, total: $0.total)
        }
        return .init(startedAt: state.startedAt, entries: entries)
    }

    private func load() throws -> State {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: file.path) else { return State() }
        var state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        guard state.version == 1 else { throw StoreError.unsupportedVersion }
        // A new store belongs to a new app lifetime. Its previous unfinished
        // processes cannot report completion, but their unknown usage must survive.
        for index in state.receipts.indices where !state.receipts[index].finished {
            state.receipts[index].finished = true
            state.receipts[index].complete = false
        }
        cached = state
        return state
    }

    private func save(_ state: State) throws {
        // Keep failed writes in memory so a later successful write includes
        // every observed run, rather than silently erasing an accounting gap.
        cached = state
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            writeFailed = false
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        } catch {
            writeFailed = true
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            throw error
        }
    }

    private func compact(_ state: inout State) {
        while state.receipts.count > receiptLimit {
            // Live work is never compacted before its completion callback can arrive.
            guard let index = state.receipts.firstIndex(where: \.finished) else { return }
            let receipt = state.receipts.remove(at: index)
            let hour = AssistantUsageCalendar.utc.dateInterval(of: .hour, for: receipt.date)?.start ?? receipt.date
            let version = receipt.measurement?.pricingVersion
            if let bucket = state.archived.firstIndex(where: {
                $0.hour == hour && $0.role == receipt.role && $0.assistant == receipt.assistant && $0.pricingVersion == version
            }) {
                state.archived[bucket].total.add(receipt.total)
            } else {
                state.archived.append(.init(hour: hour, role: receipt.role, assistant: receipt.assistant,
                    pricingVersion: version, total: receipt.total))
            }
        }
    }
}

fileprivate struct AssistantUsageReceipt: Codable, Sendable {
    let id: UUID
    let date: Date
    let role: AssistantUsageRole
    let assistant: AutomationAssistant
    var measurement: AssistantUsageMeasurement?
    var finished = false
    var complete = false

    var total: AssistantUsageTotal {
        .init(runs: 1, estimatedUSD: measurement?.estimatedUSD ?? 0,
            unknownCostRuns: complete && measurement?.estimatedUSD != nil ? 0 : 1,
            inputTokens: measurement?.tokens?.input ?? 0,
            cachedInputTokens: measurement?.tokens?.cachedInput ?? 0, outputTokens: measurement?.tokens?.output ?? 0,
            tokensUnavailable: measurement?.tokens == nil ? true : nil)
    }
}

fileprivate struct AssistantUsageBucket: Codable, Sendable {
    let hour: Date
    let role: AssistantUsageRole
    let assistant: AutomationAssistant
    let pricingVersion: String?
    var total: AssistantUsageTotal
}

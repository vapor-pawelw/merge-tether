import Foundation
import Observation
#if os(iOS)
import MetricKit
#endif

@MainActor @Observable
final class CrashReporting {
    static let shared = CrashReporting(
        destination: (Bundle.main.object(forInfoDictionaryKey: "MergeTetherCrashDSN") as? String)
            .flatMap(CrashReportingDestination.init),
        defaults: .standard,
        bundle: .main
    )

    private let destination: CrashReportingDestination?
    private let store: CrashConsentStore
    private let bundle: Bundle
    private var decision: CrashReportingDecision?
    @ObservationIgnored private var collection: Task<Void, Never>?
    #if os(iOS)
    @ObservationIgnored private var subscriber: CrashMetricSubscriber?
    #endif
    @ObservationIgnored private var uploader: CrashUpload?
    @ObservationIgnored private var uploads: [String: Task<Void, Never>] = [:]

    var isAvailable: Bool { destination != nil }
    var isEnabled: Bool { decision?.authorization != nil }
    var needsConsent: Bool { isAvailable && decision == nil }

    init(destination: CrashReportingDestination?, defaults: UserDefaults, bundle: Bundle) {
        let store = CrashConsentStore(defaults: defaults)
        self.destination = destination
        self.store = store
        self.bundle = bundle
        decision = destination.flatMap { store.decision(for: $0) }
    }

    func setEnabled(_ enabled: Bool) {
        guard let destination else { return }
        decision = store.setEnabled(enabled, for: destination, at: .now)
        if enabled {
            startIfAllowed()
        } else {
            stop()
        }
    }

    func startIfAllowed() {
        guard let authorization = decision?.authorization, let destination, uploader == nil else { return }
        uploader = CrashUpload(destination: destination)

        let executable = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? ""
        #if os(macOS)
        let source = MacCrashReportSource(executable: executable, bundleIdentifier: bundle.bundleIdentifier ?? "")
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
        collection = Task.detached(priority: .utility) { [weak self] in
            let start = max(authorization.startsAt, Date.now.addingTimeInterval(-30 * 24 * 60 * 60))
            await self?.submit(source.recentReports(in: directory, startingAt: start), under: authorization)
            // ReportCrash can finish writing after the user has already relaunched the app.
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            await self?.submit(source.recentReports(in: directory, startingAt: start), under: authorization)
        }
        #else
        let subscriber = CrashMetricSubscriber(authorization: authorization, executable: executable) { [weak self] reports in
            Task { @MainActor in self?.submit(reports, under: authorization) }
        }
        self.subscriber = subscriber
        MXMetricManager.shared.add(subscriber)
        // MetricKit may keep earlier diagnostics for delivery after a restart or an offline launch.
        collection = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return }
            subscriber.didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
        }
        #endif
    }

    private func stop() {
        collection?.cancel()
        collection = nil
        #if os(iOS)
        if let subscriber { MXMetricManager.shared.remove(subscriber) }
        subscriber = nil
        #endif
        for task in uploads.values { task.cancel() }
        uploads.removeAll()
        uploader?.cancel()
        uploader = nil
    }

    private func submit(_ reports: [CrashReport], under authorization: CrashReportingAuthorization) {
        guard decision?.authorization == authorization, let uploader else { return }
        for report in reports {
            guard uploads.count < 10 else { return }
            guard let envelope = try? report.envelope(installationID: authorization.installationID),
                  uploads[envelope.id] == nil, !store.wasSent(envelope.id, under: authorization) else { continue }
            uploads[envelope.id] = Task {
                let sent = await uploader.send(envelope)
                guard !Task.isCancelled, decision?.authorization == authorization else { return }
                uploads.removeValue(forKey: envelope.id)
                if sent { store.markSent(envelope.id, under: authorization) }
            }
        }
    }
}

#if os(iOS)
private final class CrashMetricSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    let authorization: CrashReportingAuthorization
    let executable: String
    let receive: @Sendable ([CrashReport]) -> Void

    init(authorization: CrashReportingAuthorization, executable: String, receive: @escaping @Sendable ([CrashReport]) -> Void) {
        self.authorization = authorization
        self.executable = executable
        self.receive = receive
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var reports: [CrashReport] = []
        for payload in payloads.sorted(by: { $0.timeStampBegin > $1.timeStampBegin }) {
            guard authorization.allowsReport(startingAt: payload.timeStampBegin) else { break }
            for diagnostic in payload.crashDiagnostics ?? [] {
                guard reports.count < 20 else { break }
                if let report = CrashReport(timestamp: payload.timeStampBegin, applicationVersion: diagnostic.applicationVersion,
                    build: diagnostic.metaData.applicationBuildVersion, systemVersion: diagnostic.metaData.osVersion,
                    signal: diagnostic.signal?.intValue, exception: diagnostic.exceptionType?.intValue,
                    callStack: diagnostic.callStackTree.jsonRepresentation(), executable: executable) {
                    reports.append(report)
                }
            }
        }
        if !reports.isEmpty { receive(reports) }
    }
}
#endif

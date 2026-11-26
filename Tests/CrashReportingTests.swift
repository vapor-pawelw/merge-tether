import Foundation
import Testing
@testable import MergeTether

@Suite struct CrashReportingTests {
    private let dsn = "https://0123456789abcdef0123456789abcdef@o1.ingest.de.sentry.io/42"

    @Test func consentIsPerDestinationAndTheIdentifierIsRemovedOnWithdrawal() throws {
        let name = "CrashReportingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let destination = try #require(CrashReportingDestination(dsn))
        let another = try #require(CrashReportingDestination(dsn.replacingOccurrences(of: "/42", with: "/43")))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CrashConsentStore(defaults: defaults)

        #expect(store.decision(for: destination) == nil)
        #expect(store.setEnabled(false, for: destination, at: date) == .declined)
        let allowed = store.setEnabled(true, for: destination, at: date)
        let authorization = try #require(allowed.authorization)
        let restarted = CrashConsentStore(defaults: defaults)
        #expect(restarted.decision(for: destination) == allowed)
        #expect(restarted.decision(for: another) == nil)
        #expect(!authorization.allowsReport(startingAt: date.addingTimeInterval(-1)))
        #expect(authorization.allowsReport(startingAt: date))

        restarted.markSent("first-report", under: authorization)
        #expect(store.wasSent("first-report", under: authorization))
        _ = restarted.setEnabled(false, for: destination, at: date)
        #expect(store.decision(for: destination) == .declined)
        #expect(!store.wasSent("first-report", under: authorization))
        #expect(store.setEnabled(true, for: destination, at: date).authorization?.installationID != authorization.installationID)
    }

    @Test func destinationAcceptsOnlySentryCloudIngestion() throws {
        let destination = try #require(CrashReportingDestination(dsn))
        #expect(destination.endpoint.absoluteString == "https://o1.ingest.de.sentry.io/api/42/envelope/")
        for invalid in [dsn + "?secret=token", dsn.replacingOccurrences(of: "https:", with: "http:"),
                        dsn.replacingOccurrences(of: "@", with: ":secret@"),
                        dsn.replacingOccurrences(of: "sentry.io", with: "sentry.io.invalid"),
                        dsn.replacingOccurrences(of: "/42", with: "/42/other"),
                        dsn.replacingOccurrences(of: "@", with: "%40@"),
                        "https://token@private-host.invalid/42"] {
            #expect(CrashReportingDestination(invalid) == nil)
        }
    }

    @Test func envelopeContainsOnlyTheCrashingAppFramesAndApprovedMetadata() throws {
        let stack = Data(#"""
        {"callStackPerThread":true,"callStacks":[
          {"threadAttributed":false,"callStackRootFrames":[{"binaryName":"MergeTether","address":99999,"offsetIntoBinaryTextSegment":10,"binaryUUID":"df197270-5844-413b-aee1-df2f3a6afd61"}]},
          {"threadAttributed":true,"callStackRootFrames":[{"binaryName":"/Users/example/private/Injected.dylib","address":77777,"offsetIntoBinaryTextSegment":10,"binaryUUID":"df197270-5844-413b-aee1-df2f3a6afd61","subFrames":[
            {"binaryName":"MergeTether","address":4100,"offsetIntoBinaryTextSegment":4,"binaryUUID":"4bc4e162-9c5d-4803-bc43-e5bf751ad150","symbol":"glpat-secret","subFrames":[
              {"binaryName":"MergeTether","address":4200,"offsetIntoBinaryTextSegment":104,"binaryUUID":"4bc4e162-9c5d-4803-bc43-e5bf751ad150"}
            ]}
          ]}]}
        ],"extra":{"request":"https://gitlab.private.invalid","user":"private-user"}}
        """#.utf8)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let identifier = UUID()
        let report = try #require(CrashReport(timestamp: timestamp, applicationVersion: "2.0.0", build: "7",
            systemVersion: "macOS 26.3 (25D125)", signal: 5, exception: 6,
            callStack: stack, executable: "MergeTether"))
        let envelope = try report.envelope(installationID: identifier)
        let sameReport = try report.envelope(installationID: identifier)
        #expect(envelope.id == sameReport.id)
        #expect(envelope.id.wholeMatch(of: /[a-f0-9]{12}4[a-f0-9]{3}[89ab][a-f0-9]{15}/) != nil)
        let lines = String(decoding: envelope.body, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 3)
        let item = try #require(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect(item["length"] as? Int == lines[2].utf8.count)
        let body = String(lines[2])
        for value in ["0x1000", "0x1004", "0x1068", "2.0.0", "26.3", "SIGTRAP", identifier.uuidString.lowercased()] {
            #expect(body.contains(value))
        }
        for privateValue in ["/Users", "Injected", "gitlab", "glpat", "private-user", "0x1869f", "0x12fd1", "25D125"] {
            #expect(!body.contains(privateValue))
        }
    }

    @Test func macCrashReportRequiresMatchingIdentityAndConsentAtTheTimeOfTheCrash() throws {
        let data = Data(#"""
        {"bug_type":"309","bundleID":"com.vaporpw.MergeTether","app_version":"2.0.0","build_version":"7","os_version":"macOS 26.3 (25D125)"}
        {"captureTime":"2026-11-26 12:09:53.7852 +0100","procName":"MergeTether","procPath":"/Users/example/workspace/MergeTether.app/Contents/MacOS/MergeTether",
        "bundleInfo":{"CFBundleIdentifier":"com.vaporpw.MergeTether"},"faultingThread":0,
        "exception":{"signal":"SIGTRAP","reason":"glpat-secret"},
        "threads":[{"frames":[{"imageIndex":1,"imageOffset":104,"symbol":"privateFunction"},{"imageIndex":0,"imageOffset":4}]}],
        "usedImages":[
          {"name":"MergeTether","path":"/Users/example/workspace/MergeTether.app/Contents/MacOS/MergeTether","base":4096,"size":256,"uuid":"4bc4e162-9c5d-4803-bc43-e5bf751ad150"},
          {"name":"Injected","path":"/Users/example/private.dylib","base":77777,"size":256,"uuid":"df197270-5844-413b-aee1-df2f3a6afd61"}
        ]}
        """#.utf8)
        let source = MacCrashReportSource(executable: "MergeTether", bundleIdentifier: "com.vaporpw.MergeTether")
        let after = Date(timeIntervalSince1970: 1_795_691_400)
        let before = after.addingTimeInterval(-100)
        #expect(source.report(in: data, startingAt: after) == nil)
        #expect(MacCrashReportSource(executable: "MergeTether", bundleIdentifier: "com.example.not-us")
            .report(in: data, startingAt: before) == nil)
        let crash = try #require(source.report(in: data, startingAt: before))
        let body = String(decoding: try crash.envelope(installationID: UUID()).body, as: UTF8.self)
        #expect(body.contains("0x1004"))
        #expect(body.contains("SIGTRAP"))
        #expect(body.contains("macos_crash_report"))
        for privateValue in ["/Users", "Injected", "glpat", "privateFunction", "0x12fd1", "25D125"] {
            #expect(!body.contains(privateValue))
        }
    }

    @Test func macCrashReportUsesExecutableUUIDWhenTheSystemRecordsDifferentPaths() throws {
        let data = Data(#"""
        {"bug_type":"309","bundleID":"com.vaporpw.MergeTether","app_version":"2.0.0","build_version":"7","os_version":"macOS 26.3","slice_uuid":"4bc4e162-9c5d-4803-bc43-e5bf751ad150"}
        {"captureTime":"2026-11-26 12:09:53.7852 +0100","procName":"MergeTether","procPath":"/tmp/*/MergeTether.app/Contents/MacOS/MergeTether",
        "bundleInfo":{"CFBundleIdentifier":"com.vaporpw.MergeTether"},"faultingThread":0,
        "threads":[{"frames":[{"imageIndex":0,"imageOffset":4},{"imageIndex":1,"imageOffset":4}]}],
        "usedImages":[
          {"name":"MergeTether","path":"/private/tmp/*/MergeTether.app/Contents/MacOS/MergeTether","base":4096,"size":256,"uuid":"4bc4e162-9c5d-4803-bc43-e5bf751ad150"},
          {"name":"MergeTether","path":"/tmp/*/MergeTether.app/Contents/MacOS/MergeTether","base":8192,"size":256,"uuid":"df197270-5844-413b-aee1-df2f3a6afd61"}
        ]}
        """#.utf8)
        let source = MacCrashReportSource(executable: "MergeTether", bundleIdentifier: "com.vaporpw.MergeTether")
        let report = try #require(source.report(in: data, startingAt: Date(timeIntervalSince1970: 1_795_691_300)))
        let body = String(decoding: try report.envelope(installationID: UUID()).body, as: UTF8.self)
        #expect(body.contains("0x1004"))
        #expect(!body.contains("0x2004"))
        #expect(!body.contains("/tmp/"))
    }
}

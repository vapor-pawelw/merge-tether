import AppKit
import Darwin

func runningApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { app in
        app.activationPolicy == .regular &&
            app.executableURL.map { executableNames.contains($0.lastPathComponent) } == true &&
            app.bundleURL?.pathExtension == "app"
    }
}

func wait(seconds: Double, until ready: () -> Bool) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    repeat {
        if ready() { return true }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    } while ProcessInfo.processInfo.systemUptime < deadline
    return ready()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else { fail("expected quit|launch, app path and executable name") }
let appURL = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
let executableNames = Set(["GitLabTodos", CommandLine.arguments[3]])

switch CommandLine.arguments[1] {
case "quit":
    let apps = runningApps()
    for app in apps {
        print("Quitting PID \(app.processIdentifier) at \(app.bundleURL?.path ?? "?")...")
        app.terminate()
    }
    if !wait(seconds: 15, until: { apps.allSatisfy(\.isTerminated) }) {
        for app in apps where !app.isTerminated {
            print("Force quitting PID \(app.processIdentifier)...")
            app.forceTerminate()
        }
        guard wait(seconds: 5, until: { apps.allSatisfy(\.isTerminated) }) else {
            fail("MergeTether is still running")
        }
    }
case "launch":
    guard runningApps().isEmpty else { fail("another MergeTether instance started during rebuild") }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [appURL.path]
    try open.run()
    open.waitUntilExit()
    guard open.terminationStatus == 0 else { fail("Launch Services could not open \(appURL.path)") }
    var launched: NSRunningApplication?
    guard wait(seconds: 15, until: {
        launched = runningApps().first {
            $0.isFinishedLaunching && $0.bundleURL?.resolvingSymlinksInPath().path == appURL.path
        }
        return launched != nil
    }), let launched else {
        fail("no running app found at \(appURL.path)")
    }
    guard !wait(seconds: 1, until: { launched.isTerminated }) else {
        fail("MergeTether exited immediately after launch")
    }
    print("Running PID \(launched.processIdentifier)")
default:
    fail("expected quit or launch")
}

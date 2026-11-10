import Foundation

enum OnboardingDetector {
    static let defaultCandidates: [String] = [
        "/opt/homebrew/bin/glab",
        "/usr/local/bin/glab",
        "/opt/local/bin/glab",
        "/usr/bin/glab",
    ]

    /// Probes the well-known install locations first, then falls back to a
    /// login-interactive shell so PATH entries from zprofile/zshrc apply.
    static func findGlabExecutable() async -> URL? {
        #if DEBUG
        guard ApplicationLaunchMode.resolve(environment: ProcessInfo.processInfo.environment) == .application else { return nil }
        #endif
        for path in defaultCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let shell = URL(fileURLWithPath: "/bin/zsh")
        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(
                shell,
                arguments: ["-lic", "command -v glab"],
                environment: minimalShellEnvironment,
                timeout: 5
            )
        } catch {
            return nil
        }
        guard output.exitCode == 0 else { return nil }
        let trimmed = String(data: output.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        guard FileManager.default.isExecutableFile(atPath: trimmed) else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    private static var minimalShellEnvironment: [String: String] {
        var env: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
        ]
        for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "XDG_CONFIG_HOME", "GLAB_CONFIG_DIR"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                env[key] = value
            }
        }
        return env
    }
}

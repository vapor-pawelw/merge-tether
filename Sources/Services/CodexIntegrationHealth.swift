import Foundation

/// Compatibility state only: executable work uses CLI health, never a desktop listener.
struct CodexIntegrationHealth {
    let listenerHealth: CodexDesktopRelay.ListenerHealth = .off
    let pluginInstallation: CodexPluginInstaller.Installation? = nil
    var listenerWarning: LocalizedStringResource? { nil }

    func checkListener(force: Bool = false, now: Date = Date()) {}
}

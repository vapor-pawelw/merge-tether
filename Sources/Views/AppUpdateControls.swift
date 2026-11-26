import AppKit
import SwiftUI

struct CheckForAppUpdatesButton: View {
    let updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
            if !AppUpdateControls.hasUpdateInProgress(updater.presentation.phase) { updater.check() }
        } label: {
            switch updater.presentation.phase {
            case .available(let version): Text(.AppUpdates.appUpdateAvailable(version))
            case .ready(let version), .waitingToRestart(let version): Text(.AppUpdates.appUpdateReady(version))
            case .downloading, .preparing, .restarting: Text(.AppUpdates.appUpdateSectionTitle)
            default: Text(.AppUpdates.appUpdateCheck)
            }
        }
    }
}

struct AppUpdateControls: View {
    let updater: AppUpdater
    var inToolbar = false

    static func hasUpdateInProgress(_ phase: AppUpdatePresentation.Phase) -> Bool {
        switch phase {
        case .checking, .available, .downloading, .preparing, .ready, .waitingToRestart, .restarting: true
        default: false
        }
    }

    static func showsInToolbar(_ phase: AppUpdatePresentation.Phase) -> Bool { phase != .idle }

    var body: some View {
        switch updater.presentation.phase {
        case .idle:
            Button(.AppUpdates.appUpdateCheck, action: updater.check)
        case .checking:
            progress(.AppUpdates.appUpdateChecking)
        case .available(let version):
            if inToolbar {
                primary(.AppUpdates.appUpdateToVersion(version), icon: "arrow.down.circle.fill", action: updater.presentation.download)
                    .help(Text(.AppUpdates.appUpdateAvailable(version)))
            } else {
                status(.AppUpdates.appUpdateAvailable(version)) {
                    primary(.AppUpdates.appUpdateDownload, icon: "arrow.down.circle.fill", action: updater.presentation.download)
                }
            }
        case .downloading(let fraction):
            progress(.AppUpdates.appUpdateDownloading, fraction: fraction)
        case .preparing(let fraction):
            progress(.AppUpdates.appUpdatePreparing, fraction: fraction)
        case .ready(let version):
            if inToolbar {
                primary(.AppUpdates.appUpdateRestart, icon: "arrow.clockwise.circle.fill", action: updater.restart)
                    .help(Text(.AppUpdates.appUpdateReady(version)))
            } else {
                status(.AppUpdates.appUpdateReady(version)) {
                    primary(.AppUpdates.appUpdateRestart, icon: "arrow.clockwise.circle.fill", action: updater.restart)
                }
            }
        case .waitingToRestart:
            status(.AppUpdates.appUpdateWaiting) {
                if inToolbar {
                    Button(action: updater.cancelWaitingForRestart) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text(.AppUpdates.appUpdateCancelRestart))
                    .help(Text(.AppUpdates.appUpdateCancelRestart))
                } else {
                    Button(.AppUpdates.appUpdateCancelRestart, action: updater.cancelWaitingForRestart)
                }
            }
        case .restarting:
            progress(.AppUpdates.appUpdateRestarting)
        case .current:
            result(.AppUpdates.appUpdateUpToDate)
        case .unavailable:
            result(.AppUpdates.appUpdateUnavailable)
        case .failed:
            result(.AppUpdates.appUpdateFailed, retry: true)
        }
    }

    private func primary(_ title: LocalizedStringResource, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label { Text(title) } icon: { Image(systemName: icon) } }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
    }

    private func progress(_ title: LocalizedStringResource, fraction: Double? = nil) -> some View {
        status(title) {
            Group {
                if let fraction {
                    ProgressView(value: fraction).frame(width: inToolbar ? 44 : 100)
                } else {
                    ProgressView()
                }
            }
            .controlSize(.small)
            .accessibilityLabel(Text(title))
        }
    }

    private func status<Accessory: View>(_ title: LocalizedStringResource,
                                          @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(inToolbar ? 1 : nil)
            if !inToolbar { Spacer() }
            accessory()
        }
    }

    private func result(_ title: LocalizedStringResource, retry: Bool = false) -> some View {
        status(title) {
            if retry || !inToolbar {
                Button(retry ? .AppUpdates.appUpdateRetry : .AppUpdates.appUpdateCheck, action: updater.check)
            }
            if inToolbar {
                Button(action: updater.presentation.clearResult) { Image(systemName: "xmark") }
                    .accessibilityLabel(Text(.AppUpdates.appUpdateDismissStatus))
                    .help(Text(.AppUpdates.appUpdateDismissStatus))
            }
        }
    }
}

import SwiftUI

/// A call-to-action label with the selected provider for AI work.
struct MRActionLabel: View {
    let title: LocalizedStringResource
    let cta: MRActionCTA
    var fallbackSymbol: String? = nil
    var working = false

    var body: some View {
        MRActionProgressLabel(working: working) {
            if cta.requiresCodingAssistant {
                Label { Text(title).lineLimit(1) } icon: {
                    CodingProviderIcon().help(cta.help)
                }
            } else if let symbol = cta.symbol ?? fallbackSymbol {
                Label { Text(title).lineLimit(1) } icon: {
                    Image(systemName: symbol).help(cta.help)
                }
            } else {
                Text(title).lineLimit(1)
            }
        }
    }
}

struct MRActionProgressLabel<Title: View>: View {
    let working: Bool
    var workingTitle: LocalizedStringResource = .Remote.remoteRunning
    @ViewBuilder var title: () -> Title

    var body: some View {
        ZStack {
            title().opacity(working ? 0 : 1).accessibilityHidden(working)
            if working {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                    Text(workingTitle)
                }
            }
        }
    }
}

/// Identifies the AI work shown in a status or job history.
struct MRActionEffectIcon: View {
    let effect: MRActionEffect
    var assistant: AutomationAssistant? = nil

    var body: some View {
        if effect == .agent || effect == .aiCheck {
            CodingProviderIcon(provider: assistant?.glyph).foregroundStyle(.secondary)
                .help(Text(effect.kindDescription))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(effect.kindDescription))
        }
    }
}

extension AutomationAssistant {
    var glyph: CodingProviderGlyph {
        switch self {
        case .codex: .codex
        case .claude: .claude
        }
    }
}

extension View {
    /// Explains on hover, and to VoiceOver, exactly what the action runs.
    /// `detail` keeps a call site's narrower explanation after the shared one.
    func mrActionHelp(_ cta: MRActionCTA?, detail: LocalizedStringResource? = nil) -> some View {
        let help = [cta?.help, detail.map { String(localized: $0) }].compactMap { $0 }.joined(separator: "\n")
        return self.help(help).accessibilityHint(help)
    }
}

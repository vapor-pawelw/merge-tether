import SwiftUI

/// A call-to-action label whose icon shows the action's effect: sparkles for AI
/// work, a bolt when automation resumes, otherwise the caller's own icon.
struct MRActionLabel: View {
    let title: LocalizedStringResource
    let cta: MRActionCTA
    var fallbackSymbol: String? = nil
    var working = false

    var body: some View {
        if let symbol = cta.symbol ?? fallbackSymbol {
            Label { Text(title).lineLimit(1) } icon: {
                HStack(spacing: 4) {
                    if working { ProgressView().controlSize(.mini) }
                    if !working || cta.effect.symbol != nil { Image(systemName: symbol) }
                }
            }
        } else if working {
            ProgressView().controlSize(.mini)
        } else {
            Text(title).lineLimit(1)
        }
    }
}

/// The same AI marker next to Settings that start agents or AI checks.
struct MRActionEffectIcon: View {
    let effect: MRActionEffect

    var body: some View {
        if let symbol = effect.symbol {
            Image(systemName: symbol).foregroundStyle(.secondary)
                .help(Text(effect.kindDescription))
                .accessibilityLabel(Text(effect.kindDescription))
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

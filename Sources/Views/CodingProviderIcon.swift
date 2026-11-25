import SwiftUI

enum CodingProviderGlyph: String, CaseIterable, Sendable {
    case codex, claude

    var assetName: String {
        switch self {
        case .codex: "ChatGPTGlyph"
        case .claude: "ClaudeGlyph"
        }
    }
}

private struct CodingProviderGlyphKey: EnvironmentKey {
    static let defaultValue: CodingProviderGlyph? = nil
}

extension EnvironmentValues {
    var codingProviderGlyph: CodingProviderGlyph? {
        get { self[CodingProviderGlyphKey.self] }
        set { self[CodingProviderGlyphKey.self] = newValue }
    }
}

struct CodingProviderIcon: View {
    @Environment(\.codingProviderGlyph) private var selectedProvider
    @ScaledMetric(relativeTo: .body) private var size = 12.0
    var provider: CodingProviderGlyph? = nil

    var body: some View {
        Group {
            if let glyph = provider ?? selectedProvider {
                Image(glyph.assetName)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "sparkles").font(.system(size: size))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

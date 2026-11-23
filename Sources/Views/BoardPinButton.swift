import SwiftUI

struct BoardPinButton: View {
    enum Placement { case header, menu }

    let pin: BoardCardPin?
    let settings: SettingsManager
    var placement: Placement = .header

    private var isPinned: Bool { pin.map { settings.boardPins.contains($0) } ?? false }
    private var title: LocalizedStringResource { isPinned ? .Board.boardUnpin : .Board.boardPin }
    private var symbol: String { isPinned ? "pin.fill" : "pin" }

    var body: some View {
        switch placement {
        case .header:
            Button(action: toggle) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .boardHeaderControlHover()
            .help(Text(title))
            .accessibilityLabel(Text(title))
            .disabled(pin == nil)
        case .menu:
            Button(action: toggle) {
                Label { Text(title) } icon: { Image(systemName: symbol) }
            }
            .disabled(pin == nil)
        }
    }

    private func toggle() {
        guard let pin else { return }
        settings.setBoardPin(pin, pinned: !isPinned)
    }
}

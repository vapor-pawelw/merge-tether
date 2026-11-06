import SwiftUI

struct BoardPinButton: View {
    let pin: BoardCardPin?
    let settings: SettingsManager

    private var isPinned: Bool { pin.map { settings.boardPins.contains($0) } ?? false }
    private var title: LocalizedStringResource { isPinned ? .Board.boardUnpin : .Board.boardPin }

    var body: some View {
        Button {
            guard let pin else { return }
            if isPinned { settings.boardPins.remove(pin) } else { settings.boardPins.insert(pin) }
            settings.save()
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.caption)
                .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pin == nil)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}

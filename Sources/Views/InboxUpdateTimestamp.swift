import SwiftUI

struct InboxUpdateTimestamp: View {
    let date: Date
    @Environment(\.locale) private var locale
    @State private var showsFullDate = false

    var body: some View {
        Button {
            showsFullDate.toggle()
        } label: {
            Label {
                if showsFullDate {
                    Text(date, format: .dateTime.year().month().day().hour().minute().second())
                } else {
                    TimelineView(.periodic(from: date, by: 60)) { _ in
                        relativeTime(asOf: .now)
                    }
                }
            } icon: {
                Image(systemName: "clock").accessibilityHidden(true)
            }
            .fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            .frame(minHeight: 44)
            #endif
            .contentShape(Rectangle())
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityHint(Text(formatHint))
        #if os(macOS)
        .help(Text(formatHint))
        #endif
    }

    private var formatHint: LocalizedStringResource {
        showsFullDate ? .Board.boardInboxUpdateShowRelativeTime : .Board.boardInboxUpdateShowFullDate
    }

    private func relativeTime(asOf now: Date) -> Text {
        guard now.timeIntervalSince(date) >= 60 else {
            return Text(.Board.boardInboxUpdateJustNow)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        return Text(verbatim: formatter.localizedString(for: date, relativeTo: now))
    }
}

import SwiftUI

struct ApprovalBadgeColor: ShapeStyle {
    let received: Int
    let required: Int?
    let isSatisfied: Bool

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        if isSatisfied { return Color.green.resolve(in: environment) }
        guard let required, required > 0, received > 0 else {
            return Color.secondary.resolve(in: environment)
        }
        if received >= required { return Color.green.resolve(in: environment) }
        let isDark = environment.colorScheme == .dark
        let color: Color = if received < required - received {
            isDark ? Color(red: 0.83, green: 0.57, blue: 0.37) : Color(red: 0.59, green: 0.28, blue: 0.10)
        } else {
            isDark ? Color(red: 0.79, green: 0.70, blue: 0.32) : Color(red: 0.46, green: 0.38, blue: 0.04)
        }
        return color.resolve(in: environment)
    }
}

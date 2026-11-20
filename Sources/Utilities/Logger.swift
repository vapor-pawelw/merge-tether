import Foundation
import os

enum Log {
    static let glab = Logger(subsystem: subsystem, category: "glab")
    static let monitor = Logger(subsystem: subsystem, category: "monitor")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let avatars = Logger(subsystem: subsystem, category: "avatars")
    static let onboarding = Logger(subsystem: subsystem, category: "onboarding")
    static let update = Logger(subsystem: subsystem, category: "update")

    private static let subsystem = "com.vaporpw.MergeTether"
}

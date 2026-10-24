import Foundation
import UserNotifications

enum Notifier {
    /// UNUserNotificationCenter crashes outside an .app bundle (e.g. `swift run`).
    static var canUseNotificationCenter: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard canUseNotificationCenter else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(title: String, body: String) {
        guard canUseNotificationCenter else {
            let script = "display notification \(quoted(body)) with title \(quoted(title))"
            DispatchQueue.global(qos: .utility).async { _ = Shell.run("/usr/bin/osascript", ["-e", script]) }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

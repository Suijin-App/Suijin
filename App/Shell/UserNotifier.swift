import Foundation
import UserNotifications

/// Every notification Sevinda posts goes through here. In the test host nothing reaches Notification Center: the tests
/// run the real session code (exits, turns, orchestration) and must not fill the user's notifications. What would have
/// been posted is kept instead, so tests can check it.
@MainActor
final class UserNotifier {
    static let shared = UserNotifier()

    /// One notification as the user would read it.
    struct Message: Equatable {
        var identifier: String
        var title: String
        var body: String
    }

    /// Off in the test host.
    let postsToNotificationCenter: Bool
    /// What was not posted because posting is off, newest last (test host only).
    private(set) var withheld: [Message] = []

    init(postsToNotificationCenter: Bool = !UserNotifier.isTestHost) {
        self.postsToNotificationCenter = postsToNotificationCenter
    }

    nonisolated static var isTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    /// Asks once for permission to show alerts with sound; the system remembers the answer.
    func requestPermission() async {
        guard postsToNotificationCenter else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Posts (or replaces, with the same `identifier`) a notification that opens `session` when clicked.
    func post(identifier: String, title: String, body: String, session: UUID) {
        let message = Message(identifier: identifier, title: title, body: body)
        guard postsToNotificationCenter else {
            withheld.append(message)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["session": session.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// Forgets what was withheld (tests).
    func clearWithheld() {
        withheld.removeAll()
    }
}

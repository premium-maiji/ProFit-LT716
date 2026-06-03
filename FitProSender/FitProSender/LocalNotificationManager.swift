import Foundation
import UserNotifications

@MainActor
final class LocalNotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var status = "iOS notification not checked"

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func send(text: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else {
                    status = "iOS notifications not allowed"
                    return
                }

                let content = UNMutableNotificationContent()
                content.title = "FitPro Sender"
                content.body = text.isEmpty ? "TEST" : text
                content.sound = .default
                if #available(iOS 15.0, *) {
                    content.interruptionLevel = .timeSensitive
                }

                let request = UNNotificationRequest(
                    identifier: "fitpro-local-\(UUID().uuidString)",
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                )
                try await center.add(request)
                status = "iOS notification scheduled"
            } catch {
                status = "iOS notification failed: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

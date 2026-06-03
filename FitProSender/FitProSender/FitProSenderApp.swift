import SwiftUI

@main
struct FitProSenderApp: App {
    @StateObject private var ble = FitProBLEManager()
    @StateObject private var notifier = LocalNotificationManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .environmentObject(notifier)
        }
    }
}

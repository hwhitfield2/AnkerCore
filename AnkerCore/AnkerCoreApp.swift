import SwiftUI

@main
struct AnkerCoreApp: App {
    init() {
        ProcessingNotifications.shared.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

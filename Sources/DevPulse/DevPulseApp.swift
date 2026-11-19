import SwiftUI

@main
struct DevPulseApp: App {

    @State private var updates = UpdateService()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Auto-update: manual check next to About.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkNow() }
                    .disabled(!updates.canCheck)
            }
        }
    }
}

import AppKit
import SwiftUI
import DevPulseCore

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(DevPulseCore.greeting(appName: "DevPulse"))
                .font(.title)
            Text("Your GitHub PRs, Jira tickets and Claude Code sessions — live in the menu bar and the terminal.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 640, minHeight: 400)
    }
}

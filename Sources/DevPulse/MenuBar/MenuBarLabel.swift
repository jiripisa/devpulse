import SwiftUI

/// The status item: the pulse symbol, plus the attention count when something needs me.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "waveform.path.ecg")
            if model.attentionCount > 0 {
                Text("\(model.attentionCount)")
            }
        }
        // The label lives as long as the app, so it hands the Settings action to the model
        // (needed for the socket's `openSettings` before the popover was ever opened).
        .onAppear { model.showSettingsWindow = { openSettings() } }
    }
}

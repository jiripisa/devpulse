import SwiftUI

/// The status item: the pulse symbol.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: "waveform.path.ecg")
            // The label lives as long as the app, so it hands the Settings action to the model
            // (needed for the socket's `openSettings` before the popover was ever opened).
            .onAppear { model.settingsPresenter.setOpenAction { openSettings() } }
    }
}

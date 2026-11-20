import SwiftUI

/// The status item: the sonar glyph, a template image (18 pt PDF in `Assets.xcassets`), so the
/// menu bar tints it for light, dark and selected states.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            // The label lives as long as the app, so it hands the Settings action to the model
            // (needed for the socket's `openSettings` before the popover was ever opened).
            .onAppear { model.settingsPresenter.setOpenAction { openSettings() } }
    }
}

import CoreGraphics
import Testing
@testable import DevPulseCore

@Suite struct LauncherPlacementTests {
    @Test func aTallScreenKeepsThePanelAboveTheMiddle() {
        let visible = CGRect(x: 0, y: 0, width: 1728, height: 1080)
        let top = LauncherPlacement.top(in: visible, barHeight: 64, fullHeight: 604)
        // Its top edge sits above the middle, as Spotlight's does …
        #expect(top > visible.midY)
        // … and the grown panel still fits.
        #expect(top - 604 >= visible.minY)
    }

    @Test func aShortScreenMovesThePanelUpSoTheGrownPanelFits() {
        // A 13-inch laptop with the Dock at the bottom.
        let visible = CGRect(x: 0, y: 80, width: 1470, height: 830)
        let top = LauncherPlacement.top(in: visible, barHeight: 64, fullHeight: 604)
        #expect(top - 604 >= visible.minY + LauncherPlacement.margin)
        #expect(top <= visible.maxY)
    }

    @Test func aScreenTooShortForThePanelKeepsItsTopOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1024, height: 500)
        #expect(LauncherPlacement.top(in: visible, barHeight: 64, fullHeight: 604) == visible.maxY - LauncherPlacement.margin)
    }
}

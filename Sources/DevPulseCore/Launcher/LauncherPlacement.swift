import CoreGraphics

/// Where the launcher panel sits on a screen. It opens as the search bar alone and grows
/// downwards once results show, keeping its top edge, so the top is chosen for the grown panel:
/// above the middle like Spotlight's, but high enough that the whole panel stays above the
/// screen's bottom (and the Dock) on a short screen.
public enum LauncherPlacement {
    /// The gap kept to the visible area's edges.
    public static let margin: CGFloat = 12

    /// The top edge, in screen coordinates (y up), within `visible` (the screen's visible frame).
    public static func top(in visible: CGRect, barHeight: CGFloat, fullHeight: CGFloat) -> CGFloat {
        let preferred = visible.midY + visible.height * 0.15 + barHeight / 2
        let lowestThatFits = visible.minY + fullHeight + margin
        return min(max(preferred, lowestThatFits), visible.maxY - margin)
    }
}

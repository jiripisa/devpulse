import AppKit
import DevPulseCore
import SwiftUI

/// The "Lookout" design's colours and symbols: one identity per kind of item (Jira blue, PR
/// violet, review magenta, Claude cyan) on the left of a row, and the status, by shape, word and
/// tone, on the right. Every colour has a light and a dark value.
enum Lookout {
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1B232D)
    static let chrome = dynamic(light: 0xF4F6F8, dark: 0x242E3A)
    static let primary = dynamic(light: 0x18222D, dark: 0xEDF2F7)
    static let secondary = dynamic(light: 0x556372, dark: 0xA8B6C6)
    static let divider = dynamic(light: 0xDEE4EA, dark: 0x394656)
    static let interaction = dynamic(light: 0x087F72, dark: 0x79D3C3)
    static let selection = dynamic(light: 0xE1F2EE, dark: 0x203E3C)

    static let jira = dynamic(light: 0x2459C4, dark: 0x82ABFF)
    static let pullRequest = dynamic(light: 0x7045B5, dark: 0xC0A0FF)
    static let review = dynamic(light: 0xA83479, dark: 0xF19ACD)
    static let claude = dynamic(light: 0x087B87, dark: 0x70CCD6)

    static let success = dynamic(light: 0x237145, dark: 0x78D6A0)
    static let attention = dynamic(light: 0x855600, dark: 0xEFC478)
    static let failure = dynamic(light: 0xB3343A, dark: 0xFF9F9C)
    static let activity = dynamic(light: 0x2459C4, dark: 0x91B6FF)
    /// The amber marker and wash of a session that waits for input.
    static let attentionWash = dynamic(light: 0xFFF4E0, dark: 0x3A3020)

    static func tone(_ tone: StatusBadge.Tone) -> Color {
        switch tone {
        case .success: success
        case .attention: attention
        case .failure: failure
        case .activity: activity
        case .review: pullRequest
        case .secondary: secondary
        }
    }

    static func color(_ kind: LauncherItem.Kind) -> Color {
        switch kind {
        case .ticket: jira
        case .pullRequest: pullRequest
        case .reviewRequest: review
        case .session: claude
        }
    }

    static func symbol(_ kind: LauncherItem.Kind) -> String {
        switch kind {
        case .ticket: "ticket"
        case .pullRequest: "arrow.triangle.branch"
        case .reviewRequest(let direct): direct ? "person.crop.circle.badge.checkmark" : "person.2"
        case .session: "apple.terminal"
        }
    }

    static func symbol(_ glyph: StatusBadge.Glyph) -> String {
        switch glyph {
        case .check: "checkmark"
        case .cross: "xmark"
        case .clock: "clock"
        case .diamond: "diamond"
        case .exclamation: "exclamationmark.circle"
        case .halfCircle: "circle.lefthalf.filled"
        case .openCircle: "circle"
        case .checkCircle: "checkmark.circle"
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// A kind's icon in its identity colour, in a fixed slot so titles line up.
struct KindIcon: View {
    let kind: LauncherItem.Kind
    var size: CGFloat = 17

    var body: some View {
        Image(systemName: Lookout.symbol(kind))
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(Lookout.color(kind))
            .frame(width: 26)
            .accessibilityLabel(kind.label)
    }
}

/// A status: its shape and word in the tone's colour.
struct StatusBadgeView: View {
    let badge: StatusBadge
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: Lookout.symbol(badge.glyph)).font(.system(size: size - 1, weight: .semibold))
            Text(badge.text).font(.system(size: size)).lineLimit(1)
        }
        .foregroundStyle(Lookout.tone(badge.tone))
    }
}

/// The statuses of a row, stacked on its right.
struct BadgeStack: View {
    let badges: [StatusBadge]
    var size: CGFloat = 12

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                StatusBadgeView(badge: badge, size: size)
            }
        }
        .fixedSize()
    }
}

/// A key as printed on a key cap, for the launcher's key line.
struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Lookout.primary)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(Lookout.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Lookout.divider))
    }
}

/// The DevPulse mark: the menu bar's sonar glyph in the interaction colour, and the name.
struct BrandMark: View {
    var size: CGFloat = 17

    var body: some View {
        HStack(spacing: 8) {
            Image("MenuBarIcon").renderingMode(.template).resizable().scaledToFit()
                .frame(width: size + 7, height: size + 7)
                .foregroundStyle(Lookout.interaction)
            Text("DevPulse").font(.system(size: size, weight: .semibold)).foregroundStyle(Lookout.primary)
        }
        .accessibilityElement(children: .combine)
    }
}

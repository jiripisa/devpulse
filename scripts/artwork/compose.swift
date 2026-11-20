// Composes the website's hero (docs/assets/hero.png, 1600x1000) and social card
// (docs/assets/og-image.png, 1200x630) from the real screenshots in docs/assets/manual/ and the
// app icon. Run from the repository root after new screenshots: swift scripts/artwork/compose.swift
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255)/255, CGFloat((hex >> 8) & 255)/255, CGFloat(hex & 255)/255, alpha])!
}
func load(_ path: String) -> CGImage {
    let url = root.appendingPathComponent(path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fatalError("Cannot read \(path); run from the repository root") }
    return image
}
/// A top-left origin canvas, like the screenshots' own coordinates.
func canvas(_ width: Int, _ height: Int) -> CGContext {
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
    c.interpolationQuality = .high
    return c
}
func save(_ c: CGContext, _ path: String) {
    let image = c.makeImage()!
    let url = root.appendingPathComponent(path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil); precondition(CGImageDestinationFinalize(dest))
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("Saved \(path): \(image.width)x\(image.height), \(size / 1024) KB")
}

/// The calm backdrop: the icon's teal, dark, with a soft light at the top left.
func backdrop(_ c: CGContext, _ w: CGFloat, _ h: CGFloat) {
    let g = CGGradient(colorsSpace: cs, colors: [color(0x1B4D57), color(0x10282F), color(0x0B1A20)] as CFArray, locations: [0, 0.55, 1])!
    c.drawLinearGradient(g, start: .zero, end: CGPoint(x: w * 0.6, y: h), options: [.drawsAfterEndLocation])
    let glow = CGGradient(colorsSpace: cs, colors: [color(0x7FD3CF, 0.22), color(0x7FD3CF, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: CGPoint(x: w * 0.18, y: h * 0.05), startRadius: 0,
                         endCenter: CGPoint(x: w * 0.18, y: h * 0.05), endRadius: w * 0.7, options: [])
}

/// Draws a screenshot into `r` with a soft shadow, clipped to rounded corners when `radius` > 0
/// (the TUI window has its own corners and transparent edges).
func place(_ c: CGContext, _ image: CGImage, _ r: CGRect, radius: CGFloat = 0) {
    let shape = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 22), blur: 50, color: color(0x000000, 0.55))
    if radius > 0 {
        c.addPath(shape); c.setFillColor(color(0x000000)); c.fillPath()
    } else {
        draw(c, image, r)
    }
    c.restoreGState()
    if radius > 0 {
        c.saveGState(); c.addPath(shape); c.clip(); draw(c, image, r); c.restoreGState()
        c.addPath(shape); c.setStrokeColor(color(0xFFFFFF, 0.18)); c.setLineWidth(1); c.strokePath()
    }
}
/// CGContext draws images bottom-up; flip locally for the top-left canvas.
func draw(_ c: CGContext, _ image: CGImage, _ r: CGRect) {
    c.saveGState(); c.translateBy(x: r.minX, y: r.maxY); c.scaleBy(x: 1, y: -1)
    c.draw(image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height)); c.restoreGState()
}
func text(_ c: CGContext, _ string: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight, _ col: CGColor) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
        .font: font, .foregroundColor: NSColor(cgColor: col)!,
    ]))
    c.saveGState(); c.textMatrix = .identity
    c.translateBy(x: p.x, y: p.y); c.scaleBy(x: 1, y: -1)
    c.textPosition = .zero; CTLineDraw(line, c); c.restoreGState()
}
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath(); let n: CGFloat = 5
    for i in 0...720 {
        let a = CGFloat(i)/720*2 * .pi; let co = cos(a), si = sin(a)
        let x = r.midX + r.width/2 * (co < 0 ? -1 : 1) * pow(abs(co), 2/n)
        let y = r.midY + r.height/2 * (si < 0 ? -1 : 1) * pow(abs(si), 2/n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath(); return p
}

let tui = load("docs/assets/manual/devpulse-tui.png")
let popover = load("docs/assets/manual/devpulse-popover.png")
let icon = load("Resources/AppIcon.png")
func height(_ image: CGImage, width: CGFloat) -> CGFloat { width * CGFloat(image.height) / CGFloat(image.width) }
func width(_ image: CGImage, height: CGFloat) -> CGFloat { height * CGFloat(image.width) / CGFloat(image.height) }

// Hero: the terminal dashboard and the popover side by side.
do {
    let c = canvas(1600, 1000)
    backdrop(c, 1600, 1000)
    let tw: CGFloat = 960, th = height(tui, width: tw)
    place(c, tui, CGRect(x: 48, y: (1000 - th) / 2 + 30, width: tw, height: th))
    let ph: CGFloat = 800, pw = width(popover, height: ph)
    place(c, popover, CGRect(x: 1600 - 48 - pw, y: (1000 - ph) / 2 - 20, width: pw, height: ph), radius: 14)
    save(c, "docs/assets/hero.png")
}

// Social card: icon, name and tagline on the left, the screenshots on the right.
do {
    let c = canvas(1200, 630)
    backdrop(c, 1200, 630)
    let tw: CGFloat = 700, th = height(tui, width: tw)
    place(c, tui, CGRect(x: 430, y: 630 - th - 40, width: tw, height: th))
    let ph: CGFloat = 520, pw = width(popover, height: ph)
    place(c, popover, CGRect(x: 1200 - 40 - pw, y: 30, width: pw, height: ph), radius: 12)
    let iconRect = CGRect(x: 64, y: 72, width: 132, height: 132)
    c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: color(0x000000, 0.45))
    c.addPath(squircle(iconRect)); c.setFillColor(color(0x2E8C9F)); c.fillPath(); c.restoreGState()
    c.saveGState(); c.addPath(squircle(iconRect)); c.clip(); draw(c, icon, iconRect); c.restoreGState()
    text(c, "DevPulse", at: CGPoint(x: 64, y: 300), size: 64, weight: .bold, color(0xFFFFFF))
    for (i, line) in ["Your PRs, Jira tickets and", "Claude Code sessions —", "live in the menu bar", "and the terminal."].enumerated() {
        text(c, line, at: CGPoint(x: 66, y: 360 + CGFloat(i) * 38), size: 27, weight: .regular, color(0xD5E7E9))
    }
    save(c, "docs/assets/og-image.png")
}

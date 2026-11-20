// Draws DevPulse's artwork: the app icon "Lookout" (AppIcon.png, icon-web.png) and the menu bar glyph "Sonar" (MenuBarIcon.pdf and PNGs).
// Run: swift scripts/artwork/generate.swift <output-dir>   (not part of the build; nothing is copied anywhere)
// Then copy AppIcon.png to Resources/, MenuBarIcon.pdf into Resources/Assets.xcassets/MenuBarIcon.imageset/ and icon-web.png to docs/assets/icon.png.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/artwork/generate.swift <output-dir>\n".utf8))
    exit(2)
}
let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255)/255, CGFloat((hex >> 8) & 255)/255, CGFloat(hex & 255)/255, alpha])!
}
func canvas(_ width: Int, _ height: Int) -> CGContext {
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
    c.setAllowsAntialiasing(true); c.setShouldAntialias(true)
    return c
}
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x:x,y:y,width:w,height:h) }
func fill(_ c: CGContext, _ p: CGPath, _ col: CGColor) { c.addPath(p); c.setFillColor(col); c.fillPath() }
func stroke(_ c: CGContext, _ p: CGPath, _ col: CGColor, _ width: CGFloat) {
    c.addPath(p); c.setStrokeColor(col); c.setLineWidth(width); c.setLineCap(.round); c.setLineJoin(.round); c.strokePath()
}
func linear(_ c: CGContext, _ colors: [CGColor], _ from: CGPoint, _ to: CGPoint, _ p: CGPath? = nil) {
    c.saveGState(); if let p {c.addPath(p);c.clip()}
    let g = CGGradient(colorsSpace:cs,colors:colors as CFArray,locations:nil)!
    c.drawLinearGradient(g,start:from,end:to,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation]);c.restoreGState()
}
func glow(_ c: CGContext, _ center: CGPoint, _ radius: CGFloat, _ col: UInt32, _ a: CGFloat) {
    let g = CGGradient(colorsSpace:cs,colors:[color(col,a),color(col,0)] as CFArray,locations:[0,1])!
    c.drawRadialGradient(g,startCenter:center,startRadius:0,endCenter:center,endRadius:radius,options:[])
}
func ellipse(_ r: CGRect) -> CGPath { CGPath(ellipseIn:r,transform:nil) }
func shadow(_ c: CGContext, _ p: CGPath, _ opacity: CGFloat = 0.25, _ blur: CGFloat = 35, _ dy: CGFloat = 26) {
    c.saveGState();c.setShadow(offset:CGSize(width:0,height:dy),blur:blur,color:color(0x061537,opacity));fill(c,p,color(0x162039));c.restoreGState()
}
func line(_ x1:CGFloat,_ y1:CGFloat,_ x2:CGFloat,_ y2:CGFloat) -> CGPath {
    let p=CGMutablePath();p.move(to:CGPoint(x:x1,y:y1));p.addLine(to:CGPoint(x:x2,y:y2));return p
}
func save(_ image: CGImage, _ name: String) {
    let dest = CGImageDestinationCreateWithURL(base.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(dest,image,nil);precondition(CGImageDestinationFinalize(dest));print("Saved \(name): \(image.width)x\(image.height)")
}
func drawImage(_ c:CGContext,_ im:CGImage,_ r:CGRect) {
    c.saveGState();c.translateBy(x:r.minX,y:r.maxY);c.scaleBy(x:1,y:-1);c.interpolationQuality = .high;c.draw(im,in:rect(0,0,r.width,r.height));c.restoreGState()
}

// Lookout (the app icon): an always-on sonar lens with a single actionable signal.
func lookout() -> CGImage {
    let c=canvas(1024,1024)
    linear(c,[color(0xBDE9E6),color(0x68BFC4),color(0x2E8C9F)],CGPoint(x:0,y:0),CGPoint(x:1000,y:1024))
    glow(c,CGPoint(x:170,y:80),900,0xF4FFF7,0.65)
    let dial=ellipse(rect(194,194,636,636))
    shadow(c,dial,0.25,48,38)
    linear(c,[color(0x164E67),color(0x0A374E),color(0x062D42)],CGPoint(x:280,y:200),CGPoint(x:740,y:830),dial)
    stroke(c,dial,color(0xE1FFFF,0.65),5)
    glow(c,CGPoint(x:440,y:410),310,0x2F9FAD,0.38)
    // A broad angular sweep, without grid or tiny radar details.
    let sweep=CGMutablePath();sweep.move(to:CGPoint(x:512,y:512))
    sweep.addArc(center:CGPoint(x:512,y:512),radius:275,startAngle:-1.48,endAngle:-0.52,clockwise:false);sweep.closeSubpath()
    linear(c,[color(0x6CF6C9,0.02),color(0x78FFD8,0.47)],CGPoint(x:440,y:400),CGPoint(x:739,y:303),sweep)
    for (radius,width,a):(CGFloat,CGFloat,CGFloat) in [(264,18,0.68),(176,15,0.55),(88,12,0.38)] {
        let ring=ellipse(rect(512-radius,512-radius,2*radius,2*radius))
        c.saveGState();c.setShadow(offset:CGSize(width:0,height:5),blur:5,color:color(0x001C2A,0.6));stroke(c,ring,color(0x76CBCB,a),width);c.restoreGState()
    }
    stroke(c,line(512,512,741,318),color(0x9EFBDD,0.65),12)
    let signal=ellipse(rect(674,290,77,77))
    glow(c,CGPoint(x:712,y:328),105,0x76FFCF,0.4)
    shadow(c,signal,0.25,12,8)
    linear(c,[color(0xF3FFF0),color(0xA4FBD6),color(0x70DABB)],CGPoint(x:687,y:294),CGPoint(x:740,y:365),signal)
    let hub=ellipse(rect(481,481,62,62));shadow(c,hub,0.25,9,5)
    linear(c,[color(0xD2FFF1),color(0x59C6BE)],CGPoint(x:490,y:481),CGPoint(x:530,y:543),hub)
    return c.makeImage()!
}

// Continuous corner mask: macOS-style superellipse, for presentation only.
func squircle(_ r:CGRect)->CGPath {
    let p=CGMutablePath();let n:CGFloat=5
    for i in 0...720 {
        let a=CGFloat(i)/720*2 * .pi;let co=cos(a),si=sin(a)
        let x=r.midX+r.width/2 * (co<0 ? -1:1)*pow(abs(co),2/n)
        let y=r.midY+r.height/2 * (si<0 ? -1:1)*pow(abs(si),2/n)
        if i==0 {p.move(to:CGPoint(x:x,y:y))} else {p.addLine(to:CGPoint(x:x,y:y))}
    };p.closeSubpath();return p
}

// --- v0.2 driver: opaque app master + Sonar glyph (PNG sizes and vector PDF) ---
// Flatten onto an opaque RGB canvas (no alpha channel at all).
func opaque(_ im: CGImage) -> CGImage {
    let c = CGContext(data: nil, width: im.width, height: im.height, bitsPerComponent: 8, bytesPerRow: im.width*4,
                      space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.setFillColor(color(0x2E8C9F)); c.fill(CGRect(x: 0, y: 0, width: im.width, height: im.height))
    c.draw(im, in: CGRect(x: 0, y: 0, width: im.width, height: im.height))
    return c.makeImage()!
}
save(opaque(lookout()), "AppIcon.png")

// Sonar (the menu bar glyph), drawn in its 36-unit design space.
func sonar(_ c: CGContext) {
    let black = color(0x000000)
    stroke(c, ellipse(rect(5,5,26,26)), black, 3.3)
    stroke(c, line(18,18,26,10), black, 3.3)
    fill(c, ellipse(rect(14,14,8,8)), black)
}
for scale in [1, 2, 3] {
    let px = 18*scale
    // Draw at 8x, then sample down (as the original generator does).
    let big = canvas(px*8, px*8); big.scaleBy(x: CGFloat(px*8)/36, y: CGFloat(px*8)/36); sonar(big)
    let out = canvas(px, px); drawImage(out, big.makeImage()!, rect(0,0,CGFloat(px),CGFloat(px)))
    save(out.makeImage()!, "MenuBarIcon\(scale == 1 ? "" : "@\(scale)x").png")
}
// Vector: 18 x 18 pt PDF.
var box = CGRect(x: 0, y: 0, width: 18, height: 18)
let pdfURL = base.appendingPathComponent("MenuBarIcon.pdf")
let pdf = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
pdf.beginPDFPage(nil)
pdf.translateBy(x: 0, y: 18); pdf.scaleBy(x: 0.5, y: -0.5)
sonar(pdf)
pdf.endPDFPage(); pdf.closePDF()
print("Saved MenuBarIcon.pdf")

// Website icon: the master clipped to the continuous-corner squircle, edge to edge like the
// previous docs/assets/icon.png; drawn at 1024 and sampled down to 256.
let webBig = canvas(1024, 1024)
webBig.addPath(squircle(rect(0,0,1024,1024))); webBig.clip()
drawImage(webBig, lookout(), rect(0,0,1024,1024))
let web = canvas(256, 256); drawImage(web, webBig.makeImage()!, rect(0,0,256,256))
save(web.makeImage()!, "icon-web.png")

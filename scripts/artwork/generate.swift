// Draws DevPulse's artwork: the app icon "Lookout" (AppIcon.png, icon-web.png) and the menu bar glyph "Sonar" (MenuBarIcon.pdf and PNGs).
// Run: swift scripts/artwork/generate.swift <output-dir>   (not part of the build; nothing is copied anywhere)
// Then copy AppIcon.png to Resources/, MenuBarIcon.pdf into Resources/Assets.xcassets/MenuBarIcon.imageset/ and icon-web.png to docs/assets/icon.png.
import AppKit
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
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect:r,cornerWidth:radius,cornerHeight:radius,transform:nil) }
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

// A / Resonance: two sculpted, asymmetric pulse lobes surrounding a quiet live seed.
func resonance() -> CGImage {
    let c=canvas(1024,1024)
    linear(c,[color(0x3659CF),color(0x1643A6),color(0x092A6A)],CGPoint(x:80,y:0),CGPoint(x:950,y:1024))
    glow(c,CGPoint(x:220,y:90),760,0x8DAEFF,0.48)
    glow(c,CGPoint(x:900,y:910),740,0x13B5CF,0.38)
    let l=CGMutablePath()
    l.move(to:CGPoint(x:515,y:228))
    l.addCurve(to:CGPoint(x:245,y:498),control1:CGPoint(x:369,y:205),control2:CGPoint(x:239,y:329))
    l.addCurve(to:CGPoint(x:439,y:766),control1:CGPoint(x:244,y:641),control2:CGPoint(x:344,y:744))
    l.addCurve(to:CGPoint(x:477,y:689),control1:CGPoint(x:489,y:777),control2:CGPoint(x:508,y:718))
    l.addCurve(to:CGPoint(x:365,y:501),control1:CGPoint(x:402,y:622),control2:CGPoint(x:364,y:578))
    l.addCurve(to:CGPoint(x:537,y:307),control1:CGPoint(x:365,y:405),control2:CGPoint(x:438,y:338))
    l.addCurve(to:CGPoint(x:515,y:228),control1:CGPoint(x:580,y:293),control2:CGPoint(x:560,y:237));l.closeSubpath()
    c.saveGState();c.translateBy(x:512,y:512);c.rotate(by:-0.32);c.translateBy(x:-512,y:-512)
    shadow(c,l,0.30,34,30)
    linear(c,[color(0xFFFFFF),color(0xDBF9FF),color(0x63CAE9)],CGPoint(x:300,y:220),CGPoint(x:465,y:770),l)
    stroke(c,l,color(0xFFFFFF,0.32),2)
    var rotation=CGAffineTransform(translationX:1024,y:1024).rotated(by:.pi)
    let r=l.copy(using:&rotation)!
    shadow(c,r,0.25,35,26)
    linear(c,[color(0xAEFFF0),color(0x50E6DA),color(0x12A7C8)],CGPoint(x:620,y:280),CGPoint(x:700,y:800),r)
    stroke(c,r,color(0xD8FFF8,0.45),2)
    glow(c,CGPoint(x:512,y:500),142,0x66F9FF,0.22)
    let seed=ellipse(rect(451,451,122,122));shadow(c,seed,0.24,20,15)
    linear(c,[color(0xFFFFFF),color(0xD6FFF4),color(0x7CE9DF)],CGPoint(x:480,y:450),CGPoint(x:550,y:575),seed)
    c.restoreGState();return c.makeImage()!
}

// B / Workdeck: three independent work streams collected into one focused dashboard.
func workdeck() -> CGImage {
    let c=canvas(1024,1024)
    linear(c,[color(0xF3EFFF),color(0xD9CDF4),color(0xB5A4E5)],CGPoint(x:0,y:0),CGPoint(x:1024,y:1024))
    glow(c,CGPoint(x:90,y:100),850,0xFFFFFF,0.75)
    glow(c,CGPoint(x:960,y:800),650,0x7F78DF,0.25)
    func card(_ x:CGFloat,_ y:CGFloat,_ angle:CGFloat,_ colors:[UInt32],_ content:Bool=false) {
        c.saveGState();c.translateBy(x:x+275,y:y+210);c.rotate(by:angle);c.translateBy(x:-275,y:-210)
        let p=rounded(rect(0,0,550,420),60)
        shadow(c,p,0.20,33,28)
        linear(c,colors.map{color($0)},CGPoint(x:0,y:0),CGPoint(x:540,y:430),p)
        stroke(c,p,color(0xFFFFFF,0.54),2)
        if content {
            // Four simple raised cells; no text or pseudo-text.
            let left=rounded(rect(48,49,186,322),30)
            linear(c,[color(0x8F83DD),color(0x6654B5)],CGPoint(x:48,y:49),CGPoint(x:235,y:370),left)
            let right1=rounded(rect(258,49,244,148),30)
            linear(c,[color(0xF0ECFF),color(0xE3DCF6)],CGPoint(x:258,y:49),CGPoint(x:502,y:197),right1)
            let right2=rounded(rect(258,221,244,150),30)
            linear(c,[color(0xE9E4F9),color(0xDDD4F0)],CGPoint(x:258,y:221),CGPoint(x:502,y:371),right2)
            // Active session seed and two broad progress blocks.
            let seed=ellipse(rect(108,104,65,65));shadow(c,seed,0.12,12,7)
            linear(c,[color(0xE0FFF2),color(0x8BE5C9)],CGPoint(x:115,y:104),CGPoint(x:165,y:169),seed)
            fill(c,rounded(rect(91,218,29,104),14),color(0xCFC7FA))
            fill(c,rounded(rect(153,186,29,136),14),color(0xFFFFFF,0.94))
            fill(c,ellipse(rect(288,94,40,40)),color(0x8B78C8))
            fill(c,rounded(rect(347,101,110,26),13),color(0xA494D3))
            fill(c,ellipse(rect(288,276,40,40)),color(0x64B8A2))
            fill(c,rounded(rect(347,283,81,26),13),color(0xA494D3))
        }
        c.restoreGState()
    }
    card(244,201,-0.15,[0x9B91D6,0x7264B4])
    card(239,286,0.095,[0xC3BAEB,0xA297D3])
    card(205,392,-0.045,[0xFFFFFF,0xF4F0FC],true)
    return c.makeImage()!
}

// C / Lookout: an always-on sonar lens with a single actionable signal.
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

// Template glyphs: designed at 36 px, rendered at 8x then sampled down.
func glyph(_ index:Int) -> CGImage {
    let c=canvas(288,288);c.scaleBy(x:8,y:8);let black=color(0x000000)
    switch index {
    case 1:
        let p=CGMutablePath();p.move(to:CGPoint(x:16,y:5));p.addCurve(to:CGPoint(x:11,y:29),control1:CGPoint(x:3,y:7),control2:CGPoint(x:3,y:23))
        stroke(c,p,black,4.4)
        let q=CGMutablePath();q.move(to:CGPoint(x:25,y:7));q.addCurve(to:CGPoint(x:20,y:31),control1:CGPoint(x:33,y:13),control2:CGPoint(x:33,y:28))
        stroke(c,q,black,4.4);fill(c,ellipse(rect(14.7,14.7,6.6,6.6)),black)
    case 2:
        stroke(c,rounded(rect(5,13,25,17),3.4),black,3.5)
        stroke(c,line(8,8,28,8),black,3.5);stroke(c,line(11,3,25,3),black,3.5)
        fill(c,rounded(rect(10,18,5,7),1.4),black);fill(c,rounded(rect(19,18,6,3),1.4),black)
    case 3:
        stroke(c,ellipse(rect(5,5,26,26)),black,3.3)
        stroke(c,line(18,18,26,10),black,3.3)
        fill(c,ellipse(rect(14,14,8,8)),black)
    default:
        fill(c,rounded(rect(5,5,10,10),3),black)
        fill(c,rounded(rect(5,21,10,10),3),black)
        fill(c,rounded(rect(21,21,10,10),3),black)
        fill(c,ellipse(rect(21,5,10,10)),black)
    }
    let out=canvas(36,36);drawImage(out,c.makeImage()!,rect(0,0,36,36));return out.makeImage()!
}
func tintGlyph(_ c:CGContext,_ im:CGImage,_ r:CGRect,_ col:CGColor) {
    c.saveGState();c.translateBy(x:r.minX,y:r.maxY);c.scaleBy(x:1,y:-1);c.clip(to:rect(0,0,r.width,r.height),mask:im);c.setFillColor(col);c.fill(rect(0,0,r.width,r.height));c.restoreGState()
}
func text(_ c:CGContext,_ string:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ weight:NSFont.Weight = .regular,_ col:UInt32=0x202631) {
    c.saveGState();NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:true)
    let attr:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:NSColor(cgColor:color(col))!]
    (string as NSString).draw(at:CGPoint(x:x,y:y),withAttributes:attr)
    NSGraphicsContext.restoreGraphicsState();c.restoreGState()
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
func maskedIcon(_ c:CGContext,_ im:CGImage,_ r:CGRect) {
    let p=squircle(r);shadow(c,p,0.10,r.width*0.035,r.width*0.02)
    c.saveGState();c.addPath(p);c.clip();drawImage(c,im,r);c.restoreGState()
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

// Sonar (glyph 3) drawn in its 36-unit design space.
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

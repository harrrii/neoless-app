// neoless icon renderer - Apple-style variants (graphite / blue / dark).
// Usage: swift draw-icon.swift <outdir>   (<outdir> needs preview/ and iconsets/ subfolders)
// neoless ships the "blue" variant: Resources/neoless.icns is
//   iconutil -c icns <outdir>/iconsets/neoless-blue.iconset -o Resources/neoless.icns
// and Resources/icon/neoless-1024.png is <outdir>/neoless-blue-1024.png. The sidebar BrandMark
// (Sources/neoless/DesignSystem.swift) redraws the same wave and colours as a vector.
// Draws everything as vectors at each target size (no bitmap downscaling).
import AppKit
import CoreGraphics

// MARK: - Tunables (all in 1024-canvas units, y down like SVG)

let tileOrigin: CGFloat = 100          // Big Sur grid: 824pt tile centred in 1024
let tileSize: CGFloat = 824
let cornerRatio: CGFloat = 0.2237      // continuous corner radius / tile size (Apple icon tile)
let glyphScale: CGFloat = 0.84         // shrink the original wave about the tile centre
let glyphStroke: CGFloat = 98          // stroke width after scaling (1024 units)
let glyphDY: CGFloat = 6               // optical centring nudge (down)

// Original n-wave from neoless-icon.svg (1024 space, y down).
func baseWave() -> CGMutablePath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 286, y: 685))
    p.addLine(to: CGPoint(x: 286, y: 432))
    p.addCurve(to: CGPoint(x: 496, y: 432), control1: CGPoint(x: 286, y: 291), control2: CGPoint(x: 454, y: 291))
    p.addLine(to: CGPoint(x: 550, y: 607))
    p.addCurve(to: CGPoint(x: 738, y: 574), control1: CGPoint(x: 590, y: 738), control2: CGPoint(x: 738, y: 726))
    p.addLine(to: CGPoint(x: 738, y: 494))
    return p
}

func wavePath() -> CGPath {
    let base = baseWave()
    // centre of the stroked glyph's bounds
    let outline = base.copy(strokingWithWidth: 128, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let b = outline.boundingBoxOfPath
    var t = CGAffineTransform(translationX: 512, y: 512 + glyphDY)
        .scaledBy(x: glyphScale, y: glyphScale)
        .translatedBy(x: -b.midX, y: -b.midY)
    return base.copy(using: &t)!
}

// Apple continuous-corner ("squircle") rounded rect, same curve family as
// UIBezierPath(roundedRect:cornerRadius:) on iOS 7+ / Big Sur icon tiles.
func squircle() -> CGPath {
    let r = tileSize * cornerRatio
    let minX = tileOrigin, minY = tileOrigin, maxX = tileOrigin + tileSize, maxY = tileOrigin + tileSize
    let p = CGMutablePath()
    // corner helper: (ux,uy) = unit vectors from the corner along the two edges, in order of travel
    func corner(_ cx: CGFloat, _ cy: CGFloat, _ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat) {
        // a = direction back along incoming edge, b = direction along outgoing edge
        func P(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: cx + (ax * u + bx * v) * r, y: cy + (ay * u + by * v) * r) }
        p.addLine(to: P(1.52866483, 0))
        p.addCurve(to: P(0.63149399, 0.07491100), control1: P(1.08849323, 0), control2: P(0.86840689, 0))
        p.addCurve(to: P(0.07491100, 0.63149399), control1: P(0.37282392, 0.16905899), control2: P(0.16905899, 0.37282392))
        p.addCurve(to: P(0, 1.52866483), control1: P(0, 0.86840689), control2: P(0, 1.08849323))
    }
    p.move(to: CGPoint(x: minX + 1.52866483 * r, y: minY))
    corner(maxX, minY, -1, 0, 0, 1)   // top-right (y down)
    corner(maxX, maxY, 0, -1, -1, 0)  // bottom-right
    corner(minX, maxY, 1, 0, 0, -1)   // bottom-left
    corner(minX, minY, 0, 1, 1, 0)    // top-left
    p.closeSubpath()
    return p
}

// MARK: - Styles

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

struct Style {
    let name: String
    let tileTop: CGColor, tileBottom: CGColor
    let tileTint: CGColor?            // optional soft radial tint in the lower half
    let rim: CGColor                  // hairline inner edge
    let topSheen: CGFloat             // white highlight strength at top edge
    let waveTop: CGColor, waveBottom: CGColor
    let glyphShadow: CGColor, glyphShadowBlur: CGFloat, glyphShadowDY: CGFloat
    let glow: CGColor?, glowBlur: CGFloat
}

let styles: [Style] = [
    Style(name: "graphite",
          tileTop: rgb(0xFFFFFF), tileBottom: rgb(0xE6E6EB), tileTint: nil,
          rim: rgb(0x000000, 0.07), topSheen: 0.0,
          waveTop: rgb(0x48484A), waveBottom: rgb(0x1D1D1F),
          glyphShadow: rgb(0x000000, 0.22), glyphShadowBlur: 14, glyphShadowDY: 6,
          glow: nil, glowBlur: 0),
    Style(name: "blue",
          tileTop: rgb(0xFFFFFF), tileBottom: rgb(0xE9EDF3), tileTint: rgb(0x0A84FF, 0.10),
          rim: rgb(0x0A2A5A, 0.07), topSheen: 0.0,
          waveTop: rgb(0x40A2FF), waveBottom: rgb(0x0A78F5),
          glyphShadow: rgb(0x0A5CD6, 0.30), glyphShadowBlur: 16, glyphShadowDY: 7,
          glow: nil, glowBlur: 0),
    Style(name: "dark",
          tileTop: rgb(0x414146), tileBottom: rgb(0x161618), tileTint: nil,
          rim: rgb(0xFFFFFF, 0.10), topSheen: 0.10,
          waveTop: rgb(0xFFFFFF), waveBottom: rgb(0xDCDCE2),
          glyphShadow: rgb(0x000000, 0.45), glyphShadowBlur: 14, glyphShadowDY: 6,
          glow: rgb(0xB8B8C2, 0.30), glowBlur: 40),
]

// MARK: - Render

func render(_ s: Style, px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ns = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = ns.cgContext
    let k = CGFloat(px) / 1024
    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    // y-down 1024 space
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: k, y: -k)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    let tile = squircle()
    let tileRect = CGRect(x: tileOrigin, y: tileOrigin, width: tileSize, height: tileSize)

    // 1. drop shadow (Big Sur: soft, slightly offset down). Shadow params are in device px.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 20 * k, color: rgb(0x000000, 0.30))
    ctx.addPath(tile); ctx.setFillColor(s.tileBottom); ctx.fillPath()
    ctx.restoreGState()
    // tighter contact shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -2 * k), blur: 3 * k, color: rgb(0x000000, 0.18))
    ctx.addPath(tile); ctx.setFillColor(s.tileBottom); ctx.fillPath()
    ctx.restoreGState()

    // 2. tile body: top-lit vertical gradient
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [s.tileTop, s.tileBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: tileRect.minY), end: CGPoint(x: 512, y: tileRect.maxY), options: [])
    if let tint = s.tileTint {
        let clear = tint.copy(alpha: 0)!
        let rg = CGGradient(colorsSpace: space, colors: [tint, clear] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(rg, startCenter: CGPoint(x: 512, y: tileRect.maxY + 60), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: tileRect.maxY + 60), endRadius: 640, options: [])
    }
    if s.topSheen > 0 {
        let sh = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, s.topSheen), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sh, start: CGPoint(x: 512, y: tileRect.minY), end: CGPoint(x: 512, y: tileRect.minY + 260), options: [])
    }
    ctx.restoreGState()

    // 3. hairline rim (inside the tile) so light tiles hold their edge on white
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.addPath(tile)
    ctx.setStrokeColor(s.rim); ctx.setLineWidth(max(4, 2 / k))  // >=1 device px at small sizes
    ctx.strokePath()
    if s.topSheen > 0 { // brighter top rim on the dark tile
        ctx.addPath(tile); ctx.clip()
        let rimG = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.addPath(tile); ctx.setLineWidth(max(5, 2 / k)); ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(rimG, start: CGPoint(x: 512, y: tileRect.minY), end: CGPoint(x: 512, y: tileRect.minY + 200), options: [])
    }
    ctx.restoreGState()

    // 4. glyph
    // Slightly heavier stroke at tiny sizes for legibility.
    let sw = glyphStroke * (px <= 32 ? 1.06 : 1)
    let glyph = wavePath().copy(strokingWithWidth: sw, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let gb = glyph.boundingBoxOfPath

    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    if let glow = s.glow, px >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: s.glowBlur * k, color: glow)
        ctx.addPath(glyph); ctx.setFillColor(s.waveBottom); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s.glyphShadowDY * k), blur: s.glyphShadowBlur * k, color: s.glyphShadow)
    ctx.addPath(glyph); ctx.setFillColor(s.waveBottom); ctx.fillPath()
    ctx.restoreGState()
    // gradient fill of the stroke
    ctx.saveGState()
    ctx.addPath(glyph); ctx.clip()
    let wg = CGGradient(colorsSpace: space, colors: [s.waveTop, s.waveBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(wg, start: CGPoint(x: 512, y: gb.minY), end: CGPoint(x: 512, y: gb.maxY), options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    ctx.flush()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// MARK: - Main

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let fm = FileManager.default
let iconsetSizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for s in styles {
    save(render(s, px: 1024), "\(out)/neoless-\(s.name)-1024.png")
    save(render(s, px: 64), "\(out)/preview/neoless-\(s.name)-64.png")
    save(render(s, px: 32), "\(out)/preview/neoless-\(s.name)-32.png")
    let set = "\(out)/iconsets/neoless-\(s.name).iconset"
    try? fm.createDirectory(atPath: set, withIntermediateDirectories: true)
    for (n, px) in iconsetSizes { save(render(s, px: px), "\(set)/\(n).png") }
}

// Contact sheet: each variant at 256 / 64 / 32 on light and dark desktop backgrounds,
// small sizes also shown enlarged 4x with nearest-neighbour to inspect pixels.
let sheetW = 1500, sheetH = 900
let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: sheetW, pixelsHigh: sheetH, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let sctx = NSGraphicsContext(bitmapImageRep: sheet)!
NSGraphicsContext.current = sctx
NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: sheetH / 2, width: sheetW, height: sheetH / 2).fill()
NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: sheetW, height: sheetH / 2).fill()
for (row, y0) in [(0, sheetH / 2), (1, 0)] {
    _ = row
    for (i, s) in styles.enumerated() {
        let x0 = 20 + i * 500
        let big = NSImage(size: NSSize(width: 256, height: 256)); big.addRepresentation(render(s, px: 256))
        big.draw(in: NSRect(x: x0, y: y0 + 100, width: 256, height: 256))
        let r64 = render(s, px: 64), r32 = render(s, px: 32)
        let i64 = NSImage(size: NSSize(width: 64, height: 64)); i64.addRepresentation(r64)
        let i32 = NSImage(size: NSSize(width: 32, height: 32)); i32.addRepresentation(r32)
        i64.draw(in: NSRect(x: x0 + 280, y: y0 + 300, width: 64, height: 64))
        i32.draw(in: NSRect(x: x0 + 360, y: y0 + 316, width: 32, height: 32))
        sctx.imageInterpolation = .none
        i32.draw(in: NSRect(x: x0 + 280, y: y0 + 120, width: 128, height: 128))
        sctx.imageInterpolation = .high
    }
}
NSGraphicsContext.restoreGraphicsState()
save(sheet, "\(out)/preview/contact-sheet.png")
print("ok")

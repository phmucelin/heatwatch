// Draws the HeatWatch app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
}

func draw(in ctx: CGContext) {
    // Work in top-left coordinates, like a design tool.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    // Background squircle on Apple's 824 pt icon grid, cool → hot sunset gradient.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.28))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x7A7CF0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0x5B8CFF), color(0xC66FD9), color(0xFF8A5B)], [0, 0.55, 1]),
        start: CGPoint(x: 140, y: 100), end: CGPoint(x: 884, y: 924), options: []
    )
    // Soft gloss on the upper half.
    ctx.drawLinearGradient(
        gradient([color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)]),
        start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 560), options: []
    )
    ctx.restoreGState()

    // Ground shadow under the mascot.
    ctx.setFillColor(color(0x2A1B4D, 0.18))
    ctx.fillEllipse(in: ellipse(512, 902, 300, 38))

    // Thermometer body: capsule + bulb.
    let body = CGMutablePath()
    body.addRoundedRect(in: CGRect(x: 397, y: 190, width: 230, height: 560), cornerWidth: 115, cornerHeight: 115)
    body.addEllipse(in: ellipse(512, 735, 330, 330))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x2A1B4D, 0.25))
    ctx.addPath(body)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0xFFFFFF), color(0xEEF0FF)]),
        start: CGPoint(x: 400, y: 190), end: CGPoint(x: 640, y: 900), options: []
    )
    ctx.restoreGState()

    // Mercury.
    let mercury = CGMutablePath()
    mercury.addRoundedRect(in: CGRect(x: 467, y: 505, width: 90, height: 260), cornerWidth: 45, cornerHeight: 45)
    mercury.addEllipse(in: ellipse(512, 735, 236, 236))
    ctx.saveGState()
    ctx.addPath(mercury)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0xFF8A4C), color(0xFF3D5E)]),
        start: CGPoint(x: 512, y: 505), end: CGPoint(x: 512, y: 860), options: []
    )
    ctx.restoreGState()
    ctx.setFillColor(color(0xFFFFFF, 0.45))
    ctx.fillEllipse(in: ellipse(462, 690, 44, 62))

    // Face.
    let ink = color(0x2B2D42)
    ctx.setFillColor(color(0xFF8FA3, 0.55))
    ctx.fillEllipse(in: ellipse(442, 438, 46, 26))
    ctx.fillEllipse(in: ellipse(582, 438, 46, 26))

    ctx.setFillColor(ink)
    ctx.fillEllipse(in: ellipse(468, 382, 40, 54))
    ctx.fillEllipse(in: ellipse(556, 382, 40, 54))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: ellipse(476, 370, 15, 15))
    ctx.fillEllipse(in: ellipse(564, 370, 15, 15))

    ctx.setStrokeColor(ink)
    ctx.setLineWidth(11)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 490, y: 442))
    ctx.addQuadCurve(to: CGPoint(x: 534, y: 442), control: CGPoint(x: 512, y: 470))
    ctx.strokePath()

    // Sweat drop: it's a heat app, after all.
    let drop = CGMutablePath()
    drop.move(to: CGPoint(x: 668, y: 246))
    drop.addCurve(to: CGPoint(x: 696, y: 310), control1: CGPoint(x: 678, y: 266), control2: CGPoint(x: 696, y: 286))
    drop.addArc(center: CGPoint(x: 668, y: 310), radius: 28, startAngle: 0, endAngle: .pi, clockwise: false)
    drop.addCurve(to: CGPoint(x: 668, y: 246), control1: CGPoint(x: 640, y: 286), control2: CGPoint(x: 658, y: 266))
    drop.closeSubpath()
    ctx.saveGState()
    ctx.addPath(drop)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0xBDF0FF), color(0x5CC8FF)]),
        start: CGPoint(x: 668, y: 246), end: CGPoint(x: 668, y: 340), options: []
    )
    ctx.restoreGState()
    ctx.setFillColor(color(0xFFFFFF, 0.8))
    ctx.fillEllipse(in: ellipse(658, 310, 10, 16))
}

func renderPNG(to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(in: NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func run(_ tool: String, _ args: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let master = root.appendingPathComponent("Resources/AppIcon.png")
try renderPNG(to: master)

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        run("/usr/bin/sips", ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent(name).path])
    }
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path])
print("Wrote Resources/AppIcon.png and Resources/AppIcon.icns")

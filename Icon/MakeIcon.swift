// Draws the app icon as a 1024×1024 PNG:  swift Icon/MakeIcon.swift <output.png>
// A pixel-textured grass block in front of a blocky sky, with a green check mark badge.
import AppKit

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func withShadow(blur: CGFloat, y: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: y)
    shadow.set()
    // one shadow for the whole group, so overlapping shapes don't shade each other
    NSGraphicsContext.current!.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    draw()
    NSGraphicsContext.current!.cgContext.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
}

/// Same "random" texture on every run.
var seed: UInt32 = 20261023
func random() -> Double {
    seed = seed &* 1_664_525 &+ 1_013_904_223
    return Double(seed >> 8) / Double(1 << 24)
}

func darker(_ c: NSColor, _ factor: CGFloat) -> NSColor {
    NSColor(srgbRed: c.redComponent * factor, green: c.greenComponent * factor, blue: c.blueComponent * factor, alpha: 1)
}

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

// tile on the macOS icon grid: 824 pt with 100 pt margin
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
withShadow(blur: 24, y: -12, alpha: 0.35) { color(0x1E5FB4).setFill(); tile.fill() }
NSGradient(colors: [color(0x9ED8FF), color(0x5FB2F5), color(0x2F7FD6)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: tile, angle: -90)

NSGraphicsContext.saveGraphicsState()
tile.addClip()
// blocky clouds
color(0xFFFFFF, 0.9).setFill()
for (x, y, w, h) in [(170.0, 780.0, 190.0, 44.0), (216, 824, 100, 40), (640, 830, 210, 44), (690, 874, 110, 36), (120, 650, 90, 30)] {
    NSRect(x: x, y: y, width: w, height: h).fill()
}
NSGraphicsContext.restoreGraphicsState()

// MARK: Grass block

let s: CGFloat = 300 // edge length
let front = NSPoint(x: 492, y: 170) // front-bottom corner
let toRight = NSPoint(x: s * 0.866, y: s * 0.5), toLeft = NSPoint(x: -s * 0.866, y: s * 0.5), up = NSPoint(x: 0, y: s)

/// Fills a 16×16 pixel grid onto the face spanned by `u` (columns) and `v` (rows) from `origin`.
func face(origin: NSPoint, u: NSPoint, v: NSPoint, shade: CGFloat, pixel: (Int, Int) -> NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.transformStruct = NSAffineTransformStruct(m11: u.x / 16, m12: u.y / 16, m21: v.x / 16, m22: v.y / 16,
                                                         tX: origin.x, tY: origin.y)
    transform.concat()
    for column in 0..<16 {
        for row in 0..<16 {
            darker(pixel(column, row), shade).setFill()
            NSRect(x: CGFloat(column) - 0.03, y: CGFloat(row) - 0.03, width: 1.06, height: 1.06).fill() // overlap: no seams
        }
    }
    NSGraphicsContext.restoreGraphicsState()
}

let grass = [0x5EA83A, 0x6DBB45, 0x4F9530, 0x7CC653, 0x58A034].map { color($0) }
let dirt = [0x8B5A2B, 0x7A4D24, 0x9A6837, 0x6E4520, 0x84552A].map { color($0) }
let stone = color(0x8E8E8E)
func pick(_ colors: [NSColor]) -> NSColor { colors[Int(random() * Double(colors.count)) % colors.count] }

// grass hangs over the sides 3–6 pixels; column 0 is at the front edge on both sides, so the pattern is mirrored there
let overhang = (0..<16).map { _ in 3 + Int(random() * 3.4) }
func side(_ column: Int, _ row: Int) -> NSColor {
    if 15 - row < overhang[column] { return pick(grass) }
    return random() < 0.04 ? stone : pick(dirt)
}

withShadow(blur: 40, y: -22, alpha: 0.35) {
    let top = NSPoint(x: front.x + up.x, y: front.y + up.y)
    face(origin: top, u: toRight, v: toLeft, shade: 1.0) { _, _ in pick(grass) }
    face(origin: front, u: toLeft, v: up, shade: 0.82, pixel: side)
    face(origin: front, u: toRight, v: up, shade: 0.64, pixel: side)
}

// MARK: Check mark badge

let badgeCenter = NSPoint(x: 730, y: 300)
withShadow(blur: 22, y: -10, alpha: 0.35) {
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - 158, y: badgeCenter.y - 158, width: 316, height: 316)).fill()
}
let inner = NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - 134, y: badgeCenter.y - 134, width: 268, height: 268))
NSGradient(colors: [color(0x4BE36B), color(0x1E9E3E)])!.draw(in: inner, angle: -90)
let check = NSBezierPath()
check.move(to: NSPoint(x: badgeCenter.x - 66, y: badgeCenter.y + 4))
check.line(to: NSPoint(x: badgeCenter.x - 18, y: badgeCenter.y - 46))
check.line(to: NSPoint(x: badgeCenter.x + 70, y: badgeCenter.y + 56))
check.lineWidth = 44
check.lineCapStyle = .round
check.lineJoinStyle = .round
NSColor.white.setStroke()
check.stroke()

NSGraphicsContext.current = nil
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

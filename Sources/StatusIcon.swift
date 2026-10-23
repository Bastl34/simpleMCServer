import AppKit

/// The menu bar icon: an isometric block (top light, sides darker, grass edge cut in) with a colored status badge.
enum StatusIcon {
    enum Badge { case none, running, busy, failed }

    static func image(_ badge: Badge, dot: Bool = false, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let scale = size / 18
            // drawn in label color (or black for the template version), so it resolves per menu bar appearance
            let ink = badge == .none && !dot ? NSColor.black : NSColor.labelColor
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
            drawBlock(ink)
            if dot {
                knockOut(NSRect(x: 12.6, y: 12.6, width: 6, height: 6))
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: NSRect(x: 13.6, y: 13.6, width: 4, height: 4)).fill()
            }
            if let (symbol, color) = badgeSymbol(badge) {
                knockOut(NSRect(x: 8.6, y: -0.4, width: 10, height: 10))
                let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                    .applying(.init(paletteColors: [.white, color]))
                if let badgeImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let side: CGFloat = 8.4
                    badgeImage.draw(in: NSRect(x: 9.4, y: 0.4, width: side, height: side))
                }
            }
            return true
        }
        image.isTemplate = badge == .none && !dot
        return image
    }

    private static func badgeSymbol(_ badge: Badge) -> (String, NSColor)? {
        switch badge {
        case .none: nil
        case .running: ("checkmark.circle.fill", .systemGreen)
        case .busy: ("ellipsis.circle.fill", .systemOrange)
        case .failed: ("exclamationmark.circle.fill", .systemRed)
        }
    }

    /// Isometric cube in an 18×18 box: front-bottom corner at (9, 1), edge length 8.
    private static func drawBlock(_ ink: NSColor) {
        let s: CGFloat = 8, dx = s * 0.866, dy = s * 0.5
        let bottom = NSPoint(x: 9, y: 1), center = NSPoint(x: 9, y: 1 + s)
        let leftLow = NSPoint(x: 9 - dx, y: 1 + dy), rightLow = NSPoint(x: 9 + dx, y: 1 + dy)
        let leftHigh = NSPoint(x: 9 - dx, y: 1 + dy + s), rightHigh = NSPoint(x: 9 + dx, y: 1 + dy + s)
        let top = NSPoint(x: 9, y: 1 + 2 * s)

        func face(_ points: [NSPoint], _ alpha: CGFloat) {
            let path = NSBezierPath()
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            path.close()
            ink.withAlphaComponent(alpha).setFill()
            path.fill()
        }
        face([center, leftHigh, top, rightHigh], 1)
        face([bottom, leftLow, leftHigh, center], 0.72)
        face([bottom, rightLow, rightHigh, center], 0.5)

        // edges between the faces + the zigzag where the grass ends on the sides
        let lines = NSBezierPath()
        lines.lineWidth = 1
        lines.move(to: center); lines.line(to: bottom)
        lines.move(to: center); lines.line(to: leftHigh)
        lines.move(to: center); lines.line(to: rightHigh)
        for (corner, direction) in [(leftHigh, -1.0), (rightHigh, 1.0)] {
            // parallel to the top edge, 2.6 pt below it, from the outer corner to the middle edge in 4 zigzag steps
            let start = NSPoint(x: corner.x, y: corner.y - 2.6)
            lines.move(to: start)
            for step in 1...4 {
                let t = CGFloat(step) / 4
                let x = corner.x - direction * dx * t
                let y = corner.y - 2.6 - dy * t + (step % 2 == 1 ? -1.1 : 0)
                lines.line(to: NSPoint(x: x, y: y))
            }
        }
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        lines.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    /// Clears a circle, so the badge stands free of the block.
    private static func knockOut(_ rect: NSRect) {
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}

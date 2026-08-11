import AppKit

/// Draws the fan glyph at an arbitrary rotation.
///
/// The menu bar version is a template image so macOS tints it correctly in
/// light and dark menu bars; the app icon version paints the same geometry in
/// white on a gradient tile.
enum FanIcon {

    /// Paints the blades centred on the current context origin.
    private static func drawBlades(radius: CGFloat, angle: CGFloat, bladeCount: Int,
                                   color: NSColor, punchHub: Bool = true) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.rotate(by: angle)
        color.setFill()

        for index in 0..<bladeCount {
            context.saveGState()
            context.rotate(by: CGFloat(index) * (.pi * 2 / CGFloat(bladeCount)))

            let inner = radius * 0.24
            let outer = radius * 0.96
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 0, y: inner))
            path.curve(to: CGPoint(x: outer * 0.60, y: outer * 0.62),
                       controlPoint1: CGPoint(x: inner * 1.5, y: radius * 0.66),
                       controlPoint2: CGPoint(x: radius * 0.22, y: outer * 0.88))
            path.curve(to: CGPoint(x: inner * 0.85, y: -inner * 0.20),
                       controlPoint1: CGPoint(x: outer * 0.84, y: outer * 0.28),
                       controlPoint2: CGPoint(x: radius * 0.66, y: -inner * 0.30))
            path.close()
            path.fill()
            context.restoreGState()
        }

        // Punch out the hub so the blades read as separate shapes.
        let hubRadius = radius * 0.21
        let hub = NSBezierPath(ovalIn: CGRect(x: -hubRadius, y: -hubRadius,
                                              width: hubRadius * 2, height: hubRadius * 2))
        if punchHub {
            context.setBlendMode(.clear)
            hub.fill()
            context.setBlendMode(.normal)
        } else {
            hub.fill()
        }
        context.restoreGState()
    }

    static func image(size: CGFloat = 17, angle: CGFloat, bladeCount: Int = 3) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.saveGState()
            context.translateBy(x: rect.midX, y: rect.midY)
            drawBlades(radius: min(rect.width, rect.height) / 2,
                       angle: angle,
                       bladeCount: bladeCount,
                       color: .black)
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 1024-friendly app icon: the same fan in white on a blue-teal tile.
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.06, dy: rect.width * 0.06),
                                    xRadius: rect.width * 0.20,
                                    yRadius: rect.width * 0.20)
            let gradient = NSGradient(colors: [
                NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.95, alpha: 1),
                NSColor(calibratedRed: 0.32, green: 0.84, blue: 0.88, alpha: 1),
            ])
            gradient?.draw(in: tile, angle: 240)

            context.saveGState()
            context.translateBy(x: rect.midX, y: rect.midY)
            drawBlades(radius: rect.width * 0.30, angle: 0.45, bladeCount: 3,
                       color: .white, punchHub: false)
            context.restoreGState()
            return true
        }
    }
}

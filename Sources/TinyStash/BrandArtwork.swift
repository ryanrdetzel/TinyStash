import AppKit

/// One vector master for the lock screen and every macOS icon size.
@MainActor
enum BrandArtwork {
    static let ink = NSColor(srgbRed: 23 / 255, green: 44 / 255, blue: 64 / 255, alpha: 1)
    static let pocket = NSColor(srgbRed: 54 / 255, green: 121 / 255, blue: 141 / 255, alpha: 1)
    static let paper = NSColor(srgbRed: 237 / 255, green: 242 / 255, blue: 235 / 255, alpha: 1)
    static let amber = NSColor(srgbRed: 233 / 255, green: 181 / 255, blue: 104 / 255, alpha: 1)
    static let muted = NSColor(srgbRed: 167 / 255, green: 187 / 255, blue: 200 / 255, alpha: 1)

    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    static func draw(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 128, y: rect.height / 128)

        // The inset leaves the transparent breathing room expected of a Dock icon.
        ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 112, height: 112), xRadius: 26, yRadius: 26).fill()

        // A sheet with one folded corner, tucked into a broad U-shaped pocket.
        let note = NSBezierPath()
        note.move(to: NSPoint(x: 39, y: 35))
        note.line(to: NSPoint(x: 39, y: 94))
        note.curve(to: NSPoint(x: 45, y: 100),
                   controlPoint1: NSPoint(x: 39, y: 98), controlPoint2: NSPoint(x: 41, y: 100))
        note.line(to: NSPoint(x: 75, y: 100))
        note.line(to: NSPoint(x: 91, y: 84))
        note.line(to: NSPoint(x: 91, y: 35))
        note.close()
        paper.setFill()
        note.fill()

        let fold = NSBezierPath()
        fold.move(to: NSPoint(x: 75, y: 100))
        fold.line(to: NSPoint(x: 75, y: 84))
        fold.line(to: NSPoint(x: 91, y: 84))
        fold.close()
        NSColor(srgbRed: 0.65, green: 0.77, blue: 0.79, alpha: 1).setFill()
        fold.fill()

        amber.setFill()
        NSBezierPath(roundedRect: NSRect(x: 49, y: 82, width: 8, height: 24), xRadius: 3, yRadius: 3).fill()

        let pouch = NSBezierPath()
        pouch.move(to: NSPoint(x: 28, y: 72))
        pouch.curve(to: NSPoint(x: 100, y: 72),
                    controlPoint1: NSPoint(x: 49, y: 59), controlPoint2: NSPoint(x: 79, y: 59))
        pouch.line(to: NSPoint(x: 100, y: 49))
        pouch.curve(to: NSPoint(x: 64, y: 25),
                    controlPoint1: NSPoint(x: 100, y: 33), controlPoint2: NSPoint(x: 81, y: 25))
        pouch.curve(to: NSPoint(x: 28, y: 49),
                    controlPoint1: NSPoint(x: 47, y: 25), controlPoint2: NSPoint(x: 28, y: 33))
        pouch.close()
        pocket.setFill()
        pouch.fill()

        // The opening reads as a pocket rather than an envelope or a folder.
        let seam = NSBezierPath()
        seam.move(to: NSPoint(x: 39, y: 51))
        seam.curve(to: NSPoint(x: 89, y: 51),
                   controlPoint1: NSPoint(x: 52, y: 40), controlPoint2: NSPoint(x: 76, y: 40))
        seam.lineWidth = 3
        seam.lineCapStyle = .round
        paper.withAlphaComponent(0.5).setStroke()
        seam.stroke()
    }
}

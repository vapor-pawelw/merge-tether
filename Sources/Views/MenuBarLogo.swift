import AppKit

/// A scalable, single-color version of the app icon's three linked branch ends.
@MainActor
enum MenuBarLogo {
    static func image(needsAttention: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let color = (needsAttention ? NSColor.systemOrange : NSColor.labelColor).withAlphaComponent(1)
            color.setStroke()

            let under = NSBezierPath()
            under.lineWidth = 2.8
            under.lineCapStyle = .round
            under.move(to: NSPoint(x: 4, y: 13.4))
            under.curve(to: NSPoint(x: 8.7, y: 9.3), controlPoint1: NSPoint(x: 3.6, y: 9), controlPoint2: NSPoint(x: 5.6, y: 10.1))
            under.move(to: NSPoint(x: 10.6, y: 7.1))
            under.curve(to: NSPoint(x: 9, y: 3.2), controlPoint1: NSPoint(x: 12.1, y: 4.5), controlPoint2: NSPoint(x: 10.7, y: 3.5))
            under.stroke()

            let over = NSBezierPath()
            over.lineCapStyle = .round
            over.move(to: NSPoint(x: 14, y: 13.4))
            over.curve(to: NSPoint(x: 9.7, y: 8.6), controlPoint1: NSPoint(x: 13.9, y: 9.5), controlPoint2: NSPoint(x: 12, y: 9.1))
            over.curve(to: NSPoint(x: 7.5, y: 4.2), controlPoint1: NSPoint(x: 7.4, y: 8), controlPoint2: NSPoint(x: 6.1, y: 6.3))
            over.curve(to: NSPoint(x: 9, y: 3.2), controlPoint1: NSPoint(x: 7.9, y: 3.6), controlPoint2: NSPoint(x: 8.4, y: 3.3))
            context.saveGState()
            context.setBlendMode(.clear)
            over.lineWidth = 4.6
            over.stroke()
            context.restoreGState()
            color.setStroke()
            over.lineWidth = 2.8
            over.stroke()

            color.setFill()
            for center in [NSPoint(x: 4, y: 13.4), NSPoint(x: 14, y: 13.4), NSPoint(x: 9, y: 3.2)] {
                NSBezierPath(ovalIn: NSRect(x: center.x - 2.6, y: center.y - 2.6, width: 5.2, height: 5.2)).fill()
            }
            return true
        }
        image.isTemplate = !needsAttention
        return image
    }
}

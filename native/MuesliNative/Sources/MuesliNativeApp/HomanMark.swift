import AppKit
import CoreGraphics
import Foundation

/// Code-native Homan mark: the five-bar H on the 40-unit brand canvas.
///
/// Mirrors the canonical SVG geometry in `assets/brand/homan-mark.svg` so the
/// runtime never needs to load raster artwork for the mark itself. Coordinates
/// are in the SVG's y-down space (y=4 is the top).
enum HomanMark {
    struct Bar {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let radius: CGFloat
    }

    /// Rounded-cap bars (standard mark, `rx=2`).
    static let roundedBars: [Bar] = [
        Bar(x: 4, y: 8, width: 4, height: 24, radius: 2),
        Bar(x: 10, y: 4, width: 4, height: 32, radius: 2),
        Bar(x: 16, y: 17, width: 8, height: 6, radius: 2),
        Bar(x: 26, y: 4, width: 4, height: 32, radius: 2),
        Bar(x: 32, y: 8, width: 4, height: 24, radius: 2),
    ]

    /// Square-cap bars (16 pt optical exception, `rx=0`).
    static let squareCapBars: [Bar] = roundedBars.map {
        Bar(x: $0.x, y: $0.y, width: $0.width, height: $0.height, radius: 0)
    }

    /// A bezier path for the mark scaled into a `size`-by-`size` square.
    static func path(size: CGFloat, squareCaps: Bool = false) -> CGPath {
        let scale = size / 40.0
        let bars = squareCaps ? squareCapBars : roundedBars
        let path = CGMutablePath()
        for bar in bars {
            let rect = CGRect(
                x: bar.x * scale,
                y: bar.y * scale,
                width: bar.width * scale,
                height: bar.height * scale
            )
            let radius = bar.radius * scale
            path.addPath(
                CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            )
        }
        return path
    }

    /// Renders the mark as an NSImage filled with `color`.
    static func image(size: CGFloat, color: NSColor, squareCaps: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSGraphicsContext.current?.cgContext.saveGState()
        // NSImage context is y-up; flip so the SVG y-down geometry lands right.
        NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: size)
        NSGraphicsContext.current?.cgContext.scaleBy(x: 1, y: -1)
        color.setFill()
        NSBezierPath(cgPath: path(size: size, squareCaps: squareCaps)).fill()
        NSGraphicsContext.current?.cgContext.restoreGState()
        image.unlockFocus()
        return image
    }
}

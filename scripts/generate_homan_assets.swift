// generate_homan_assets.swift
// Deterministic Homan brand raster/icon generator.
//
// Reads the canonical mark geometry and renders brand candidates below
// build/brand-review/candidate/. The wordmark is rasterized from the
// bundled IBM Plex fonts via CoreText.
//
// Usage: homan-brand-assets generate-review
//        homan-brand-assets verify-assets
//        homan-brand-assets --self-check

import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - Canonical mark geometry (matches contracts/brand-identity.md)

private struct MarkRect {
    let x, y, w, h, rx: CGFloat
}

private let markRects: [MarkRect] = [
    MarkRect(x: 4, y: 8, w: 4, h: 24, rx: 2),
    MarkRect(x: 10, y: 4, w: 4, h: 32, rx: 2),
    MarkRect(x: 16, y: 17, w: 8, h: 6, rx: 2),
    MarkRect(x: 26, y: 4, w: 4, h: 32, rx: 2),
    MarkRect(x: 32, y: 8, w: 4, h: 24, rx: 2),
]

// MARK: - Brand tokens (contracts/brand-identity.md)

private let night   = rgb(0x10, 0x10, 0x13)
private let surface = rgb(0x17, 0x17, 0x1B)
private let elevated = rgb(0x1F, 0x1F, 0x24)
private let paper   = rgb(0xF4, 0xF2, 0xEE)
private let ember   = rgb(0xE8, 0xA0, 0x5C)
private let signal  = rgb(0x6F, 0xC4, 0x93)
private let mist    = rgb(0x8E, 0x8C, 0x94)
private let secondaryText = rgb(0xB9, 0xB7, 0xBE)

private func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return .black }
    return CGColor(
        colorSpace: space,
        components: [CGFloat(r) / 255.0, CGFloat(g) / 255.0, CGFloat(b) / 255.0, 1.0]
    )!
}

// MARK: - Context helpers

/// y-down context (matches the SVG canvas orientation).
private func makeContext(width: Int, height: Int) -> CGContext {
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

private func renderImage(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let ctx = makeContext(width: width, height: height)
    draw(ctx)
    return ctx.makeImage()!
}

// MARK: - Mark drawing

/// Draws the H mark. `scale` maps the 40-unit canvas into pixel space; `offset`
/// is the top-left of the 40-unit canvas in pixel space.
private func drawMark(_ ctx: CGContext, scale: CGFloat, offset: CGPoint, color: CGColor, squareCaps: Bool) {
    for r in markRects {
        let rect = CGRect(
            x: offset.x + r.x * scale,
            y: offset.y + r.y * scale,
            width: r.w * scale,
            height: r.h * scale
        )
        let radius = squareCaps ? 0 : r.rx * scale
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }
}

// MARK: - Wordmark

private func plexFont(weight: String, size: CGFloat) -> CTFont? {
    let name: String
    switch weight {
    case "regular": name = "IBMPlexSans-Regular"
    case "medium": name = "IBMPlexSans-Medium"
    case "semibold": name = "IBMPlexSans-SemiBold"
    case "bold": name = "IBMPlexSans-Bold"
    default: name = "IBMPlexSans-Regular"
    }
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    let fontURL = repoRoot.appendingPathComponent("assets/fonts/\(name).ttf")
    guard let provider = CGDataProvider(url: fontURL as CFURL),
          let cgFont = CGFont(provider) else {
        fputs("error: cannot load \(fontURL.path)\n", stderr)
        return nil
    }
    return CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
}

/// Renders the wordmark into its own upright image (CoreText, unflipped).
private func wordmarkImage(text: String, font: CTFont, color: CGColor) -> CGImage {
    let nsColor = NSColor(cgColor: color) ?? .white
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: nsColor]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let width = ceil(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let height = ceil(ascent + descent + leading)
    let ctx = CGContext(
        data: nil,
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.clear(CGRect(x: 0, y: 0, width: Int(width), height: Int(height)))
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: 0, y: descent)
    CTLineDraw(line, ctx)
    return ctx.makeImage()!
}


/// Draws an upright image into the flipped (y-down) main context.
private func drawUpright(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
}


/// Wordmark raster plus typographic metrics used for optical lockup spacing.
private struct WordmarkMetrics {
    let image: CGImage
    let width: CGFloat
    let height: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let capHeight: CGFloat
}

/// Renders the wordmark into its own upright image with metrics.
private func wordmark(text: String, font: CTFont, color: CGColor) -> WordmarkMetrics {
    let nsColor = NSColor(cgColor: color) ?? .white
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: nsColor]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let width = ceil(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let height = ceil(ascent + descent + leading)
    let ctx = CGContext(
        data: nil,
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.clear(CGRect(x: 0, y: 0, width: Int(width), height: Int(height)))
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: 0, y: descent)
    CTLineDraw(line, ctx)
    return WordmarkMetrics(
        image: ctx.makeImage()!,
        width: width,
        height: height,
        ascent: ascent,
        descent: descent,
        capHeight: CTFontGetCapHeight(font)
    )
}


// MARK: - Lockup geometry

/// Shared horizontal-lockup geometry: 2-module clear space around the painted
/// content, mark painted height == wordmark cap height, 2-module gap.
private struct LockupDims {
    let scale: CGFloat
    let clear: CGFloat
    let gap: CGFloat
    let markOffset: CGPoint
    let wordmarkOrigin: CGPoint
    let width: CGFloat
    let height: CGFloat
}

/// Builds horizontal-lockup geometry aligned to the wordmark's actual rendered
/// content bounds (optical centering) rather than raw typographic metrics.
/// `wordmarkContentTop`/`Bottom` are measured from the wordmark image top.
private func lockupDims(
    markPaintedHeight: CGFloat,
    wordmarkContentTop: CGFloat,
    wordmarkContentBottom: CGFloat,
    wordmarkWidth: CGFloat
) -> LockupDims {
    let scale = markPaintedHeight / 32.0   // mark painted height stays cap-height
    let clear = 8.0 * scale                // two modules of clear space
    let gap = 8.0 * scale                  // two-module gap mark -> wordmark
    let wordmarkTop = clear
    let contentCenter = wordmarkTop + (wordmarkContentTop + wordmarkContentBottom) / 2.0
    // Mark painted bounds are 4..36 on the 40-unit canvas; center them on the
    // wordmark content center.
    let markOffset = CGPoint(x: clear - 4.0 * scale, y: contentCenter - 20.0 * scale)
    let wordmarkX = markOffset.x + 36.0 * scale + gap
    return LockupDims(
        scale: scale,
        clear: clear,
        gap: gap,
        markOffset: markOffset,
        wordmarkOrigin: CGPoint(x: wordmarkX, y: wordmarkTop),
        width: wordmarkX + wordmarkWidth + clear,
        height: clear + wordmarkContentBottom + clear
    )
}

/// Measures the vertical content extent (rows with visible alpha) of an image.
private func contentBounds(_ image: CGImage) -> (top: CGFloat, bottom: CGFloat) {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(
        data: &data, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var top = h, bottom = 0
    for y in 0..<h {
        for x in 0..<w where data[(y * w + x) * 4 + 3] > 32 {
            if y < top { top = y }
            if y > bottom { bottom = y }
        }
    }
    return (CGFloat(top), CGFloat(bottom))
}

// MARK: - Compositions

/// App icon: Elevated squircle background + Paper mark (brand book).
private func appIconImage(size: Int) -> CGImage {
    renderImage(width: size, height: size) { ctx in
        ctx.setFillColor(elevated)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let s = CGFloat(size)
        let scale = s * 0.56 / 32.0  // painted footprint ~56% of the icon
        let offset = CGPoint(x: (s - 40.0 * scale) / 2.0, y: (s - 40.0 * scale) / 2.0)
        drawMark(ctx, scale: scale, offset: offset, color: paper, squareCaps: false)
    }
}

/// Menu template: monochrome (alpha-only) square-cap mark on transparent.
private func menuTemplateImage(size: Int) -> CGImage {
    renderImage(width: size, height: size) { ctx in
        let s = CGFloat(size)
        drawMark(ctx, scale: s / 40.0, offset: .zero, color: .black, squareCaps: true)
    }
}

/// Horizontal lockup: rounded mark + "Homan" wordmark (IBM Plex SemiBold).
/// Mark painted height equals the wordmark cap height; gap = two modules.
private func horizontalLockupImage(height: Int, wordmarkColor: CGColor) -> CGImage {
    let fontSize = CGFloat(height) * 0.45
    guard let font = plexFont(weight: "semibold", size: fontSize) else {
        fatalError("plex font unavailable")
    }
    let wm = wordmark(text: "Homan", font: font, color: wordmarkColor)
    let (top, bottom) = contentBounds(wm.image)
    let layout = lockupDims(
        markPaintedHeight: wm.capHeight,
        wordmarkContentTop: top,
        wordmarkContentBottom: bottom,
        wordmarkWidth: wm.width
    )
    return renderImage(width: Int(layout.width), height: Int(layout.height)) { ctx in
        drawMark(ctx, scale: layout.scale, offset: layout.markOffset, color: wordmarkColor, squareCaps: false)
        drawUpright(
            wm.image,
            in: CGRect(
                x: layout.wordmarkOrigin.x, y: layout.wordmarkOrigin.y,
                width: wm.width, height: wm.height
            ),
            ctx: ctx
        )
    }
}

/// Stacked lockup: rounded mark centered over the wordmark.
/// Gap between the mark painted bounds and the wordmark = three modules.
private func stackedLockupImage(width: Int, wordmarkColor: CGColor) -> CGImage {
    let w = CGFloat(width)
    let fontSize = w * 0.16
    guard let font = plexFont(weight: "semibold", size: fontSize) else {
        fatalError("plex font unavailable")
    }
    let wm = wordmark(text: "Homan", font: font, color: wordmarkColor)
    let markScale = w * 0.30 / 40.0
    let markSize = 40.0 * markScale
    let gap = 12.0 * markScale   // three modules
    let clear = 8.0 * markScale  // two-module clear space
    let markOffset = CGPoint(
        x: (w - markSize) / 2.0,          // center the mark canvas
        y: clear - 4.0 * markScale        // painted mark top at `clear`
    )
    let wmY = markOffset.y + 36.0 * markScale + gap  // below mark painted bottom
    let totalHeight = Int(wmY + wm.height + clear)
    return renderImage(width: width, height: totalHeight) { ctx in
        drawMark(ctx, scale: markScale, offset: markOffset, color: wordmarkColor, squareCaps: false)
        drawUpright(
            wm.image,
            in: CGRect(x: (w - wm.width) / 2.0, y: wmY, width: wm.width, height: wm.height),
            ctx: ctx
        )
    }
}

/// Typography sample: wordmark + tagline in EN/RU/PL.
private func typographySample(width: Int, color: CGColor) -> CGImage {
    let w = CGFloat(width)
    let fontSize = w * 0.10
    guard let font = plexFont(weight: "semibold", size: fontSize) else {
        fatalError("plex font unavailable")
    }
    let heading = wordmarkImage(text: "Homan", font: font, color: color)
    let hW = CGFloat(heading.width)
    let hH = CGFloat(heading.height)
    let samples = [
        ("English", "Human conversations, kept at home."),
        ("Русский", "Человеческие разговоры остаются дома."),
        ("Polski", "Ludzkie rozmowy zostają w domu."),
    ]
    let tagFont = plexFont(weight: "regular", size: w * 0.052)
    var rowY: CGFloat = 0
    var totalH: CGFloat = 0
    // measure
    var tagImages: [(CGImage, CGFloat, CGFloat)] = []
    totalH += hH
    for (_, tag) in samples {
        let t = wordmarkImage(text: tag, font: tagFont!, color: secondaryText)
        tagImages.append((t, CGFloat(t.width), CGFloat(t.height)))
        totalH += CGFloat(t.height) + 10
    }
    let pad: CGFloat = 40
    return renderImage(width: width, height: Int(totalH + pad * 2)) { ctx in
        ctx.setFillColor(night)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: totalH + pad * 2))
        rowY = pad
        drawUpright(heading, in: CGRect(x: pad, y: rowY, width: hW, height: hH), ctx: ctx)
        rowY += hH + 18
        for (tag, tw, th) in tagImages {
            drawUpright(tag, in: CGRect(x: pad, y: rowY, width: tw, height: th), ctx: ctx)
            rowY += th + 10
        }
    }
}

/// Repository open-graph: Night background, Paper mark + wordmark + tagline.
private func ogImage() -> CGImage {
    let w = 1280, h = 640
    let fontSize = 120.0
    guard let font = plexFont(weight: "semibold", size: fontSize),
          let tagFont = plexFont(weight: "regular", size: 44.0) else {
        fatalError("plex font unavailable")
    }
    let wordmark = wordmarkImage(text: "Homan", font: font, color: paper)
    let tagline = wordmarkImage(text: "Human conversations, kept at home.", font: tagFont, color: secondaryText)
    let wmW = CGFloat(wordmark.width), wmH = CGFloat(wordmark.height)
    let tgW = CGFloat(tagline.width), tgH = CGFloat(tagline.height)
    let markScale = 6.0
    let markSize = 40.0 * markScale
    return renderImage(width: w, height: h) { ctx in
        ctx.setFillColor(night)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // mark centered-left, wordmark + tagline to its right
        let markOffset = CGPoint(x: 160 - 20.0 * markScale, y: (CGFloat(h) - markSize) / 2.0)
        drawMark(ctx, scale: markScale, offset: markOffset, color: paper, squareCaps: false)
        let textX = 160 + markSize + 56
        let textY = CGFloat(h) / 2.0 - wmH - 16
        drawUpright(wordmark, in: CGRect(x: textX, y: textY, width: wmW, height: wmH), ctx: ctx)
        drawUpright(tagline, in: CGRect(x: textX, y: textY + wmH + 20, width: tgW, height: tgH), ctx: ctx)
    }
}


// MARK: - SVG lockup masters (T013)

private func svgNumber(_ v: CGFloat) -> String {
    String(format: "%.2f", v)
}

/// Serializes a CGPath into an SVG path `d` string.
private func cgPathToSVGD(_ path: CGPath) -> String {
    var d = ""
    path.applyWithBlock { element in
        let p = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint:
            d += "M \(svgNumber(p[0].x)) \(svgNumber(p[0].y)) "
        case .addLineToPoint:
            d += "L \(svgNumber(p[0].x)) \(svgNumber(p[0].y)) "
        case .addQuadCurveToPoint:
            d += "Q \(svgNumber(p[0].x)) \(svgNumber(p[0].y)) \(svgNumber(p[1].x)) \(svgNumber(p[1].y)) "
        case .addCurveToPoint:
            d += "C \(svgNumber(p[0].x)) \(svgNumber(p[0].y)) \(svgNumber(p[1].x)) \(svgNumber(p[1].y)) \(svgNumber(p[2].x)) \(svgNumber(p[2].y)) "
        case .closeSubpath:
            d += "Z "
        @unknown default:
            break
        }
    }
    return d.trimmingCharacters(in: .whitespaces)
}

/// Composed y-up wordmark path plus metrics.
private func wordmarkPathAndMetrics(_ text: String, font: CTFont)
    -> (path: CGPath, width: CGFloat, height: CGFloat, ascent: CGFloat, descent: CGFloat, capHeight: CGFloat) {
    let attrString = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attrString)
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    let path = CGMutablePath()
    for run in runs {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRangeMake(0, 0), &glyphs)
        CTRunGetPositions(run, CFRangeMake(0, 0), &positions)
        for i in 0..<count {
            if let gp = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
                path.addPath(gp, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
            }
        }
    }
    return (path, width, ascent + descent + leading, ascent, descent, CTFontGetCapHeight(font))
}

/// The five mark rects as SVG elements.
private func markSVG(scale: CGFloat, offset: CGPoint, fill: String, squareCaps: Bool) -> String {
    var out = ""
    for r in markRects {
        let x = svgNumber(offset.x + r.x * scale)
        let y = svgNumber(offset.y + r.y * scale)
        let w = svgNumber(r.w * scale)
        let h = svgNumber(r.h * scale)
        let rx = squareCaps ? "" : " rx=\"\(svgNumber(r.rx * scale))\""
        out += "  <rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\"\(rx) fill=\"\(fill)\"/>" + "\n"
    }
    return out
}

/// Horizontal lockup SVG with outlined wordmark (mark height = cap height, gap 2 modules).
private func horizontalLockupSVG(fill: String) -> String {
    let height: CGFloat = 96
    let fontSize = height * 0.45
    guard let font = plexFont(weight: "semibold", size: fontSize) else { fatalError() }
    let m = wordmarkPathAndMetrics("Homan", font: font)
    let bounds = m.path.boundingBoxOfPath
    let layout = lockupDims(
        markPaintedHeight: m.capHeight,
        wordmarkContentTop: 0,
        wordmarkContentBottom: bounds.maxY - bounds.minY,
        wordmarkWidth: m.width
    )
    // Flip the y-up wordmark path into the SVG y-down space; its top lands at
    // layout.wordmarkOrigin.y (the top clear-space edge).
    var transform = CGAffineTransform(
        a: 1, b: 0, c: 0, d: -1,
        tx: layout.wordmarkOrigin.x,
        ty: layout.wordmarkOrigin.y + bounds.maxY
    )
    let flipped = m.path
    let wordmarkPath = flipped.copy(using: &transform) ?? m.path
    let d = cgPathToSVGD(wordmarkPath)
    let mark = markSVG(scale: layout.scale, offset: layout.markOffset, fill: fill, squareCaps: false)
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(svgNumber(layout.width)) \(svgNumber(layout.height))">
    \(mark)  <path d="\(d)" fill="\(fill)"/>
    </svg>
    """
}

/// Stacked lockup SVG (mark centered over wordmark, gap 3 modules).
private func stackedLockupSVG(fill: String) -> String {
    let width: CGFloat = 240
    let fontSize = width * 0.16
    guard let font = plexFont(weight: "semibold", size: fontSize) else { fatalError() }
    let m = wordmarkPathAndMetrics("Homan", font: font)
    let markScale = width * 0.30 / 40.0
    let markSize = 40.0 * markScale
    let gap = 12.0 * markScale
    let clear = 8.0 * markScale
    let markOffset = CGPoint(x: (width - markSize) / 2.0, y: clear - 4.0 * markScale)
    let wmX = (width - m.width) / 2.0
    let wmY = markOffset.y + 36.0 * markScale + gap  // below mark painted bottom
    let height = wmY + m.height + clear
    let bounds = m.path.boundingBoxOfPath
    var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: wmX, ty: wmY + bounds.maxY)
    let flipped = m.path
    let wordmarkPath = flipped.copy(using: &transform) ?? m.path
    let d = cgPathToSVGD(wordmarkPath)
    let mark = markSVG(scale: markScale, offset: markOffset, fill: fill, squareCaps: false)
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(svgNumber(width)) \(svgNumber(height))">
    \(mark)  <path d="\(d)" fill="\(fill)"/>
    </svg>
    """
}

private func runGenerateLockups() throws {
    let brandDir = repoRoot().appendingPathComponent("assets/brand")
    let horizontal = horizontalLockupSVG(fill: "#F4F2EE")
    try horizontal.write(to: brandDir.appendingPathComponent("homan-lockup-horizontal.svg"), atomically: true, encoding: .utf8)
    let stacked = stackedLockupSVG(fill: "#F4F2EE")
    try stacked.write(to: brandDir.appendingPathComponent("homan-lockup-stacked.svg"), atomically: true, encoding: .utf8)
    print("wrote lockup SVGs to \(brandDir.path)")
}

// MARK: - Generator plumbing

enum GeneratorError: Error, CustomStringConvertible {
    case cannotWrite(String)
    var description: String {
        switch self {
        case .cannotWrite(let p): return "cannot write \(p)"
        }
    }
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
}

private func candidateRoot() -> URL {
    repoRoot().appendingPathComponent("build/brand-review/candidate")
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw GeneratorError.cannotWrite(url.path)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw GeneratorError.cannotWrite(url.path)
    }
}

private func runGenerateReview() throws {
    let root = candidateRoot()
    let iconSizes: [(Int, String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]
    for (size, name) in iconSizes {
        try writePNG(appIconImage(size: size), to: root.appendingPathComponent("app-icon/\(name)"))
    }
    try writePNG(appIconImage(size: 1024), to: root.appendingPathComponent("app-icon/homan-app-icon-1024.png"))
    try writePNG(menuTemplateImage(size: 16), to: root.appendingPathComponent("menu/menu-template.png"))
    try writePNG(menuTemplateImage(size: 32), to: root.appendingPathComponent("menu/menu-template@2x.png"))
    try writePNG(
        horizontalLockupImage(height: 120, wordmarkColor: paper),
        to: root.appendingPathComponent("lockup/lockup-horizontal.png")
    )
    let lockupDir = root.appendingPathComponent("lockup")
    try horizontalLockupSVG(fill: "#F4F2EE").write(
        to: lockupDir.appendingPathComponent("homan-lockup-horizontal.svg"),
        atomically: true, encoding: .utf8
    )
    try writePNG(
        stackedLockupImage(width: 320, wordmarkColor: paper),
        to: root.appendingPathComponent("lockup/lockup-stacked.png")
    )
    try stackedLockupSVG(fill: "#F4F2EE").write(
        to: lockupDir.appendingPathComponent("homan-lockup-stacked.svg"),
        atomically: true, encoding: .utf8
    )
    try writePNG(
        typographySample(width: 800, color: paper),
        to: root.appendingPathComponent("typography/typography-sample.png")
    )
    try writePNG(
        ogImage(),
        to: root.appendingPathComponent("social/repository-open-graph.png")
    )
    try writeReviewIndex()
    print("wrote candidates under \(root.path)")
}

private func writeReviewIndex() throws {
    let root = candidateRoot()
    let index = """
    <!doctype html><html><head><meta charset="utf-8"><title>Homan Brand Review</title>
    <style>body{background:#101013;color:#F4F2EE;font-family:system-ui;margin:40px}
    h1{font-weight:600} img{background:#1F1F24;border-radius:12px;margin:8px;max-width:220px}
    section{margin:24px 0}</style></head><body>
    <h1>Homan Brand Review — candidates</h1>
    <section><h2>App icon</h2>
    <img src="../app-icon/icon_512x512.png">
    <img src="../app-icon/homan-app-icon-1024.png">
    </section>
    <section><h2>Menu template</h2>
    <img src="../menu/menu-template.png">
    </section>
    <section><h2>Lockups</h2>
    <img src="../lockup/lockup-horizontal.png">
    <img src="../lockup/lockup-stacked.png" style="background:#101013">
    <p style="color:#8E8C94">SVG masters (outlined wordmark, no live text):</p>
    <img src="../lockup/homan-lockup-horizontal.svg">
    <img src="../lockup/homan-lockup-stacked.svg" style="background:#101013">
    </section>
    <section><h2>Typography</h2>
    <img src="../typography/typography-sample.png" style="max-width:600px">
    </section>
    <section><h2>Repository OG</h2>
    <img src="../social/repository-open-graph.png" style="max-width:640px">
    </section>
    </body></html>
    """
    let reviewDir = root.appendingPathComponent("review")
    try FileManager.default.createDirectory(at: reviewDir, withIntermediateDirectories: true)
    try index.write(to: reviewDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
}

private func runVerifyAssets() throws {
    let root = candidateRoot()
    let required = [
        "app-icon/icon_16x16.png", "app-icon/icon_512x512@2x.png",
        "menu/menu-template.png", "menu/menu-template@2x.png",
        "lockup/lockup-horizontal.png",
    ]
    for rel in required {
        let url = root.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fputs("verify FAIL: missing \(rel)\n", stderr)
            exit(1)
        }
    }
    print("verify-assets OK")
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: homan-brand-assets generate-lockups | generate-review | verify-assets | --self-check\n", stderr)
    exit(2)
}
do {
    switch args[1] {
    case "generate-lockups":
        try runGenerateLockups()
    case "generate-review":
        try runGenerateReview()
    case "verify-assets":
        try runVerifyAssets()
    case "--self-check":
        print("homan-brand-assets self-check ok")
    default:
        fputs("unknown command \(args[1])\n", stderr)
        exit(2)
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}

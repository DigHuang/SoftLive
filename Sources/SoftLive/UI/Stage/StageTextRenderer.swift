import AppKit
import CoreText

/// CoreText measurement, centered glyph outlines, and glow bitmap rendering.
enum StageTextRenderer {
    /// Extracts the combined CoreText vector `CGPath` for a word's glyphs centered in `boxSize`.
    static func glyphPath(for text: String, font: NSFont, in boxSize: CGSize) -> CGPath {
        let combined = CGMutablePath()
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineW = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        let originX = floor((boxSize.width - lineW) / 2)
        let baselineY = floor((boxSize.height - (ascent + descent)) / 2 + descent)

        let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = (attrs[kCTFontAttributeName] as! CTFont?) ?? (font as CTFont)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, count), &positions)
            for i in 0..<count {
                if let gp = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                    let transform = CGAffineTransform(translationX: originX + positions[i].x, y: baselineY + positions[i].y)
                    combined.addPath(gp, transform: transform)
                }
            }
        }
        return combined
    }

    static func measureWord(_ text: String, font: NSFont) -> CGSize {
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        return CGSize(width: max(4, ceil(width)), height: max(4, ceil(ascent + descent)))
    }

    static func rasterizeWord(
        _ text: String,
        font: NSFont,
        size: CGSize,
        scale: CGFloat,
        color: NSColor,
        glowColor: NSColor,
        glowBlur: CGFloat
    ) -> CGImage? {
        let pixelW = max(1, Int(ceil(size.width * scale)))
        let pixelH = max(1, Int(ceil(size.height * scale)))
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.scaleBy(x: scale, y: scale)
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        let ctLine = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let rawW = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        let textScale = rawW > 0 ? min(1, max(0.5, (size.width - 16) / rawW)) : 1
        let drawW = rawW * textScale
        let originX = floor((size.width - drawW) / 2)
        let baselineY = floor((size.height - (ascent + descent) * textScale) / 2 + descent * textScale)

        ctx.translateBy(x: originX, y: baselineY)
        ctx.scaleBy(x: textScale, y: textScale)
        if glowBlur > 0 {
            ctx.setShadow(offset: .zero, blur: glowBlur, color: glowColor.cgColor)
        }
        ctx.textPosition = .zero
        CTLineDraw(ctLine, ctx)
        return ctx.makeImage()
    }
}

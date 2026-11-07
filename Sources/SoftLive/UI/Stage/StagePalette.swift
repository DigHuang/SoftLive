import AppKit

/// Cohesive color palette derived from album artwork for Stage Mode's backdrop, word glow, and sparks.
struct StagePalette: Equatable {
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    let orbPrimary: NSColor
    let orbSecondary: NSColor
    let accent: NSColor

    static let fallback = StagePalette(
        backgroundTop: NSColor(deviceRed: 0.07, green: 0.09, blue: 0.16, alpha: 1),
        backgroundBottom: NSColor(deviceRed: 0.03, green: 0.04, blue: 0.08, alpha: 1),
        orbPrimary: NSColor(deviceRed: 0.24, green: 0.52, blue: 0.96, alpha: 0.42),
        orbSecondary: NSColor(deviceRed: 0.62, green: 0.28, blue: 0.92, alpha: 0.34),
        accent: NSColor(deviceRed: 0.52, green: 0.82, blue: 1.0, alpha: 1)
    )

    private static var lastCachedID: ObjectIdentifier?
    private static var lastCachedPalette: StagePalette = .fallback

    /// Returns a palette for `image`, reusing the last extracted result while the `NSImage` instance is unchanged.
    static func cached(for image: NSImage?) -> StagePalette {
        guard let image else { return .fallback }
        let id = ObjectIdentifier(image)
        if id == lastCachedID {
            return lastCachedPalette
        }
        let extracted = extract(from: image)
        lastCachedID = id
        lastCachedPalette = extracted
        return extracted
    }

    static func extract(from image: NSImage?) -> StagePalette {
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return .fallback }

        let sampleSize = 12
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return .fallback }

        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        struct Swatch {
            var r: CGFloat
            var g: CGFloat
            var b: CGFloat
            var score: CGFloat
        }

        var swatches: [Swatch] = []
        swatches.reserveCapacity(sampleSize * sampleSize)
        var avgR: CGFloat = 0
        var avgG: CGFloat = 0
        var avgB: CGFloat = 0
        let count = CGFloat(sampleSize * sampleSize)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255
            let g = CGFloat(pixels[i + 1]) / 255
            let b = CGFloat(pixels[i + 2]) / 255
            avgR += r
            avgG += g
            avgB += b

            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let delta = maxC - minC
            let sat = maxC > 0.01 ? delta / maxC : 0
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            // Prefer vibrant mid-to-bright tones and avoid near-black or washed-out white.
            let lumWeight = max(0, 1 - abs(lum - 0.58) * 1.9)
            let score = (sat * 0.75 + 0.25) * lumWeight
            swatches.append(Swatch(r: r, g: g, b: b, score: score))
        }

        avgR /= count
        avgG /= count
        avgB /= count

        swatches.sort { $0.score > $1.score }
        let primary = swatches.first ?? Swatch(r: avgR, g: avgG, b: avgB, score: 0)
        let secondary = swatches.dropFirst().first { cand in
            let dist = hypot(cand.r - primary.r, hypot(cand.g - primary.g, cand.b - primary.b))
            return dist > 0.24
        } ?? Swatch(
            r: min(1, avgR * 0.85 + 0.12),
            g: min(1, avgG * 0.75 + 0.08),
            b: min(1, avgB * 0.95 + 0.18),
            score: 0
        )

        let pColor = NSColor(deviceRed: primary.r, green: primary.g, blue: primary.b, alpha: 1)
        let sColor = NSColor(deviceRed: secondary.r, green: secondary.g, blue: secondary.b, alpha: 1)
        let boostedAccent = Self.boostedAccent(from: pColor)

        return StagePalette(
            backgroundTop: Self.mix(pColor, with: NSColor(deviceRed: 0.04, green: 0.05, blue: 0.08, alpha: 1), ratio: 0.76),
            backgroundBottom: Self.mix(sColor, with: NSColor(deviceRed: 0.02, green: 0.02, blue: 0.04, alpha: 1), ratio: 0.86),
            orbPrimary: boostedAccent.withAlphaComponent(0.40),
            orbSecondary: Self.boostedAccent(from: sColor).withAlphaComponent(0.32),
            accent: boostedAccent
        )
    }

    private static func boostedAccent(from color: NSColor) -> NSColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let targetS = min(0.85, max(0.42, s * 1.15))
        let targetB = min(1.0, max(0.84, b * 1.25))
        return NSColor(deviceHue: h, saturation: targetS, brightness: targetB, alpha: 1)
    }

    private static func mix(_ first: NSColor, with second: NSColor, ratio: CGFloat) -> NSColor {
        let a = first.usingColorSpace(.deviceRGB) ?? first
        let b = second.usingColorSpace(.deviceRGB) ?? second
        let t = min(1, max(0, ratio))
        return NSColor(
            deviceRed: a.redComponent * (1 - t) + b.redComponent * t,
            green: a.greenComponent * (1 - t) + b.greenComponent * t,
            blue: a.blueComponent * (1 - t) + b.blueComponent * t,
            alpha: 1
        )
    }
}

import AppKit

extension NSImage {
    /// The image's average color, lifted so it reads well on black, like the Dynamic Island.
    var vibrantAverageColor: NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = 8
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

        // Weight saturated, opaque pixels more so the result isn't a muddy grey.
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0.2 else { continue }
            let pr = Double(pixels[i]) / 255 / alpha
            let pg = Double(pixels[i + 1]) / 255 / alpha
            let pb = Double(pixels[i + 2]) / 255 / alpha
            let weight = (0.15 + (max(pr, pg, pb) - min(pr, pg, pb)) * 2) * alpha
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total > 0 else { return nil }

        let average = NSColor(srgbRed: min(1, r / total), green: min(1, g / total), blue: min(1, b / total), alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        average.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        if s < 0.12 { return NSColor(white: 0.92, alpha: 1) }
        return NSColor(hue: h, saturation: min(1, s * 1.15), brightness: max(0.85, v), alpha: 1)
    }
}

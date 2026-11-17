import Foundation

/// Plain sRGB color with components in `0...1`.
public struct RGBColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Picks a bar tint from album artwork.
public enum ArtworkPalette {
    private static let hueBuckets = 12

    /// Returns the dominant *vivid* color of an RGBA8 bitmap (premultiplied or straight alpha),
    /// or `nil` when the artwork is essentially grayscale.
    ///
    /// Pixels are grouped by hue and weighted by saturation × brightness, so the strongest
    /// colorful region wins instead of a muddy average of the whole cover.
    public static func accentColor(rgba: [UInt8], width: Int, height: Int) -> RGBColor? {
        let pixelCount = width * height
        guard pixelCount > 0, rgba.count >= pixelCount * 4 else { return nil }

        var weights = [Double](repeating: 0, count: hueBuckets)
        var sumR = [Double](repeating: 0, count: hueBuckets)
        var sumG = [Double](repeating: 0, count: hueBuckets)
        var sumB = [Double](repeating: 0, count: hueBuckets)

        for i in 0..<pixelCount {
            let o = i * 4
            let a = Double(rgba[o + 3]) / 255
            guard a > 0.5 else { continue }
            let r = Double(rgba[o]) / 255 / a
            let g = Double(rgba[o + 1]) / 255 / a
            let b = Double(rgba[o + 2]) / 255 / a

            let hsb = toHSB(RGBColor(red: min(1, r), green: min(1, g), blue: min(1, b)))
            guard hsb.brightness > 0.18, hsb.saturation > 0.22 else { continue }

            let weight = hsb.saturation * hsb.brightness
            let bucket = min(hueBuckets - 1, Int(hsb.hue * Double(hueBuckets)))
            weights[bucket] += weight
            sumR[bucket] += r * weight
            sumG[bucket] += g * weight
            sumB[bucket] += b * weight
        }

        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }) else { return nil }
        // Require a meaningful colorful area (~3% of fully saturated pixels).
        guard weights[best] >= Double(pixelCount) * 0.03 else { return nil }

        let w = weights[best]
        return RGBColor(
            red: min(1, sumR[best] / w),
            green: min(1, sumG[best] / w),
            blue: min(1, sumB[best] / w)
        )
    }

    /// Adjusts a color so thin bars stay readable on a Liquid Glass capsule:
    /// bright, saturated, but not neon.
    public static func legibleBarTint(_ color: RGBColor) -> RGBColor {
        var hsb = toHSB(color)
        hsb.saturation = min(0.80, max(0.40, hsb.saturation))
        hsb.brightness = max(0.88, hsb.brightness)
        return fromHSB(hsb)
    }

    struct HSB {
        var hue: Double
        var saturation: Double
        var brightness: Double
    }

    static func toHSB(_ c: RGBColor) -> HSB {
        let maxV = max(c.red, c.green, c.blue)
        let minV = min(c.red, c.green, c.blue)
        let delta = maxV - minV
        var hue = 0.0
        if delta > 0 {
            if maxV == c.red {
                hue = (c.green - c.blue) / delta
            } else if maxV == c.green {
                hue = 2 + (c.blue - c.red) / delta
            } else {
                hue = 4 + (c.red - c.green) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxV > 0 ? delta / maxV : 0
        return HSB(hue: hue, saturation: saturation, brightness: maxV)
    }

    static func fromHSB(_ hsb: HSB) -> RGBColor {
        let h = (hsb.hue - floor(hsb.hue)) * 6
        let s = hsb.saturation
        let v = hsb.brightness
        let sector = Int(h) % 6
        let f = h - floor(h)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch sector {
        case 0: return RGBColor(red: v, green: t, blue: p)
        case 1: return RGBColor(red: q, green: v, blue: p)
        case 2: return RGBColor(red: p, green: v, blue: t)
        case 3: return RGBColor(red: p, green: q, blue: v)
        case 4: return RGBColor(red: t, green: p, blue: v)
        default: return RGBColor(red: v, green: p, blue: q)
        }
    }
}

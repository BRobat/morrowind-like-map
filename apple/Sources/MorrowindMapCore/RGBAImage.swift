import Foundation

/// A plain 8-bit RGBA buffer (non-premultiplied, row-major, top-left origin).
/// All rendering happens on this type so it is identical on every platform and testable without UIKit.
public struct RGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: RGB = RGB(0, 0, 0)) {
        self.width = width
        self.height = height
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            px[i] = fill.r
            px[i + 1] = fill.g
            px[i + 2] = fill.b
        }
        self.pixels = px
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> RGB {
        get {
            let i = (y * width + x) * 4
            return RGB(pixels[i], pixels[i + 1], pixels[i + 2])
        }
        set {
            let i = (y * width + x) * 4
            pixels[i] = newValue.r
            pixels[i + 1] = newValue.g
            pixels[i + 2] = newValue.b
            pixels[i + 3] = 255
        }
    }
}

public struct RGB: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Parses "#RRGGBB".
    public init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }

    /// Float components 0...255, convenient for blending.
    public init(r: Double, g: Double, b: Double) {
        func c(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        self.init(c(r), c(g), c(b))
    }

    public var components: (Double, Double, Double) { (Double(r), Double(g), Double(b)) }

    public func scaled(_ f: Double) -> RGB {
        let (r, g, b) = components
        return RGB(r: r * f, g: g * f, b: b * f)
    }

    public static func lerp(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let (ar, ag, ab) = a.components
        let (br, bg, bb) = b.components
        return RGB(r: ar + (br - ar) * t, g: ag + (bg - ag) * t, b: ab + (bb - ab) * t)
    }
}

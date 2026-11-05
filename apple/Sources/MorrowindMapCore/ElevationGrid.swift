import Foundation

/// Elevation samples in meters for one tile, decoded from AWS Terrain Tiles (Terrarium encoding).
public struct ElevationGrid: Sendable {
    public let width: Int
    public let height: Int
    public var meters: [Float]

    public init(width: Int, height: Int, meters: [Float]) {
        precondition(meters.count == width * height)
        self.width = width
        self.height = height
        self.meters = meters
    }

    /// Terrarium: elevation = (R * 256 + G + B / 256) - 32768.
    public init(terrarium image: RGBAImage) {
        var m = [Float](repeating: 0, count: image.width * image.height)
        let px = image.pixels
        for i in 0..<m.count {
            let r = Float(px[i * 4]), g = Float(px[i * 4 + 1]), b = Float(px[i * 4 + 2])
            m[i] = r * 256 + g + b / 256 - 32768
        }
        self.init(width: image.width, height: image.height, meters: m)
    }

    @inline(__always)
    public func at(_ x: Int, _ y: Int) -> Float {
        meters[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
    }

    /// Bilinear sample at fractional pixel coordinates (pixel centres at +0.5).
    public func sample(_ fx: Double, _ fy: Double) -> Float {
        let x = fx - 0.5, y = fy - 0.5
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let tx = Float(x - Double(x0)), ty = Float(y - Double(y0))
        let a = at(x0, y0), b = at(x0 + 1, y0), c = at(x0, y0 + 1), d = at(x0 + 1, y0 + 1)
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    }

    /// Cuts out a sub-square (given in fractions of this tile) and resamples it to `size`×`size`.
    /// Used to overzoom past the source's max zoom.
    public func resampled(offsetX: Double, offsetY: Double, scale: Double, size: Int) -> ElevationGrid {
        if offsetX == 0, offsetY == 0, scale == 1, size == width, size == height { return self }
        var out = [Float](repeating: 0, count: size * size)
        let sx = Double(width) * scale / Double(size)
        let sy = Double(height) * scale / Double(size)
        for y in 0..<size {
            let fy = offsetY * Double(height) + (Double(y) + 0.5) * sy
            for x in 0..<size {
                let fx = offsetX * Double(width) + (Double(x) + 0.5) * sx
                out[y * size + x] = sample(fx, fy)
            }
        }
        return ElevationGrid(width: size, height: size, meters: out)
    }
}

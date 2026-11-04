import Foundation

/// Minimal Mapbox Vector Tile (MVT v2) decoder: enough to read water polygons, waterway lines
/// and place / POI points from OpenFreeMap (OpenMapTiles schema). No external dependencies.
public struct VectorTile: Sendable {
    public enum GeometryType: Int, Sendable {
        case unknown = 0, point = 1, lineString = 2, polygon = 3
    }

    public enum Value: Hashable, Sendable {
        case string(String), double(Double), int(Int64), bool(Bool)

        public var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }
    }

    public struct Point: Hashable, Sendable {
        public var x: Int32
        public var y: Int32
    }

    public struct Feature: Sendable {
        /// Optional feature id (OpenMapTiles derives it from the OSM id, so it is stable across zooms).
        public var id: UInt64?
        public var type: GeometryType
        public var properties: [String: Value]
        /// Paths in tile coordinates (0...extent). For polygons, each path is a closed ring;
        /// exterior rings are clockwise in screen space and holes counter-clockwise (nonzero fill handles both).
        public var paths: [[Point]]
    }

    public struct Layer: Sendable {
        public var name: String
        public var extent: Int
        public var features: [Feature]
    }

    public var layers: [String: Layer]

    public init(data: Data) throws {
        var reader = ProtobufReader([UInt8](data))
        var layers: [String: Layer] = [:]
        while let next = try reader.nextField() {
            let (field, wire) = next
            if field == 3, wire == 2 {
                let layer = try Self.decodeLayer(try reader.readBytes())
                layers[layer.name] = layer
            } else {
                try reader.skip(wire)
            }
        }
        self.layers = layers
    }

    private static func decodeLayer(_ bytes: ArraySlice<UInt8>) throws -> Layer {
        var r = ProtobufReader(bytes)
        var name = ""
        var extent = 4096
        var keys: [String] = []
        var values: [Value] = []
        var rawFeatures: [ArraySlice<UInt8>] = []
        while let next = try r.nextField() {
            let (field, wire) = next
            switch (field, wire) {
            case (1, 2): name = String(decoding: try r.readBytes(), as: UTF8.self)
            case (2, 2): rawFeatures.append(try r.readBytes())
            case (3, 2): keys.append(String(decoding: try r.readBytes(), as: UTF8.self))
            case (4, 2): values.append(try decodeValue(try r.readBytes()))
            case (5, 0): extent = Int(try r.readVarint())
            default: try r.skip(wire)
            }
        }
        let features = try rawFeatures.map { try decodeFeature($0, keys: keys, values: values) }
        return Layer(name: name, extent: extent, features: features)
    }

    private static func decodeValue(_ bytes: ArraySlice<UInt8>) throws -> Value {
        var r = ProtobufReader(bytes)
        var value = Value.bool(false)
        while let next = try r.nextField() {
            let (field, wire) = next
            switch (field, wire) {
            case (1, 2): value = .string(String(decoding: try r.readBytes(), as: UTF8.self))
            case (2, 5): value = .double(Double(Float(bitPattern: try r.readFixed32())))
            case (3, 1): value = .double(Double(bitPattern: try r.readFixed64()))
            case (4, 0), (5, 0): value = .int(Int64(bitPattern: try r.readVarint()))
            case (6, 0): value = .int(ProtobufReader.zigzag(try r.readVarint()))
            case (7, 0): value = .bool(try r.readVarint() != 0)
            default: try r.skip(wire)
            }
        }
        return value
    }

    private static func decodeFeature(_ bytes: ArraySlice<UInt8>, keys: [String], values: [Value]) throws -> Feature {
        var r = ProtobufReader(bytes)
        var id: UInt64?
        var type = GeometryType.unknown
        var tags: [UInt64] = []
        var geometry: [UInt64] = []
        while let next = try r.nextField() {
            let (field, wire) = next
            switch (field, wire) {
            case (1, 0): id = try r.readVarint()
            case (2, 2): tags = try r.readPackedVarints()
            case (3, 0): type = GeometryType(rawValue: Int(try r.readVarint())) ?? .unknown
            case (4, 2): geometry = try r.readPackedVarints()
            default: try r.skip(wire)
            }
        }
        var props: [String: Value] = [:]
        var i = 0
        while i + 1 < tags.count {
            let k = Int(tags[i]), v = Int(tags[i + 1])
            if k < keys.count, v < values.count { props[keys[k]] = values[v] }
            i += 2
        }
        return Feature(id: id, type: type, properties: props, paths: decodeGeometry(geometry))
    }

    static func decodeGeometry(_ cmds: [UInt64]) -> [[Point]] {
        var paths: [[Point]] = []
        var current: [Point] = []
        var x: Int32 = 0, y: Int32 = 0
        var i = 0
        while i < cmds.count {
            let id = cmds[i] & 0x7
            let count = Int(cmds[i] >> 3)
            i += 1
            switch id {
            case 1, 2: // MoveTo, LineTo
                for _ in 0..<count {
                    guard i + 1 < cmds.count else { return paths }
                    x &+= Int32(truncatingIfNeeded: ProtobufReader.zigzag(cmds[i]))
                    y &+= Int32(truncatingIfNeeded: ProtobufReader.zigzag(cmds[i + 1]))
                    i += 2
                    if id == 1 {
                        if !current.isEmpty { paths.append(current) }
                        current = []
                    }
                    current.append(Point(x: x, y: y))
                }
            case 7: // ClosePath
                if let first = current.first { current.append(first) }
            default:
                return paths
            }
        }
        if !current.isEmpty { paths.append(current) }
        return paths
    }
}

public enum ProtobufError: Error {
    case truncated, malformed
}

struct ProtobufReader {
    private let bytes: ArraySlice<UInt8>
    private var index: Int

    init(_ bytes: [UInt8]) { self.init(bytes[...]) }

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.index = bytes.startIndex
    }

    static func zigzag(_ n: UInt64) -> Int64 {
        Int64(bitPattern: n >> 1) ^ -Int64(bitPattern: n & 1)
    }

    mutating func nextField() throws -> (Int, Int)? {
        guard index < bytes.endIndex else { return nil }
        let key = try readVarint()
        return (Int(key >> 3), Int(key & 0x7))
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.endIndex else { throw ProtobufError.truncated }
            let b = bytes[index]
            index += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { throw ProtobufError.malformed }
        }
    }

    mutating func readBytes() throws -> ArraySlice<UInt8> {
        let len = Int(try readVarint())
        guard len >= 0, index + len <= bytes.endIndex else { throw ProtobufError.truncated }
        defer { index += len }
        return bytes[index..<index + len]
    }

    mutating func readFixed32() throws -> UInt32 {
        guard index + 4 <= bytes.endIndex else { throw ProtobufError.truncated }
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(bytes[index + k]) << (8 * k) }
        index += 4
        return v
    }

    mutating func readFixed64() throws -> UInt64 {
        guard index + 8 <= bytes.endIndex else { throw ProtobufError.truncated }
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(bytes[index + k]) << (8 * k) }
        index += 8
        return v
    }

    mutating func readPackedVarints() throws -> [UInt64] {
        var sub = ProtobufReader(try readBytes())
        var out: [UInt64] = []
        while sub.index < sub.bytes.endIndex { out.append(try sub.readVarint()) }
        return out
    }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try readVarint()
        case 1: guard index + 8 <= bytes.endIndex else { throw ProtobufError.truncated }; index += 8
        case 2: _ = try readBytes()
        case 5: guard index + 4 <= bytes.endIndex else { throw ProtobufError.truncated }; index += 4
        default: throw ProtobufError.malformed
        }
    }
}

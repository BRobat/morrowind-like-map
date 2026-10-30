#if canImport(Observation)
import Foundation
import Observation

/// App-wide owner of the fog grid: persistence, settings and change tracking.
@MainActor
@Observable
public final class FogStore {
    public private(set) var grid: FogGrid
    /// Bumped on every change so views can invalidate cached fog tiles.
    public private(set) var revision = 0

    public var revealRadiusMeters: Double {
        didSet { UserDefaults.standard.set(revealRadiusMeters, forKey: Keys.radius) }
    }

    public var style: FogStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Keys.style) }
    }

    /// Called after local imports add new cells (used to push changes to the paired device).
    @ObservationIgnored public var onLocalChange: ((FogGrid) -> Void)?

    public let fileURL: URL

    private enum Keys {
        static let radius = "fog.revealRadiusMeters"
        static let style = "fog.style"
    }

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("explored.mwfog")
        self.fileURL = url
        self.grid = (try? Data(contentsOf: url)).flatMap { try? FogGrid(serialized: $0) } ?? FogGrid()
        let r = UserDefaults.standard.double(forKey: Keys.radius)
        self.revealRadiusMeters = r > 0 ? r : FogGrid.defaultRevealRadiusMeters
        self.style = UserDefaults.standard.string(forKey: Keys.style).flatMap(FogStyle.init(rawValue:)) ?? .hidden
    }

    /// Reveals along a recorded track. Returns the number of newly explored cells.
    @discardableResult
    public func reveal(track: [GeoPoint]) -> Int {
        guard !track.isEmpty else { return 0 }
        let added = grid.reveal(track: track, radius: revealRadiusMeters)
        if added > 0 {
            commit()
            onLocalChange?(grid)
        }
        return added
    }

    /// Merges a grid from another device. Returns true if anything new arrived.
    @discardableResult
    public func merge(_ other: FogGrid) -> Bool {
        let before = grid.count
        grid.merge(other)
        guard grid.count != before else { return false }
        commit()
        return true
    }

    public func reset() {
        grid = FogGrid()
        commit()
    }

    private func commit() {
        revision += 1
        let data = grid.serialized()
        let url = fileURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
#endif

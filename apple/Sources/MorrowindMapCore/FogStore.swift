#if canImport(Observation)
import Foundation
import Observation

/// What changed in the fog since some revision, so views can redraw only the affected tiles.
public enum FogDirty: Sendable, Equatable {
    case none
    case rect(CellRect)
    case all

    public func affects(_ tile: TileID, marginCells: Int) -> Bool {
        switch self {
        case .none: return false
        case .all: return true
        case .rect(let r): return r.intersects(tile: tile, marginCells: marginCells)
        }
    }
}

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

    /// Bounds of recent changes by revision; nil bounds mean "everything" (reset).
    @ObservationIgnored private var changeLog: [(revision: Int, bounds: CellRect?)] = []
    private static let changeLogLimit = 64
    @ObservationIgnored private let writer = FogFileWriter()

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
        var bounds: CellRect?
        let added = grid.reveal(track: track, radius: revealRadiusMeters, bounds: &bounds)
        if added > 0 {
            commit(bounds)
            onLocalChange?(grid)
        }
        return added
    }

    /// Reveals many tracks with a single save, redraw and sync. The cell math runs off the main actor.
    /// Returns the number of newly explored cells.
    @discardableResult
    public func reveal(tracks: [[GeoPoint]]) async -> Int {
        let tracks = tracks.filter { !$0.isEmpty }
        guard !tracks.isEmpty else { return 0 }
        let start = grid
        let radius = revealRadiusMeters
        let (newCells, bounds) = await Task.detached(priority: .userInitiated) { () -> (Set<UInt64>, CellRect?) in
            var g = start
            var b: CellRect?
            for t in tracks { g.reveal(track: t, radius: radius, bounds: &b) }
            return (g.cells.subtracting(start.cells), b)
        }.value
        // Only the new cells are merged, so a reset or sync that happened meanwhile is respected.
        let before = grid.count
        grid.merge(FogGrid(cells: newCells))
        let added = grid.count - before
        if added > 0 {
            commit(bounds)
            onLocalChange?(grid)
        }
        return added
    }

    /// Merges a grid from another device. Returns true if anything new arrived.
    @discardableResult
    public func merge(_ other: FogGrid) -> Bool {
        let newCells = other.cells.subtracting(grid.cells)
        guard !newCells.isEmpty else { return false }
        grid.merge(FogGrid(cells: newCells))
        commit(CellRect(covering: newCells))
        return true
    }

    public func reset() {
        grid = FogGrid()
        commit(nil)
    }

    /// What changed after `revision`. Returns `.all` when the log no longer reaches back that far.
    public func dirty(since revision: Int) -> FogDirty {
        guard revision < self.revision else { return .none }
        guard let first = changeLog.first, first.revision <= revision + 1 else { return .all }
        var rect: CellRect?
        for entry in changeLog where entry.revision > revision {
            guard let b = entry.bounds else { return .all }
            rect = rect.map { $0.union(b) } ?? b
        }
        return rect.map(FogDirty.rect) ?? .none
    }

    private func commit(_ bounds: CellRect?) {
        revision += 1
        changeLog.append((revision, bounds))
        if changeLog.count > Self.changeLogLimit { changeLog.removeFirst(changeLog.count - Self.changeLogLimit) }
        let grid = self.grid, revision = self.revision, url = fileURL, writer = self.writer
        Task.detached(priority: .utility) {
            await writer.write(grid, revision: revision, to: url)
        }
    }
}

/// Serializes and saves the grid off the main actor. Skips writes older than the last one,
/// since detached tasks can run out of order.
private actor FogFileWriter {
    private var lastWritten = -1

    func write(_ grid: FogGrid, revision: Int, to url: URL) {
        guard revision > lastWritten else { return }
        lastWritten = revision
        let data = grid.serialized()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
#endif

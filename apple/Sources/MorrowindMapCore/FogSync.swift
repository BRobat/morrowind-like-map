#if canImport(WatchConnectivity)
import Foundation
import WatchConnectivity

/// Everything the iPhone and Apple Watch exchange. The same class runs on both.
///
/// - **Fog grid** (file transfer): grids are merged by set union, which is order-independent, so
///   the protocol is simply: after a local import, send the whole grid file; on receipt, merge it
///   and, if the receiver had cells the sender lacked, send the merged grid back once.
/// - **Live tracks** (`transferUserInfo`, queued and delivered even if the other app isn't
///   running): chunks of points the watch logged while exploring. The iPhone stores and reveals them.
/// - **Navigation target** (application context, latest value only): the newest change wins.
@MainActor
public final class FogSync: NSObject {
    private let store: FogStore
    private let target: TargetStore?
    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    /// Chunks sent before the session finished activating.
    private var queuedChunks: [TrackChunk] = []

    /// Called on the receiving device for each live-track chunk.
    public var onTrackChunk: ((TrackChunk) -> Void)?

    public init(store: FogStore, target: TargetStore? = nil) {
        self.store = store
        self.target = target
        super.init()
        store.onLocalChange = { [weak self] grid in self?.send(grid) }
        target?.onLocalChange = { [weak self] t, at in self?.sendTarget(t, updatedAt: at) }
        session?.delegate = self
        session?.activate()
    }

    /// Queues a live-track chunk for the paired device. Delivery is guaranteed and in order.
    public func send(_ chunk: TrackChunk) {
        guard let session else { return }
        guard session.activationState == .activated else {
            queuedChunks.append(chunk)
            return
        }
        session.transferUserInfo(chunk.userInfo)
    }

    private func sendTarget(_ t: NavigationTarget?, updatedAt: Date) {
        guard let session, session.activationState == .activated else { return }
        var context: [String: Any] = ["targetUpdatedAt": updatedAt.timeIntervalSince1970]
        if let t { context["target"] = [t.point.latitude, t.point.longitude, t.setAt.timeIntervalSince1970] }
        try? session.updateApplicationContext(context)
    }

    private func receiveContext(_ context: [String: Any]) {
        guard let target, let at = context["targetUpdatedAt"] as? Double else { return }
        var remote: NavigationTarget?
        if let v = context["target"] as? [Double], v.count == 3 {
            remote = NavigationTarget(point: GeoPoint(latitude: v[0], longitude: v[1]), setAt: Date(timeIntervalSince1970: v[2]))
        }
        target.applyRemote(remote, updatedAt: Date(timeIntervalSince1970: at))
    }

    private func didActivate() {
        if !store.grid.isEmpty { send(store.grid) }
        let chunks = queuedChunks
        queuedChunks = []
        for chunk in chunks { send(chunk) }
        if let session { receiveContext(session.receivedApplicationContext) }
        if let target, target.updatedAt.timeIntervalSince1970 > 0 { sendTarget(target.target, updatedAt: target.updatedAt) }
    }

    public func send(_ grid: FogGrid) {
        guard let session, session.activationState == .activated else { return }
        #if os(iOS)
        guard session.isPaired, session.isWatchAppInstalled else { return }
        #endif
        // Only the newest grid matters; drop transfers that haven't gone out yet.
        for transfer in session.outstandingFileTransfers { transfer.cancel() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outgoing-\(UUID().uuidString).mwfog")
        do {
            try grid.serialized().write(to: url, options: .atomic)
            session.transferFile(url, metadata: ["kind": "fog", "count": grid.count])
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func receive(_ grid: FogGrid) {
        store.merge(grid)
        if store.grid.count > grid.count { send(store.grid) }
    }
}

extension FogSync: WCSessionDelegate {
    nonisolated public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in self.didActivate() }
    }

    nonisolated public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let chunk = TrackChunk(userInfo: userInfo) else { return }
        Task { @MainActor in self.onTrackChunk?(chunk) }
    }

    nonisolated public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let context = applicationContext
        Task { @MainActor in self.receiveContext(context) }
    }

    nonisolated public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?["kind"] as? String == "fog",
              let data = try? Data(contentsOf: file.fileURL),
              let grid = try? FogGrid(serialized: data) else { return }
        Task { @MainActor in self.receive(grid) }
    }

    nonisolated public func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }

    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated public func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
#endif

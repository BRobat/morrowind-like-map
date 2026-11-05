#if canImport(WatchConnectivity)
import Foundation
import WatchConnectivity

/// Keeps the fog grid identical on iPhone and Apple Watch. The same class runs on both.
///
/// Grids are merged by set union, which is order-independent, so the protocol is simply:
/// after a local import, send the whole grid file; on receipt, merge it and, if the receiver
/// had cells the sender lacked, send the merged grid back once. Both sides then match.
@MainActor
public final class FogSync: NSObject {
    private let store: FogStore
    private let session: WCSession? = WCSession.isSupported() ? .default : nil

    public init(store: FogStore) {
        self.store = store
        super.init()
        store.onLocalChange = { [weak self] grid in self?.send(grid) }
        session?.delegate = self
        session?.activate()
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
        Task { @MainActor in
            if !self.store.grid.isEmpty { self.send(self.store.grid) }
        }
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

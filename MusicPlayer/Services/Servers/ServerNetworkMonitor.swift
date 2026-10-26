import Foundation
import Network

/// Reports meaningful network path changes (connectivity restored, or the active interface changed, e.g.
/// Wi-Fi to cellular / VPN up or down) so server sources can recover without user action. React-only: it never
/// gates requests (Apple discourages pre-flight reachability checks; requests themselves fail fast).
nonisolated final class ServerNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ServerNetworkMonitor")
    private var lastSignature: String?

    /// `onChange` runs on the main actor after the path settles as satisfied with a new interface set.
    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = path.status == .satisfied
                ? path.availableInterfaces.map { "\($0.type)" }.joined(separator: ",") + (path.usesInterfaceType(.other) ? "+vpn" : "")
                : "offline"
            defer { self.lastSignature = signature }
            guard let previous = self.lastSignature, previous != signature, path.status == .satisfied else { return }
            Task { @MainActor in
                // Let routes and DNS settle before reconnecting.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                onChange()
            }
        }
        monitor.start(queue: queue)
    }
}

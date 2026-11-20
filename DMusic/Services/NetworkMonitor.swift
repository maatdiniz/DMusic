import Foundation
import Network
import Observation

/// Estado da rede (online / celular ou hotspot) para escolher qualidade de streaming e regras de cache.
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private(set) var isOnline = true
    private(set) var isExpensive = false
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                self?.isOnline = online
                self?.isExpensive = expensive
            }
        }
        monitor.start(queue: DispatchQueue(label: "network.monitor"))
    }
}

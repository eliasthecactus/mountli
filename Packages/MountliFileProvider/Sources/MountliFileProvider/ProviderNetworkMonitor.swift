import Foundation
import MountliCore
@preconcurrency import Network

final class ProviderNetworkMonitor: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "ch.benavo.mountli.fileprovider.network")
    private let lock = NSLock()
    private var snapshot = NetworkPathSnapshot(
        isOnline: false,
        isWiFiOrWired: false,
        isExpensive: false,
        isConstrained: false,
        isCellular: false
    )

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    func requireAccess(for policy: NetworkPolicy, allowCellular: Bool) throws {
        lock.lock()
        let current = snapshot
        lock.unlock()
        guard current.allows(policy, allowCellular: allowCellular) else {
            let message =
                !allowCellular && current.isCellular
                ? "Cellular network access is blocked by your organization."
                : "The current network does not satisfy this location’s network policy."
            throw BridgeFailure(kind: .unreachable, message: message, retryable: true)
        }
    }

    private func update(_ path: NWPath) {
        let next = NetworkPathSnapshot(
            isOnline: path.status == .satisfied,
            isWiFiOrWired: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            isCellular: path.usesInterfaceType(.cellular)
        )
        lock.lock()
        snapshot = next
        lock.unlock()
    }
}

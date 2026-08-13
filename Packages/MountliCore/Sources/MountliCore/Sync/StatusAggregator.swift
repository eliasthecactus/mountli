import Foundation

public enum StatusAggregator {
    public static func mountStatus(
        enabled: Bool,
        paused: Bool,
        reachable: Bool,
        authenticated: Bool,
        activeTransfers: Int,
        retryableFailures: Int,
        nonRetryableFailures: Int,
        cachedDataUsable: Bool
    ) -> MountStatus {
        guard enabled else { return .disabled }
        if paused { return .paused }
        guard authenticated else { return .authenticationRequired }
        guard reachable else { return .offline }
        if nonRetryableFailures > 0 { return .error }
        if activeTransfers > 0 { return .transferring }
        if retryableFailures > 0, cachedDataUsable { return .degraded }
        if retryableFailures > 0 { return .connecting }
        return .online
    }

    public static func aggregate(_ states: [MountOperationalState]) -> MountStatus {
        guard !states.isEmpty else { return .disabled }
        let priority: [MountStatus: Int] = [
            .error: 90,
            .authenticationRequired: 80,
            .offline: 70,
            .degraded: 60,
            .transferring: 50,
            .connecting: 40,
            .paused: 30,
            .online: 20,
            .disabled: 10,
        ]
        return states.map(\.status).max { priority[$0, default: 0] < priority[$1, default: 0] } ?? .disabled
    }

    public static func pollingInterval(
        activeTransfers: Int,
        recentlyActive: Bool,
        policy: PollingPolicy
    ) -> Duration {
        if activeTransfers > 0 || recentlyActive { return .seconds(30) }
        switch policy {
        case .frequent: return Duration.seconds(60)
        case .automatic: return Duration.seconds(300)
        case .batterySaving: return Duration.seconds(900)
        }
    }
}

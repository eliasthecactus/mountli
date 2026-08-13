import Foundation
import MountliCore

/// Owns the process-global rclone bridge and multiplexes callbacks across File Provider domains.
/// rclone configuration and listeners are process global, so individual domain objects must not
/// replace or shut them down while another domain is active.
actor ProviderProcessRuntime {
    static let shared = ProviderProcessRuntime()

    nonisolated let client = GoRcloneClient()
    nonisolated let progressRegistry = ProviderProgressRegistry()

    private var retainCount = 0
    private var setupTask: Task<Void, Never>?
    private var changeHandlers: [String: @Sendable ([String]) async -> Void] = [:]

    func retain(vaultStore: EncryptedVaultStore, stateStore: SQLiteStore) async {
        retainCount += 1
        if setupTask == nil {
            let runtime = self
            let client = client
            setupTask = Task {
                await client.configureVaultMutations { mutation in
                    _ = try await vaultStore.applyRcloneMutation(mutation)
                }
                await client.configureProgress { operationID, completed, total in
                    Task {
                        try? await stateStore.updateOperationProgress(
                            id: operationID,
                            completedBytes: completed,
                            totalBytes: total
                        )
                        runtime.progressRegistry.update(
                            operationID: operationID,
                            completed: completed,
                            total: total
                        )
                    }
                }
                await client.configureChangeNotifications { watcherID, paths in
                    Task { await runtime.deliverChanges(watcherID: watcherID, paths: paths) }
                }
            }
        }
        await setupTask?.value
    }

    func registerChanges(
        watcherID: String,
        handler: @escaping @Sendable ([String]) async -> Void
    ) {
        changeHandlers[watcherID] = handler
    }

    func unregisterChanges(watcherID: String) {
        changeHandlers.removeValue(forKey: watcherID)
    }

    func release() async -> Bool {
        precondition(retainCount > 0, "Unbalanced provider process runtime release")
        retainCount -= 1
        guard retainCount == 0 else { return false }
        changeHandlers.removeAll()
        await client.shutdown()
        setupTask = nil
        return true
    }

    private func deliverChanges(watcherID: String, paths: [String]) async {
        guard let handler = changeHandlers[watcherID] else { return }
        await handler(paths)
    }
}

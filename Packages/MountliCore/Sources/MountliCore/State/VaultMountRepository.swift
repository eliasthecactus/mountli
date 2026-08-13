import Foundation

public actor VaultMountRepository: MountRepository {
    private let vault: any VaultStoreProtocol
    private let stateStore: SQLiteStore

    public init(vault: any VaultStoreProtocol, stateStore: SQLiteStore) {
        self.vault = vault
        self.stateStore = stateStore
    }

    public func mount(id: UUID) async throws -> MountDefinition? {
        try await vault.load().document.mounts.first { $0.id == id }
    }

    public func mounts() async throws -> [MountDefinition] {
        try await vault.load().document.mounts
    }

    public func state(mountID: UUID) async throws -> MountOperationalState? {
        try await stateStore.state(mountID: mountID)
    }

    public func setState(_ state: MountOperationalState) async throws {
        try await stateStore.setState(state)
    }
}

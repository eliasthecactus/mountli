import AppIntents
import FileProvider
import Foundation
import MountliCore

struct MountEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mount")
    static let defaultQuery = MountEntityQuery()

    let id: UUID
    let displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

struct MountEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [MountEntity] {
        let identifierSet = Set(identifiers)
        return try await MountIntentStore.shared.entities().filter { identifierSet.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MountEntity] {
        try await MountIntentStore.shared.entities()
    }
}

struct RefreshMountIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Mount"
    static let description = IntentDescription("Ask Files or Finder to refresh a Mountli location.")

    @Parameter(title: "Mount") var mount: MountEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await MountIntentStore.shared.refresh(mount.id)
        return .result(dialog: "Refreshing \(mount.displayName).")
    }
}

struct PauseMountIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Mount"
    static let description = IntentDescription("Pause new remote work for a Mountli location without removing cached files.")

    @Parameter(title: "Mount") var mount: MountEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await MountIntentStore.shared.setPaused(true, mountID: mount.id)
        return .result(dialog: "Paused \(mount.displayName).")
    }
}

struct ResumeMountIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Mount"
    static let description = IntentDescription("Resume remote work and refresh a Mountli location.")

    @Parameter(title: "Mount") var mount: MountEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await MountIntentStore.shared.setPaused(false, mountID: mount.id)
        return .result(dialog: "Resumed \(mount.displayName).")
    }
}

struct OpenMountIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Mount"
    static let description = IntentDescription("Open a Mountli location in Files or Finder.")

    @Parameter(title: "Mount") var mount: MountEntity

    func perform() async throws -> some IntentResult & OpensIntent {
        let url = try await MountIntentStore.shared.userVisibleURL(mount.id)
        return .result(opensIntent: OpenURLIntent(url))
    }
}

struct GetMountStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Mount Status"
    static let description = IntentDescription("Get the current English status of a Mountli location.")

    @Parameter(title: "Mount") var mount: MountEntity

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let status = try await MountIntentStore.shared.status(mount.id)
        return .result(value: status.label, dialog: "\(mount.displayName) is \(status.label.lowercased()).")
    }
}

struct MountliAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshMountIntent(),
            phrases: ["Refresh a mount in \(.applicationName)"],
            shortTitle: "Refresh Mount",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: PauseMountIntent(),
            phrases: ["Pause a mount in \(.applicationName)"],
            shortTitle: "Pause Mount",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeMountIntent(),
            phrases: ["Resume a mount in \(.applicationName)"],
            shortTitle: "Resume Mount",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: OpenMountIntent(),
            phrases: ["Open a mount in \(.applicationName)"],
            shortTitle: "Open Mount",
            systemImageName: "folder"
        )
        AppShortcut(
            intent: GetMountStatusIntent(),
            phrases: ["Get mount status in \(.applicationName)"],
            shortTitle: "Mount Status",
            systemImageName: "externaldrive.badge.checkmark"
        )
    }
}

private actor MountIntentStore {
    static let shared = MountIntentStore()

    func entities() async throws -> [MountEntity] {
        let snapshot = try await loadSnapshot()
        return snapshot.document.mounts
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { MountEntity(id: $0.id, displayName: $0.displayName) }
    }

    func refresh(_ mountID: UUID) async throws {
        let mount = try await mount(mountID)
        try await DomainRegistry().signalWorkingSet(for: mount)
    }

    func setPaused(_ paused: Bool, mountID: UUID) async throws {
        let mount = try await mount(mountID)
        let store = try await stateStore()
        var state = try await store.state(mountID: mount.id) ?? MountOperationalState(mountID: mount.id)
        state.isPaused = paused
        state.status = paused ? .paused : .connecting
        try await store.setState(state)
        if !paused {
            try await DomainRegistry().signalWorkingSet(for: mount)
        }
    }

    func userVisibleURL(_ mountID: UUID) async throws -> URL {
        try await DomainRegistry().userVisibleRoot(for: mount(mountID))
    }

    func status(_ mountID: UUID) async throws -> MountStatus {
        let mount = try await mount(mountID)
        let state = try await stateStore().state(mountID: mount.id)
        return state?.status ?? (mount.isEnabled ? .connecting : .disabled)
    }

    private func mount(_ id: UUID) async throws -> MountDefinition {
        let snapshot = try await loadSnapshot()
        guard let mount = snapshot.document.mounts.first(where: { $0.id == id }) else {
            throw MountIntentError.mountNotFound
        }
        return mount
    }

    private func loadSnapshot() async throws -> VaultSnapshot {
        let root = try applicationSupportRoot()
        guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: "MOUNTLIKeychainAccessGroup") as? String,
            !accessGroup.isEmpty
        else { throw MountIntentError.storageUnavailable }
        let vault = EncryptedVaultStore(
            directory: root,
            keyProvider: KeychainKeyProvider(accessGroup: accessGroup)
        )
        return try await vault.load()
    }

    private func stateStore() async throws -> SQLiteStore {
        try await SQLiteStore(databaseURL: applicationSupportRoot().appendingPathComponent("state.sqlite3"))
    }

    private func applicationSupportRoot() throws -> URL {
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.ch.benavo.mountli"
        ) {
            return group
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("MOUNTLI", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum MountIntentError: LocalizedError {
    case mountNotFound
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .mountNotFound: "The selected Mountli mount no longer exists."
        case .storageUnavailable: "Mountli storage is unavailable."
        }
    }
}

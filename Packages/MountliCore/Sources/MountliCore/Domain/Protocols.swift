import CryptoKit
import Foundation

public protocol RcloneClient: Sendable {
    func version() async -> String
    func loadVault(_ snapshot: VaultSnapshot) async throws
    func providerCatalog() async throws -> [ProviderDescriptor]
    func validate(remote: RemoteProfile, root: String) async throws
    func validateConfiguration(backendType: String, options: [String: String], root: String) async throws
    func capabilities(remote: RemoteProfile, root: String) async throws -> BackendCapabilities
    func about(remote: RemoteProfile, root: String) async throws -> QuotaUsage
    func list(remote: RemoteProfile, directory: String, pageToken: String?, pageSize: Int) async throws -> ListingPage
    func stat(remote: RemoteProfile, path: String, objectID: String?) async throws -> RemoteItem
    func download(operationID: UUID, remote: RemoteProfile, path: String, objectID: String?, destination: URL, range: Range<Int64>?) async throws
        -> TransferResult
    func upload(operationID: UUID, remote: RemoteProfile, path: String, source: URL, expectedVersion: String?) async throws -> RemoteItem
    func makeDirectory(operationID: UUID, remote: RemoteProfile, path: String) async throws
    func move(operationID: UUID, remote: RemoteProfile, source: RemoteItem, destinationPath: String, expectedDestinationVersion: String?) async throws
        -> RemoteItem
    func delete(operationID: UUID, remote: RemoteProfile, item: RemoteItem) async throws
    func configureProgress(
        _ handler: @escaping @Sendable (_ operationID: UUID, _ completed: Int64, _ total: Int64) -> Void
    ) async
    func configureChangeNotifications(
        _ handler: @escaping @Sendable (_ watcherID: String, _ paths: [String]) -> Void
    ) async
    func configureVaultMutations(
        _ handler: @escaping @Sendable (RcloneVaultMutation) async throws -> Void
    ) async
    func startChangeNotifications(watcherID: String, remote: RemoteProfile, root: String, interval: Int) async throws
    func stopChangeNotifications(watcherID: String) async

    func cancel(operationID: UUID) async
    func shutdown() async
}

public protocol VaultStoreProtocol: Sendable {
    func load() async throws -> VaultSnapshot
    func save(_ document: VaultDocument, expectedRevision: UInt64) async throws -> VaultSnapshot
    func mutate(expectedRevision: UInt64, _ mutation: @Sendable (inout VaultDocument) throws -> Void) async throws -> VaultSnapshot
}

public protocol MountRepository: Sendable {
    func mount(id: UUID) async throws -> MountDefinition?
    func mounts() async throws -> [MountDefinition]
    func state(mountID: UUID) async throws -> MountOperationalState?
    func setState(_ state: MountOperationalState) async throws
}

public protocol ItemRepository: Sendable {
    func item(id: UUID, mountID: UUID) async throws -> StoredItem?
    func item(remoteID: String, mountID: UUID) async throws -> StoredItem?
    func children(parentID: UUID?, mountID: UUID) async throws -> [StoredItem]
    func workingSet(mountID: UUID, accessedAfter: Date) async throws -> [StoredItem]
    func reconcile(
        mountID: UUID,
        parentID: UUID?,
        remoteItems: [RemoteItem],
        enumerationOwner: String?
    ) async throws -> ChangeBatch
    func update(itemID: UUID, mountID: UUID, parentID: UUID?, remoteItem: RemoteItem) async throws -> StoredItem
    @discardableResult
    func deleteItem(itemID: UUID, mountID: UUID) async throws -> [StoredItem]
    func markAccessed(itemID: UUID, mountID: UUID, at date: Date) async throws
    func setMaterialized(_ materialized: Bool, itemID: UUID, mountID: UUID) async throws
    func setPinned(_ pinned: Bool, itemID: UUID, mountID: UUID) async throws
    func changes(mountID: UUID, containerID: UUID?, after anchor: Int64, limit: Int) async throws -> JournalPage
    func workingSetChanges(mountID: UUID, after anchor: Int64, limit: Int) async throws -> JournalPage
    func currentSyncAnchor(mountID: UUID) async throws -> Int64
    func acquireEnumerationLease(mountID: UUID, containerID: UUID?, owner: String, ttl: TimeInterval) async throws -> Bool
    func renewEnumerationLease(mountID: UUID, containerID: UUID?, owner: String, ttl: TimeInterval) async throws -> Bool
    func releaseEnumerationLease(mountID: UUID, containerID: UUID?, owner: String) async throws
    func acquireOperationLease(operationID: UUID, mountID: UUID, owner: String, ttl: TimeInterval) async throws -> Bool
    func renewOperationLease(operationID: UUID, owner: String, ttl: TimeInterval) async throws -> Bool
    func releaseOperationLease(operationID: UUID, owner: String) async throws
    func pendingOperationCount(mountID: UUID) async throws -> Int
    func acquireRemovalAdmission(mountID: UUID, owner: String, ttl: TimeInterval) async throws -> Int?
    func renewRemovalAdmission(mountID: UUID, owner: String, ttl: TimeInterval) async throws -> Bool
    func releaseRemovalAdmission(mountID: UUID, owner: String) async throws
}

extension ItemRepository {
    public func reconcile(
        mountID: UUID,
        parentID: UUID?,
        remoteItems: [RemoteItem]
    ) async throws -> ChangeBatch {
        try await reconcile(
            mountID: mountID,
            parentID: parentID,
            remoteItems: remoteItems,
            enumerationOwner: nil
        )
    }
}

public protocol IssueRepository: Sendable {
    func recordIssue(_ issue: IssueRecord) async throws -> IssueRecord
    func issue(id: UUID) async throws -> IssueRecord?
    func openIssues(mountID: UUID?, limit: Int) async throws -> [IssueRecord]
    func resolveIssue(id: UUID, at date: Date) async throws -> Bool
    func requestIssueResolution(
        issueID: UUID,
        action: IssueResolutionAction,
        renameTo: String?,
        at date: Date
    ) async throws -> Bool
    func pendingIssueResolutionRequests(
        mountID: UUID?,
        limit: Int
    ) async throws -> [IssueResolutionRequest]
    func clearIssueResolutionRequest(issueID: UUID) async throws
}

public protocol OperationCancellationRepository: Sendable {
    func requestOperationCancellation(id: UUID, at date: Date) async throws -> Bool
    func isOperationCancellationRequested(id: UUID) async throws -> Bool
    func clearOperationCancellationRequest(id: UUID) async throws
}

public protocol NetworkStatusProviding: Sendable {
    func currentStatus() async -> NetworkStatus
    func updates() -> AsyncStream<NetworkStatus>
}

public protocol Clock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

public struct ContinuousClockAdapter: Clock {
    private let clock = ContinuousClock()
    public init() {}
    public func now() -> Date { .now }
    public func sleep(for duration: Duration) async throws { try await clock.sleep(for: duration) }
}

public enum NetworkStatus: Equatable, Sendable {
    case unavailable
    case available(isExpensive: Bool, isConstrained: Bool, usesWiFi: Bool)

    public func permits(_ policy: NetworkPolicy) -> Bool {
        switch (self, policy) {
        case (.unavailable, _): false
        case (.available, .allNetworks): true
        case (.available(_, _, let usesWiFi), .wifiOnly): usesWiFi
        case (.available(_, let constrained, _), .avoidConstrained): !constrained
        }
    }
}

public struct RemoteItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String { objectID ?? path }
    public var path: String
    public var name: String
    public var size: Int64
    public var modificationDate: Date
    public var isDirectory: Bool
    public var objectID: String?
    public var fingerprint: String
    public var mimeType: String?

    enum CodingKeys: String, CodingKey {
        case path
        case name
        case size
        case modificationDate = "modTime"
        case isDirectory
        case objectID
        case fingerprint
        case mimeType
    }
}

public enum StoredItemVersion {
    public static func contentVersion(for remote: RemoteItem) -> Data {
        let source = Data(
            "\(remote.objectID ?? "")\u{0}\(remote.fingerprint)\u{0}\(remote.size)\u{0}\(remote.modificationDate.timeIntervalSince1970)"
                .utf8
        )
        return Data(SHA256.hash(data: source))
    }
}

public struct ListingPage: Codable, Sendable {
    public var items: [RemoteItem]
    public var nextPageToken: String?
    public var generation: String
}

public struct TransferResult: Codable, Sendable {
    public var bytes: Int64
    public var fingerprint: String
}

public struct StoredItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var mountID: UUID
    public var parentID: UUID?
    public var remoteID: String?
    public var remotePath: String
    public var displayName: String
    public var isDirectory: Bool
    public var size: Int64
    public var modificationDate: Date
    public var contentVersion: Data
    public var metadataVersion: Data
    public var listGeneration: Int64
    public var materialized: Bool
    public var pinned: Bool
    public var lastAccessedAt: Date?
}

public struct ChangeBatch: Sendable {
    public var generation: Int64
    public var created: [StoredItem]
    public var updated: [StoredItem]
    public var deleted: [StoredItem]
}

public enum ItemRepositoryError: Error, Equatable, Sendable {
    case itemNotFound(UUID)
    case syncAnchorExpired(retainedFloor: Int64)
    case removalInProgress(UUID)
    case enumerationLeaseLost(UUID?)
}

public enum JournalChangeKind: String, Equatable, Sendable {
    case create
    case update
    case delete
}

public struct JournalChange: Sendable {
    public var sequence: Int64
    public var itemID: UUID
    public var containerID: UUID?
    public var kind: JournalChangeKind

    public init(sequence: Int64, itemID: UUID, containerID: UUID?, kind: JournalChangeKind) {
        self.sequence = sequence
        self.itemID = itemID
        self.containerID = containerID
        self.kind = kind
    }
}

public struct JournalPage: Sendable {
    public var changes: [JournalChange]
    public var nextAnchor: Int64

    public init(changes: [JournalChange], nextAnchor: Int64) {
        self.changes = changes
        self.nextAnchor = nextAnchor
    }
}

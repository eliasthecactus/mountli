import Foundation
import RcloneCore

public actor GoRcloneClient: RcloneClient {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var loadedRevision: UInt64?
    private var changeRelay: RcloneChangeRelay?
    private var progressRelay: RcloneProgressRelay?
    private var vaultMutationRelay: RcloneVaultMutationRelay?

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func version() async -> String { MountliVersion() }

    public func loadVault(_ snapshot: VaultSnapshot) async throws {
        guard loadedRevision != snapshot.revision else { return }
        let payload = BridgeVault(
            schemaVersion: snapshot.document.schemaVersion,
            revision: snapshot.revision,
            remotes: snapshot.document.remotes.map {
                BridgeRemote(engineName: $0.engineName, backendType: $0.backendType, options: $0.options)
            }
        )
        let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
        var error: NSError?
        guard MountliLoadVault(json, &error) else {
            throw error ?? BridgeFailure(kind: .internal, message: "Unable to load rclone configuration", retryable: false)
        }
        loadedRevision = snapshot.revision
    }

    public func reloadVault(_ snapshot: VaultSnapshot) async throws {
        loadedRevision = nil
        try await loadVault(snapshot)
    }

    public func providerCatalog() async throws -> [ProviderDescriptor] {
        try decode(MountliProviderCatalog(), as: [ProviderDescriptor].self)
    }

    public func validate(remote: RemoteProfile, root: String) async throws {
        let _: ValidationResult = try decode(MountliValidate(remote.engineName, root), as: ValidationResult.self)
    }

    public func validateConfiguration(
        backendType: String,
        options: [String: String],
        root: String
    ) async throws {
        let optionsJSON = String(decoding: try encoder.encode(options), as: UTF8.self)
        let _: ValidationResult = try decode(
            MountliValidateConfiguration(backendType, optionsJSON, root),
            as: ValidationResult.self
        )
    }

    public func capabilities(remote: RemoteProfile, root: String) async throws -> BackendCapabilities {
        try decode(MountliCapabilities(remote.engineName, root), as: BackendCapabilities.self)
    }

    public func about(remote: RemoteProfile, root: String) async throws -> QuotaUsage {
        try decode(MountliAbout(remote.engineName, root), as: QuotaUsage.self)
    }

    public func list(
        remote: RemoteProfile,
        directory: String,
        pageToken: String?,
        pageSize: Int
    ) async throws -> ListingPage {
        var page: ListingPage = try decode(
            MountliList(remote.engineName, directory, pageToken ?? "", pageSize),
            as: ListingPage.self
        )
        if page.nextPageToken?.isEmpty == true { page.nextPageToken = nil }
        return page
    }

    public func stat(remote: RemoteProfile, path: String, objectID: String?) async throws -> RemoteItem {
        let raw: RawRemoteItem = try decode(MountliStat(remote.engineName, path, objectID ?? ""), as: RawRemoteItem.self)
        return raw.remoteItem(fallbackPath: path)
    }

    public func download(
        operationID: UUID,
        remote: RemoteProfile,
        path: String,
        objectID: String?,
        destination: URL,
        range: Range<Int64>?
    ) async throws -> TransferResult {
        let offset = range?.lowerBound ?? 0
        let length = range.map { $0.upperBound - $0.lowerBound } ?? 0
        return try decode(
            MountliDownload(
                operationID.uuidString.lowercased(), remote.engineName, path, objectID ?? "",
                destination.path, offset, length
            ),
            as: TransferResult.self
        )
    }

    public func upload(
        operationID: UUID,
        remote: RemoteProfile,
        path: String,
        source: URL,
        expectedVersion: String?
    ) async throws -> RemoteItem {
        let raw: RawRemoteItem = try decode(
            MountliUpload(
                operationID.uuidString.lowercased(), remote.engineName, path,
                source.path, expectedVersion ?? ""
            ),
            as: RawRemoteItem.self
        )
        return raw.remoteItem(fallbackPath: path)
    }

    public func makeDirectory(operationID: UUID, remote: RemoteProfile, path: String) async throws {
        let _: PathResult = try decode(
            MountliMakeDirectory(operationID.uuidString.lowercased(), remote.engineName, path),
            as: PathResult.self
        )
    }

    public func move(
        operationID: UUID,
        remote: RemoteProfile,
        source: RemoteItem,
        destinationPath: String,
        expectedDestinationVersion: String?
    ) async throws -> RemoteItem {
        let raw: RawRemoteItem = try decode(
            MountliMove(
                operationID.uuidString.lowercased(), remote.engineName, source.path,
                source.objectID ?? "", destinationPath, source.fingerprint,
                expectedDestinationVersion ?? ""
            ),
            as: RawRemoteItem.self
        )
        return raw.remoteItem(fallbackPath: destinationPath)
    }

    public func delete(operationID: UUID, remote: RemoteProfile, item: RemoteItem) async throws {
        let _: DeleteResult = try decode(
            MountliDelete(
                operationID.uuidString.lowercased(), remote.engineName, item.path,
                item.objectID ?? "", item.fingerprint
            ),
            as: DeleteResult.self
        )
    }

    public func configureProgress(
        _ handler: @escaping @Sendable (_ operationID: UUID, _ completed: Int64, _ total: Int64) -> Void
    ) async {
        let relay = RcloneProgressRelay(handler: handler)
        progressRelay = relay
        MountliSetProgressListener(relay)
    }

    public func configureChangeNotifications(
        _ handler: @escaping @Sendable (_ watcherID: String, _ paths: [String]) -> Void
    ) async {
        let relay = RcloneChangeRelay(handler: handler)
        changeRelay = relay
        MountliSetChangeListener(relay)
    }

    public func startChangeNotifications(
        watcherID: String,
        remote: RemoteProfile,
        root: String,
        interval: Int
    ) async throws {
        let _: ChangeNotificationResult = try decode(
            MountliStartChangeNotifications(watcherID, remote.engineName, root, interval),
            as: ChangeNotificationResult.self
        )
    }

    public func configureVaultMutations(
        _ handler: @escaping @Sendable (RcloneVaultMutation) async throws -> Void
    ) async {
        let relay = RcloneVaultMutationRelay(handler: handler)
        vaultMutationRelay = relay
        MountliSetVaultMutationListener(relay)
    }

    public func stopChangeNotifications(watcherID: String) async {
        MountliStopChangeNotifications(watcherID)
    }

    public func cancel(operationID: UUID) async {
        MountliCancel(operationID.uuidString.lowercased())
    }

    public func shutdown() async {
        MountliShutdown()
        MountliSetChangeListener(nil)
        MountliSetProgressListener(nil)
        progressRelay = nil
        changeRelay = nil
        MountliSetVaultMutationListener(nil)
        vaultMutationRelay = nil
        loadedRevision = nil
    }

    private func decode<Value: Codable & Sendable>(_ json: String, as type: Value.Type) throws -> Value {
        let envelope = try decoder.decode(BridgeEnvelope<Value>.self, from: Data(json.utf8))
        return try envelope.value()
    }
}

private struct BridgeVault: Encodable {
    var schemaVersion: Int
    var revision: UInt64
    var remotes: [BridgeRemote]
}

private struct BridgeRemote: Encodable {
    var engineName: String
    var backendType: String
    var options: [String: String]
}

private struct ValidationResult: Codable, Sendable {
    var valid: Bool
    var name: String
    var root: String
}

private struct PathResult: Codable, Sendable { var path: String }

private final class RcloneProgressRelay: NSObject, MountliProgressListenerProtocol, @unchecked Sendable {
    private let handler: @Sendable (UUID, Int64, Int64) -> Void

    init(handler: @escaping @Sendable (UUID, Int64, Int64) -> Void) {
        self.handler = handler
    }

    func onProgress(_ operationID: String?, completed: Int64, total: Int64) {
        guard let operationID, let id = UUID(uuidString: operationID) else { return }
        handler(id, completed, total)
    }
}

private final class RcloneVaultMutationRelay: NSObject, MountliVaultMutationListenerProtocol, @unchecked Sendable {
    private let handler: @Sendable (RcloneVaultMutation) async throws -> Void

    init(handler: @escaping @Sendable (RcloneVaultMutation) async throws -> Void) {
        self.handler = handler
    }

    func onMutation(_ mutationJSON: String?) -> String {
        guard
            let mutationJSON,
            let mutation = try? JSONDecoder().decode(RcloneVaultMutation.self, from: Data(mutationJSON.utf8))
        else {
            return Self.response(error: "Invalid vault mutation")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let result = MutationResponseBox()
        Task {
            do {
                try await handler(mutation)
                result.set(Self.response(error: nil))
            } catch {
                result.set(Self.response(error: error.localizedDescription))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result.get()
    }

    private static func response(error: String?) -> String {
        let value = MutationCallbackEnvelope(
            schemaVersion: 1,
            error: error.map { MutationCallbackError(kind: "conflict", message: $0, retryable: true) }
        )
        let fallback = #"{"schemaVersion":1,"error":{"kind":"internal","message":"Unable to encode mutation response","retryable":false}}"#
        let data = (try? JSONEncoder().encode(value)) ?? Data(fallback.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private final class MutationResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = #"{"schemaVersion":1}"#
    func set(_ newValue: String) { lock.withLock { value = newValue } }
    func get() -> String { lock.withLock { value } }
}

private struct MutationCallbackEnvelope: Encodable {
    var schemaVersion: Int
    var error: MutationCallbackError?
}

private struct MutationCallbackError: Encodable {
    var kind: String
    var message: String
    var retryable: Bool
}

private struct ChangeNotificationResult: Codable, Sendable {
    var watcherID: String
    var native: Bool
}

private final class RcloneChangeRelay: NSObject, MountliChangeListenerProtocol, @unchecked Sendable {
    private let handler: @Sendable (String, [String]) -> Void

    init(handler: @escaping @Sendable (String, [String]) -> Void) {
        self.handler = handler
    }

    func onChange(_ watcherID: String?, pathsJSON: String?) {
        guard
            let watcherID,
            let pathsJSON,
            let paths = try? JSONDecoder().decode([String].self, from: Data(pathsJSON.utf8))
        else { return }
        handler(watcherID, paths)
    }
}

private struct DeleteResult: Codable, Sendable { var deleted: Bool }

private struct RawRemoteItem: Codable, Sendable {
    var path: String?
    var name: String?
    var size: Int64?
    var modTime: Date?
    var isDirectory: Bool?
    var objectID: String?
    var fingerprint: String?
    var mimeType: String?

    func remoteItem(fallbackPath: String) -> RemoteItem {
        let resolvedPath = path ?? fallbackPath
        return RemoteItem(
            path: resolvedPath,
            name: name ?? URL(fileURLWithPath: resolvedPath).lastPathComponent,
            size: size ?? 0,
            modificationDate: modTime ?? .distantPast,
            isDirectory: isDirectory ?? false,
            objectID: objectID,
            fingerprint: fingerprint ?? "",
            mimeType: mimeType
        )
    }
}

import CryptoKit
import Darwin
import Foundation
import Security

public enum VaultStoreError: Error, Equatable, Sendable {
    case notFound
    case keychain(OSStatus)
    case invalidEnvelope
    case integrityFailure
    case revisionConflict(expected: UInt64, actual: UInt64)
    case unsupportedSchema(Int)
    case mutationRejected(String)
}

extension VaultStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound:
            "The encrypted vault was not found."
        case .keychain(let status) where status == errSecItemNotFound:
            "The device-only vault key is missing. Open Issues to remove the inaccessible vault and start again."
        case .keychain:
            "The encrypted vault key is temporarily unavailable."
        case .invalidEnvelope, .integrityFailure:
            "The encrypted vault failed its integrity check. Open Issues to review recovery options."
        case .revisionConflict(let expected, let actual):
            "The vault changed concurrently (expected revision \(expected), found \(actual))."
        case .unsupportedSchema(let version):
            "This vault uses unsupported schema version \(version)."
        case .mutationRejected(let message):
            message
        }
    }
}

public protocol KeyMaterialProviding: Sendable {
    func loadExistingKey() throws -> SymmetricKey
    func loadOrCreateKey() throws -> SymmetricKey
    func deleteKey() throws
}

public struct KeychainKeyProvider: KeyMaterialProviding, @unchecked Sendable {
    public let service: String
    public let account: String
    public let accessGroup: String

    public init(
        service: String = "ch.benavo.mountli.vault",
        account: String = "primary",
        accessGroup: String
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func loadExistingKey() throws -> SymmetricKey {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw VaultStoreError.keychain(status) }
        guard let data = result as? Data, data.count == 32 else {
            throw VaultStoreError.keychain(errSecDecode)
        }
        return SymmetricKey(data: data)
    }
    public func loadOrCreateKey() throws -> SymmetricKey {
        do {
            return try loadExistingKey()
        } catch let VaultStoreError.keychain(status) where status == errSecItemNotFound {
            // A key is created only for a new vault. Reads never replace a missing key.
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw VaultStoreError.keychain(errSecNotAvailable)
        }
        let data = Data(bytes)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem { return try loadOrCreateKey() }
        guard addStatus == errSecSuccess else { throw VaultStoreError.keychain(addStatus) }
        return SymmetricKey(data: data)
    }

    public func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

public struct FixedKeyProvider: KeyMaterialProviding, Sendable {
    private let data: Data
    public init(data: Data) {
        precondition(data.count == 32)
        self.data = data
    }
    public func loadExistingKey() throws -> SymmetricKey { SymmetricKey(data: data) }
    public func loadOrCreateKey() throws -> SymmetricKey { SymmetricKey(data: data) }
    public func deleteKey() throws {}
}

private struct VaultMetadata: Codable, Sendable {
    let schemaVersion: Int
    let revision: UInt64
}

private struct EncryptedVaultEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let revision: UInt64
    let nonce: Data
    let ciphertext: Data
    let tag: Data
}

public struct RcloneVaultMutation: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case set
        case deleteKey
        case deleteSection
    }

    public let schemaVersion: Int
    public let expectedRevision: UInt64
    public let action: Action
    public let section: String
    public let key: String?
    public let value: String?
    public let previousValue: String?
    public let previousValuePresent: Bool?

    public init(
        schemaVersion: Int = 1,
        expectedRevision: UInt64,
        action: Action,
        section: String,
        key: String? = nil,
        value: String? = nil,
        previousValue: String? = nil,
        previousValuePresent: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.expectedRevision = expectedRevision
        self.action = action
        self.section = section
        self.key = key
        self.value = value
        self.previousValue = previousValue
        self.previousValuePresent = previousValuePresent
    }
}

public actor EncryptedVaultStore: VaultStoreProtocol {
    public static let currentSchemaVersion = 1

    private let directory: URL
    private let vaultURL: URL
    private let backupURL: URL
    private let lockURL: URL
    private let keyProvider: any KeyMaterialProviding
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, keyProvider: any KeyMaterialProviding) {
        self.directory = directory
        vaultURL = directory.appendingPathComponent("vault.bin", isDirectory: false)
        backupURL = directory.appendingPathComponent("vault.bin.backup", isDirectory: false)
        lockURL = directory.appendingPathComponent("vault.lock", isDirectory: false)
        self.keyProvider = keyProvider
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    public func load() async throws -> VaultSnapshot {
        try withFileLock {
            do {
                return try decrypt(at: vaultURL)
            } catch VaultStoreError.notFound {
                throw VaultStoreError.notFound
            } catch let error as VaultStoreError {
                switch error {
                case .keychain, .unsupportedSchema:
                    throw error
                default:
                    throw VaultStoreError.integrityFailure
                }
            } catch {
                throw VaultStoreError.integrityFailure
            }
        }
    }

    public func backupCandidate() async throws -> VaultSnapshot {
        try withFileLock {
            do {
                _ = try decrypt(at: vaultURL)
                throw VaultStoreError.mutationRejected("The primary vault is valid")
            } catch VaultStoreError.mutationRejected {
                throw VaultStoreError.mutationRejected("The primary vault is valid")
            } catch let error as VaultStoreError {
                switch error {
                case .invalidEnvelope, .integrityFailure:
                    return try decrypt(at: backupURL)
                default:
                    throw error
                }
            } catch {
                return try decrypt(at: backupURL)
            }
        }
    }

    public func restoreBackup() async throws -> VaultSnapshot {
        try withFileLock {
            let backup = try decrypt(at: backupURL)
            do {
                _ = try decrypt(at: vaultURL)
                throw VaultStoreError.mutationRejected("The primary vault is valid")
            } catch VaultStoreError.mutationRejected {
                throw VaultStoreError.mutationRejected("The primary vault is valid")
            } catch let error as VaultStoreError {
                switch error {
                case .invalidEnvelope, .integrityFailure:
                    break
                default:
                    throw error
                }
            } catch {
                // Authenticated plaintext that no longer decodes may recover only by explicit action.
            }
            let primaryRevision = (try? encryptedEnvelope(at: vaultURL).revision) ?? 0
            guard backup.revision <= UInt64.max - 2 else { throw VaultStoreError.invalidEnvelope }
            // A successful save always rotates the immediately previous primary into the backup.
            // If the damaged envelope cannot expose its revision, it was therefore backup + 1.
            let presumedPrimaryRevision = backup.revision + 1
            let highestRevision = max(primaryRevision, presumedPrimaryRevision)
            guard highestRevision < UInt64.max else { throw VaultStoreError.invalidEnvelope }
            let nextRevision = highestRevision + 1
            let data = try encryptedData(for: backup.document, revision: nextRevision)
            let corruptURL = directory.appendingPathComponent(
                "vault.bin.corrupt.\(Int(Date.now.timeIntervalSince1970))",
                isDirectory: false
            )
            guard rename(vaultURL.path, corruptURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            do {
                try atomicReplace(data, destination: vaultURL)
            } catch {
                _ = rename(corruptURL.path, vaultURL.path)
                throw error
            }
            return VaultSnapshot(revision: nextRevision, document: backup.document)
        }
    }

    public func save(_ document: VaultDocument, expectedRevision: UInt64) async throws -> VaultSnapshot {
        try withFileLock {
            try persist(document, expectedRevision: expectedRevision)
        }
    }

    public func saveMergingChanges(
        _ updated: VaultDocument,
        basedOn base: VaultSnapshot
    ) async throws -> VaultSnapshot {
        try withFileLock {
            let current = try loadOrEmpty()
            let document =
                current.revision == base.revision
                ? updated
                : try Self.mergeChanges(from: base.document, updated: updated, current: current.document)
            return try persist(document, expectedRevision: current.revision)
        }
    }

    public func mutate(
        expectedRevision: UInt64,
        _ mutation: @Sendable (inout VaultDocument) throws -> Void
    ) async throws -> VaultSnapshot {
        try withFileLock {
            let current = try loadOrEmpty()
            guard current.revision == expectedRevision else {
                throw VaultStoreError.revisionConflict(expected: expectedRevision, actual: current.revision)
            }
            var document = current.document
            try mutation(&document)
            return try persist(document, expectedRevision: expectedRevision)
        }
    }

    public func applyRcloneMutation(_ mutation: RcloneVaultMutation) async throws -> VaultSnapshot {
        let data = try encoder.encode(mutation)
        return try await applyRcloneMutation(String(decoding: data, as: UTF8.self))
    }

    public func applyRcloneMutation(_ mutationJSON: String) async throws -> VaultSnapshot {
        let mutation = try decoder.decode(RcloneVaultMutation.self, from: Data(mutationJSON.utf8))
        guard mutation.schemaVersion == Self.currentSchemaVersion else {
            throw VaultStoreError.unsupportedSchema(mutation.schemaVersion)
        }
        return try withFileLock {
            let current = try loadOrEmpty()
            if current.revision != mutation.expectedRevision {
                guard
                    mutation.action != .deleteSection,
                    let key = mutation.key,
                    let previousValuePresent = mutation.previousValuePresent,
                    let remote = current.document.remotes.first(where: { $0.engineName == mutation.section })
                else {
                    throw VaultStoreError.revisionConflict(expected: mutation.expectedRevision, actual: current.revision)
                }
                let currentValue: String?
                if key == "type" {
                    currentValue = remote.backendType
                } else {
                    currentValue = remote.options[key]
                }
                guard
                    (previousValuePresent && currentValue == mutation.previousValue)
                        || (!previousValuePresent && currentValue == nil)
                else {
                    throw VaultStoreError.revisionConflict(expected: mutation.expectedRevision, actual: current.revision)
                }
            }
            var document = current.document
            guard let index = document.remotes.firstIndex(where: { $0.engineName == mutation.section }) else {
                throw VaultStoreError.mutationRejected("Unknown remote \(mutation.section)")
            }
            switch mutation.action {
            case .set:
                guard let key = mutation.key, let value = mutation.value else {
                    throw VaultStoreError.mutationRejected("Set mutation is missing key or value")
                }
                if key == "type" {
                    document.remotes[index].backendType = value
                } else {
                    document.remotes[index].options[key] = value
                }
                document.remotes[index].updatedAt = .now
            case .deleteKey:
                guard let key = mutation.key, key != "type" else {
                    throw VaultStoreError.mutationRejected("Backend type cannot be deleted")
                }
                document.remotes[index].options.removeValue(forKey: key)
                document.remotes[index].updatedAt = .now
            case .deleteSection:
                let graph = try RemoteDependencyGraph(remotes: document.remotes)
                try graph.assertCanDelete(mutation.section)
                guard !document.mounts.contains(where: { $0.remoteID == document.remotes[index].id }) else {
                    throw VaultStoreError.mutationRejected("Remote is used by a mount")
                }
                document.remotes.remove(at: index)
            }
            return try persist(document, expectedRevision: current.revision)
        }
    }

    public func reset() async throws {
        try withFileLock {
            let contents =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )) ?? []
            for url in contents
            where
                url == vaultURL
                || url == backupURL
                || url.lastPathComponent.hasPrefix("vault.bin.corrupt.")
            {
                try FileManager.default.removeItem(at: url)
            }
            try keyProvider.deleteKey()
        }
    }

    private func loadOrEmpty() throws -> VaultSnapshot {
        do {
            return try decrypt(at: vaultURL)
        } catch VaultStoreError.notFound {
            return VaultSnapshot(revision: 0, document: VaultDocument())
        }
    }

    private static func mergeChanges(
        from base: VaultDocument,
        updated: VaultDocument,
        current: VaultDocument
    ) throws -> VaultDocument {
        guard
            base.schemaVersion == current.schemaVersion,
            updated.schemaVersion == current.schemaVersion
        else {
            throw VaultStoreError.unsupportedSchema(updated.schemaVersion)
        }

        var merged = current
        merged.settings = try mergeSettings(from: base.settings, updated: updated.settings, current: current.settings)
        merged.remotes = try mergeRemotes(from: base.remotes, updated: updated.remotes, current: current.remotes)
        merged.mounts = try mergeMounts(from: base.mounts, updated: updated.mounts, current: current.mounts)
        return merged
    }

    private static func mergeSettings(
        from base: GlobalSettings,
        updated: GlobalSettings,
        current: GlobalSettings
    ) throws -> GlobalSettings {
        var merged = current
        merged.showMenuBarExtra = try mergeValue(
            base.showMenuBarExtra,
            updated.showMenuBarExtra,
            current.showMenuBarExtra,
            label: "menu bar setting"
        )
        merged.launchAtLogin = try mergeValue(
            base.launchAtLogin,
            updated.launchAtLogin,
            current.launchAtLogin,
            label: "launch at login setting"
        )
        merged.notifications = try mergeValue(
            base.notifications,
            updated.notifications,
            current.notifications,
            label: "notification settings"
        )
        merged.maximumConcurrentTransfersIOS = try mergeValue(
            base.maximumConcurrentTransfersIOS,
            updated.maximumConcurrentTransfersIOS,
            current.maximumConcurrentTransfersIOS,
            label: "iPhone and iPad transfer limit"
        )
        merged.maximumConcurrentTransfersMacOS = try mergeValue(
            base.maximumConcurrentTransfersMacOS,
            updated.maximumConcurrentTransfersMacOS,
            current.maximumConcurrentTransfersMacOS,
            label: "Mac transfer limit"
        )
        merged.defaultNetworkPolicy = try mergeValue(
            base.defaultNetworkPolicy,
            updated.defaultNetworkPolicy,
            current.defaultNetworkPolicy,
            label: "default network policy"
        )
        merged.includeFilenamesInDiagnostics = try mergeValue(
            base.includeFilenamesInDiagnostics,
            updated.includeFilenamesInDiagnostics,
            current.includeFilenamesInDiagnostics,
            label: "diagnostics privacy setting"
        )
        return merged
    }

    private static func mergeRemotes(
        from base: [RemoteProfile],
        updated: [RemoteProfile],
        current: [RemoteProfile]
    ) throws -> [RemoteProfile] {
        let baseByID = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let updatedByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        var merged = current

        for original in base {
            guard let draft = updatedByID[original.id] else {
                merged.removeAll { $0.id == original.id }
                continue
            }
            guard let currentIndex = merged.firstIndex(where: { $0.id == original.id }) else {
                if draft != original {
                    throw concurrentChange("remote “\(original.displayName)”")
                }
                continue
            }
            if draft != original {
                merged[currentIndex] = try mergeRemote(
                    from: original,
                    updated: draft,
                    current: merged[currentIndex]
                )
            }
        }

        for draft in updated where baseByID[draft.id] == nil {
            if let existing = merged.first(where: { $0.id == draft.id }) {
                guard existing == draft else { throw concurrentChange("new remote “\(draft.displayName)”") }
            } else {
                merged.append(draft)
            }
        }
        return merged
    }

    private static func mergeRemote(
        from base: RemoteProfile,
        updated: RemoteProfile,
        current: RemoteProfile
    ) throws -> RemoteProfile {
        guard
            base.id == updated.id,
            base.id == current.id,
            base.engineName == updated.engineName,
            base.engineName == current.engineName,
            base.createdAt == updated.createdAt,
            base.createdAt == current.createdAt
        else {
            throw concurrentChange("remote identity")
        }

        let label = "remote “\(base.displayName)”"
        var merged = current
        merged.displayName = try mergeValue(base.displayName, updated.displayName, current.displayName, label: label)
        merged.backendType = try mergeValue(base.backendType, updated.backendType, current.backendType, label: label)
        merged.options = try mergeOptions(from: base.options, updated: updated.options, current: current.options, label: label)
        merged.resources = try mergeValue(base.resources, updated.resources, current.resources, label: label)
        merged.updatedAt = max(updated.updatedAt, current.updatedAt)
        return merged
    }

    private static func mergeOptions(
        from base: [String: String],
        updated: [String: String],
        current: [String: String],
        label: String
    ) throws -> [String: String] {
        var merged = current
        let keys = Set(base.keys).union(updated.keys)
        for key in keys where updated[key] != base[key] {
            guard current[key] == base[key] || current[key] == updated[key] else {
                throw concurrentChange("\(label) option “\(key)”")
            }
            if let value = updated[key] {
                merged[key] = value
            } else {
                merged.removeValue(forKey: key)
            }
        }
        return merged
    }

    private static func mergeMounts(
        from base: [MountDefinition],
        updated: [MountDefinition],
        current: [MountDefinition]
    ) throws -> [MountDefinition] {
        let baseByID = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let updatedByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        var merged = current

        for original in base {
            guard let draft = updatedByID[original.id] else {
                merged.removeAll { $0.id == original.id }
                continue
            }
            guard let currentIndex = merged.firstIndex(where: { $0.id == original.id }) else {
                if draft != original {
                    throw concurrentChange("mount “\(original.displayName)”")
                }
                continue
            }
            if draft != original {
                merged[currentIndex] = try mergeMount(
                    from: original,
                    updated: draft,
                    current: merged[currentIndex]
                )
            }
        }

        for draft in updated where baseByID[draft.id] == nil {
            if let existing = merged.first(where: { $0.id == draft.id }) {
                guard existing == draft else { throw concurrentChange("new mount “\(draft.displayName)”") }
            } else {
                merged.append(draft)
            }
        }
        return merged
    }

    private static func mergeMount(
        from base: MountDefinition,
        updated: MountDefinition,
        current: MountDefinition
    ) throws -> MountDefinition {
        guard
            base.id == updated.id,
            base.id == current.id,
            base.domainIdentifier == updated.domainIdentifier,
            base.domainIdentifier == current.domainIdentifier,
            base.remoteID == updated.remoteID,
            base.remoteID == current.remoteID
        else {
            throw concurrentChange("mount identity")
        }

        let label = "mount “\(base.displayName)”"
        var merged = current
        merged.root = try mergeValue(base.root, updated.root, current.root, label: label)
        merged.displayName = try mergeValue(base.displayName, updated.displayName, current.displayName, label: label)
        merged.readOnly = try mergeValue(base.readOnly, updated.readOnly, current.readOnly, label: label)
        merged.networkPolicy = try mergeValue(base.networkPolicy, updated.networkPolicy, current.networkPolicy, label: label)
        merged.pollingPolicy = try mergeValue(base.pollingPolicy, updated.pollingPolicy, current.pollingPolicy, label: label)
        merged.isEnabled = try mergeValue(base.isEnabled, updated.isEnabled, current.isEnabled, label: label)
        return merged
    }

    private static func mergeValue<Value: Equatable>(
        _ base: Value,
        _ updated: Value,
        _ current: Value,
        label: String
    ) throws -> Value {
        if updated == base { return current }
        if current == base || current == updated { return updated }
        throw concurrentChange(label)
    }

    private static func concurrentChange(_ label: String) -> VaultStoreError {
        .mutationRejected("The \(label) changed elsewhere. Review the current value and try again.")
    }

    private func persist(_ document: VaultDocument, expectedRevision: UInt64) throws -> VaultSnapshot {
        guard document.schemaVersion == Self.currentSchemaVersion else {
            throw VaultStoreError.unsupportedSchema(document.schemaVersion)
        }
        _ = try RemoteDependencyGraph(remotes: document.remotes)
        let current = try loadOrEmpty()
        guard current.revision == expectedRevision else {
            throw VaultStoreError.revisionConflict(expected: expectedRevision, actual: current.revision)
        }
        let nextRevision = expectedRevision + 1
        let data = try encryptedData(for: document, revision: nextRevision)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: vaultURL.path) {
            try replaceBackup(with: try Data(contentsOf: vaultURL))
        }
        try atomicReplace(data, destination: vaultURL)
        return VaultSnapshot(revision: nextRevision, document: document)
    }
    private func encryptedData(for document: VaultDocument, revision: UInt64) throws -> Data {
        guard document.schemaVersion == Self.currentSchemaVersion else {
            throw VaultStoreError.unsupportedSchema(document.schemaVersion)
        }
        let metadata = VaultMetadata(schemaVersion: Self.currentSchemaVersion, revision: revision)
        let authenticatedData = try encoder.encode(metadata)
        let plaintext = try encoder.encode(document)
        let key = try keyProvider.loadOrCreateKey()
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedData)
        let envelope = EncryptedVaultEnvelope(
            schemaVersion: metadata.schemaVersion,
            revision: metadata.revision,
            nonce: Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
        return try encoder.encode(envelope)
    }

    private func encryptedEnvelope(at url: URL) throws -> EncryptedVaultEnvelope {
        try decoder.decode(EncryptedVaultEnvelope.self, from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    private func decrypt(at url: URL) throws -> VaultSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { throw VaultStoreError.notFound }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let envelope: EncryptedVaultEnvelope
        do {
            envelope = try decoder.decode(EncryptedVaultEnvelope.self, from: data)
        } catch {
            throw VaultStoreError.invalidEnvelope
        }
        guard envelope.schemaVersion == Self.currentSchemaVersion else {
            throw VaultStoreError.unsupportedSchema(envelope.schemaVersion)
        }
        let metadata = VaultMetadata(schemaVersion: envelope.schemaVersion, revision: envelope.revision)
        let authenticatedData = try encoder.encode(metadata)
        let nonce = try AES.GCM.Nonce(data: envelope.nonce)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: envelope.ciphertext, tag: envelope.tag)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                sealed,
                using: keyProvider.loadExistingKey(),
                authenticating: authenticatedData
            )
        } catch let error as VaultStoreError {
            throw error
        } catch {
            throw VaultStoreError.integrityFailure
        }
        let document = try decoder.decode(VaultDocument.self, from: plaintext)
        guard document.schemaVersion == envelope.schemaVersion else { throw VaultStoreError.invalidEnvelope }
        return VaultSnapshot(revision: envelope.revision, document: document)
    }

    private func replaceBackup(with data: Data) throws {
        try atomicReplace(data, destination: backupURL)
    }

    private func atomicReplace(_ data: Data, destination: URL) throws {
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try protect(temporary)
            if rename(temporary.path, destination.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try synchronizeDirectory()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func synchronizeDirectory() throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

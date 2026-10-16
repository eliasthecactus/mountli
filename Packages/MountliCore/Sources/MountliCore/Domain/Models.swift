import Foundation

public enum MountStatus: String, Codable, CaseIterable, Sendable {
    case disabled
    case connecting
    case online
    case transferring
    case degraded
    case offline
    case authenticationRequired
    case paused
    case error

    public var label: String {
        switch self {
        case .disabled: "Disabled"
        case .connecting: "Connecting"
        case .online: "Online"
        case .transferring: "Transferring"
        case .degraded: "Degraded"
        case .offline: "Offline"
        case .authenticationRequired: "Authentication required"
        case .paused: "Paused"
        case .error: "Error"
        }
    }

    public var systemImage: String {
        switch self {
        case .disabled: "minus.circle"
        case .connecting: "arrow.trianglehead.2.clockwise"
        case .online: "checkmark.circle"
        case .transferring: "arrow.up.arrow.down"
        case .degraded: "exclamationmark.circle"
        case .offline: "wifi.slash"
        case .authenticationRequired, .error: "exclamationmark.triangle"
        case .paused: "pause.circle"
        }
    }
}

public enum NetworkPolicy: String, Codable, CaseIterable, Sendable {
    case allNetworks
    case wifiOnly
    case avoidConstrained
}

public struct NetworkPathSnapshot: Equatable, Sendable {
    public var isOnline: Bool
    public var isWiFiOrWired: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var isCellular: Bool

    public init(
        isOnline: Bool,
        isWiFiOrWired: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        isCellular: Bool = false
    ) {
        self.isOnline = isOnline
        self.isWiFiOrWired = isWiFiOrWired
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.isCellular = isCellular
    }

    public func allows(_ policy: NetworkPolicy) -> Bool {
        guard isOnline else { return false }
        switch policy {
        case .allNetworks:
            return true
        case .wifiOnly:
            return isWiFiOrWired
        case .avoidConstrained:
            return !isExpensive && !isConstrained
        }
    }

    public func allows(_ policy: NetworkPolicy, allowCellular: Bool) -> Bool {
        guard allowCellular || !isCellular else { return false }
        return allows(policy)
    }
}

public enum PollingPolicy: String, Codable, CaseIterable, Sendable {
    case automatic
    case frequent
    case batterySaving
}

public struct ManagedResourceReference: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case securityScopedDirectory
        case sshPrivateKey
        case sshPublicKey
        case knownHosts
        case clientCertificate
        case clientPrivateKey
        case serviceAccount
        case customCA
        case configurationFile
        case credentialCache
        case backendData
    }

    public let id: UUID
    public var kind: Kind
    public var displayName: String
    public var originalFilename: String
    public var bookmark: Data?
    public var encryptedPayload: Data?
    public var originalPath: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        displayName: String,
        originalFilename: String,
        bookmark: Data? = nil,
        encryptedPayload: Data? = nil,
        originalPath: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.originalFilename = originalFilename
        self.bookmark = bookmark
        self.encryptedPayload = encryptedPayload
        self.originalPath = originalPath
        self.createdAt = createdAt
    }
}

public struct RemoteProfile: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let engineName: String
    public var displayName: String
    public var backendType: String
    public var options: [String: String]
    public var resources: [ManagedResourceReference]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        engineName: String,
        displayName: String,
        backendType: String,
        options: [String: String] = [:],
        resources: [ManagedResourceReference] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.engineName = engineName
        self.displayName = displayName
        self.backendType = backendType
        self.options = options
        self.resources = resources
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func make(
        displayName: String,
        backendType: String,
        options: [String: String] = [:],
        id: UUID = UUID()
    ) -> RemoteProfile {
        RemoteProfile(
            id: id,
            engineName: EngineName.make(displayName: displayName, id: id),
            displayName: displayName,
            backendType: backendType,
            options: options
        )
    }
}

public enum EngineName {
    public static func make(displayName: String, id: UUID) -> String {
        let folded = displayName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let slug = folded.unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.append(Character(String(scalar).lowercased()))
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let prefix = slug.isEmpty ? "remote" : String(slug.prefix(40))
        let suffix = id.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(6)
        return "\(prefix)-\(suffix)"
    }
}

public struct MountDefinition: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let domainIdentifier: String
    public let remoteID: UUID
    public var root: String
    public var displayName: String
    public var readOnly: Bool
    public var networkPolicy: NetworkPolicy
    public var pollingPolicy: PollingPolicy
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        remoteID: UUID,
        root: String = "",
        displayName: String,
        readOnly: Bool = false,
        networkPolicy: NetworkPolicy = .allNetworks,
        pollingPolicy: PollingPolicy = .automatic,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.domainIdentifier = "mountli.\(id.uuidString.lowercased())"
        self.remoteID = remoteID
        self.root = root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.displayName = displayName
        self.readOnly = readOnly
        self.networkPolicy = networkPolicy
        self.pollingPolicy = pollingPolicy
        self.isEnabled = isEnabled
    }
}

public struct NotificationSettings: Codable, Hashable, Sendable {
    public var actionRequired: Bool
    public var transferCompleted: Bool

    public init(actionRequired: Bool = false, transferCompleted: Bool = false) {
        self.actionRequired = actionRequired
        self.transferCompleted = transferCompleted
    }
}

public struct GlobalSettings: Codable, Hashable, Sendable {
    public var showMenuBarExtra: Bool
    public var launchAtLogin: Bool
    public var notifications: NotificationSettings
    public var maximumConcurrentTransfersIOS: Int
    public var maximumConcurrentTransfersMacOS: Int
    public var defaultNetworkPolicy: NetworkPolicy
    public var includeFilenamesInDiagnostics: Bool

    public init(
        showMenuBarExtra: Bool = true,
        launchAtLogin: Bool = false,
        notifications: NotificationSettings = .init(),
        maximumConcurrentTransfersIOS: Int = 2,
        maximumConcurrentTransfersMacOS: Int = 4,
        defaultNetworkPolicy: NetworkPolicy = .allNetworks,
        includeFilenamesInDiagnostics: Bool = false
    ) {
        self.showMenuBarExtra = showMenuBarExtra
        self.launchAtLogin = launchAtLogin
        self.notifications = notifications
        self.maximumConcurrentTransfersIOS = min(max(maximumConcurrentTransfersIOS, 1), 4)
        self.maximumConcurrentTransfersMacOS = min(max(maximumConcurrentTransfersMacOS, 1), 8)
        self.defaultNetworkPolicy = defaultNetworkPolicy
        self.includeFilenamesInDiagnostics = includeFilenamesInDiagnostics
    }
}

public struct VaultDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var remotes: [RemoteProfile]
    public var mounts: [MountDefinition]
    public var settings: GlobalSettings

    public init(
        schemaVersion: Int = 1,
        remotes: [RemoteProfile] = [],
        mounts: [MountDefinition] = [],
        settings: GlobalSettings = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.remotes = remotes
        self.mounts = mounts
        self.settings = settings
    }
}

public struct VaultSnapshot: Equatable, Sendable {
    public var revision: UInt64
    public var document: VaultDocument

    public init(revision: UInt64, document: VaultDocument) {
        self.revision = revision
        self.document = document
    }
}

public struct BackendCapabilities: Codable, Hashable, Sendable {
    public var readOnly: Bool
    public var caseInsensitive: Bool
    public var duplicateFiles: Bool
    public var readMimeType: Bool
    public var writeMimeType: Bool
    public var canHaveEmptyDirectories: Bool
    public var serverSideCopy: Bool
    public var serverSideMove: Bool
    public var serverSideDirectoryMove: Bool
    public var changeNotify: Bool
    public var paginatedList: Bool
    public var recursiveList: Bool
    public var reportsQuota: Bool
    public var precisionNanoseconds: Int64
    public var hashes: [String]

    enum CodingKeys: String, CodingKey {
        case readOnly
        case caseInsensitive
        case duplicateFiles
        case readMimeType
        case writeMimeType
        case canHaveEmptyDirectories = "emptyDirectories"
        case serverSideCopy
        case serverSideMove
        case serverSideDirectoryMove
        case changeNotify
        case paginatedList = "listP"
        case recursiveList = "listR"
        case reportsQuota = "about"
        case precisionNanoseconds
        case hashes
    }
}

public struct QuotaUsage: Codable, Hashable, Sendable {
    public var total: Int64?
    public var used: Int64?
    public var trashed: Int64?
    public var other: Int64?
    public var free: Int64?
    public var objects: Int64?
}

public struct ProviderOption: Codable, Hashable, Sendable, Identifiable {
    public struct Example: Codable, Hashable, Sendable {
        public var value: String
        public var help: String
        public var provider: String?

        enum CodingKeys: String, CodingKey {
            case value = "Value"
            case help = "Help"
            case provider = "Provider"
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            value = try values.decodeIfPresent(String.self, forKey: .value) ?? ""
            help = try values.decodeIfPresent(String.self, forKey: .help) ?? ""
            provider = try values.decodeIfPresent(String.self, forKey: .provider)
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(value, forKey: .value)
            try values.encode(help, forKey: .help)
            try values.encodeIfPresent(provider, forKey: .provider)
        }
    }

    public var id: String { name }
    public var name: String
    public var help: String
    public var groups: String?
    public var provider: String?
    public var defaultValue: String
    public var valueType: String
    public var examples: [Example]
    public var required: Bool
    public var isPassword: Bool
    public var advanced: Bool
    public var exclusive: Bool
    public var sensitive: Bool

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case help = "Help"
        case groups = "Groups"
        case provider = "Provider"
        case defaultValue = "DefaultStr"
        case valueType = "Type"
        case examples = "Examples"
        case required = "Required"
        case isPassword = "IsPassword"
        case advanced = "Advanced"
        case exclusive = "Exclusive"
        case sensitive = "Sensitive"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        help = try values.decodeIfPresent(String.self, forKey: .help) ?? ""
        groups = try values.decodeIfPresent(String.self, forKey: .groups)
        provider = try values.decodeIfPresent(String.self, forKey: .provider)
        defaultValue = try values.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        valueType = try values.decodeIfPresent(String.self, forKey: .valueType) ?? "string"
        examples = try values.decodeIfPresent([Example].self, forKey: .examples) ?? []
        required = try values.decodeIfPresent(Bool.self, forKey: .required) ?? false
        isPassword = try values.decodeIfPresent(Bool.self, forKey: .isPassword) ?? false
        advanced = try values.decodeIfPresent(Bool.self, forKey: .advanced) ?? false
        exclusive = try values.decodeIfPresent(Bool.self, forKey: .exclusive) ?? false
        sensitive = try values.decodeIfPresent(Bool.self, forKey: .sensitive) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(help, forKey: .help)
        try values.encodeIfPresent(groups, forKey: .groups)
        try values.encodeIfPresent(provider, forKey: .provider)
        try values.encode(defaultValue, forKey: .defaultValue)
        try values.encode(valueType, forKey: .valueType)
        try values.encode(examples, forKey: .examples)
        try values.encode(required, forKey: .required)
        try values.encode(isPassword, forKey: .isPassword)
        try values.encode(advanced, forKey: .advanced)
        try values.encode(exclusive, forKey: .exclusive)
        try values.encode(sensitive, forKey: .sensitive)
    }
}

public struct ProviderDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var aliases: [String]
    public var options: [ProviderOption]
    public var testOnly: Bool
    public var overlay: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case aliases
        case options
        case testOnly
        case overlay
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? name
        aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
        options = try values.decodeIfPresent([ProviderOption].self, forKey: .options) ?? []
        testOnly = try values.decodeIfPresent(Bool.self, forKey: .testOnly) ?? false
        overlay = try values.decodeIfPresent(Bool.self, forKey: .overlay) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(description, forKey: .description)
        try values.encode(aliases, forKey: .aliases)
        try values.encode(options, forKey: .options)
        try values.encode(testOnly, forKey: .testOnly)
        try values.encode(overlay, forKey: .overlay)
    }
}

public enum BridgeErrorKind: String, Codable, CaseIterable, Sendable {
    case notAuthenticated
    case unreachable
    case quotaExceeded
    case notFound
    case alreadyExists
    case permissionDenied
    case conflict
    case unsupported
    case cancelled
    case `internal`
}

public struct BridgeFailure: Error, Codable, Equatable, Sendable {
    public var kind: BridgeErrorKind
    public var message: String
    public var retryable: Bool

    public init(kind: BridgeErrorKind, message: String, retryable: Bool) {
        self.kind = kind
        self.message = message
        self.retryable = retryable
    }
}

extension BridgeFailure: LocalizedError {
    public var errorDescription: String? {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: String =
            switch kind {
            case .notAuthenticated: "The storage provider rejected the credentials. Reconnect or edit the remote."
            case .unreachable: "The storage provider could not be reached. Check the network connection and server address."
            case .quotaExceeded: "The storage provider reports that the quota is full."
            case .notFound: "The requested file or folder does not exist on the remote."
            case .alreadyExists: "An item with this name already exists on the remote."
            case .permissionDenied: "The storage provider denied access to this location."
            case .conflict: "The remote item changed while Mountli was working on it."
            case .unsupported: "This storage provider does not support that operation."
            case .cancelled: "The operation was cancelled."
            case .internal: "rclone reported an unexpected error."
            }
        guard !detail.isEmpty, detail != summary else { return summary }
        return "\(summary)\n\n\(detail)"
    }
}

public struct BridgeEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    public var schemaVersion: Int
    public var data: Value?
    public var error: BridgeFailure?

    public func value() throws -> Value {
        guard schemaVersion == 1 else {
            throw BridgeFailure(kind: .unsupported, message: "Unsupported bridge schema \(schemaVersion)", retryable: false)
        }
        if let error { throw error }
        guard let data else {
            throw BridgeFailure(kind: .internal, message: "Bridge returned no data", retryable: false)
        }
        return data
    }
}

public struct MountOperationalState: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { mountID }
    public var mountID: UUID
    public var status: MountStatus
    public var lastSuccessfulEnumeration: Date?
    public var lastErrorCode: String?
    public var pendingOperations: Int
    public var activeTransfers: Int
    public var unresolvedIssues: Int
    public var isReachable: Bool
    public var isAuthenticated: Bool
    public var isPaused: Bool
    public init(
        mountID: UUID,
        status: MountStatus = .connecting,
        lastSuccessfulEnumeration: Date? = nil,
        lastErrorCode: String? = nil,
        pendingOperations: Int = 0,
        activeTransfers: Int = 0,
        unresolvedIssues: Int = 0,
        isReachable: Bool = true,
        isAuthenticated: Bool = true,
        isPaused: Bool = false
    ) {
        self.mountID = mountID
        self.status = status
        self.lastSuccessfulEnumeration = lastSuccessfulEnumeration
        self.lastErrorCode = lastErrorCode
        self.pendingOperations = pendingOperations
        self.activeTransfers = activeTransfers
        self.unresolvedIssues = unresolvedIssues
        self.isReachable = isReachable
        self.isAuthenticated = isAuthenticated
        self.isPaused = isPaused
    }
}

public enum OperationKind: String, Codable, Sendable {
    case enumerate, download, upload, createDirectory, move, delete, refresh
}

public enum OperationOutcome: String, Codable, Sendable {
    case pending, running, succeeded, retryableFailure, failed, cancelled
}

public struct OperationRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var mountID: UUID
    public var itemID: UUID?
    public var kind: OperationKind
    public var outcome: OperationOutcome
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var startedAt: Date
    public var completedAt: Date?
    public var diagnosticCode: String?

    public init(
        id: UUID = UUID(),
        mountID: UUID,
        itemID: UUID? = nil,
        kind: OperationKind,
        outcome: OperationOutcome = .pending,
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        startedAt: Date = .now,
        completedAt: Date? = nil,
        diagnosticCode: String? = nil
    ) {
        self.id = id
        self.mountID = mountID
        self.itemID = itemID
        self.kind = kind
        self.outcome = outcome
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.diagnosticCode = diagnosticCode
    }
}

public enum IssueKind: String, Codable, Sendable {
    case authentication, quota, tls, conflict, duplicate, inaccessibleResource, vaultIntegrity, syncFailure, policy, orphanDomain
}

public struct MountliIssue: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var mountID: UUID?
    public var itemID: UUID?
    public var kind: IssueKind
    public var diagnosticCode: String
    public var impact: String
    public var createdAt: Date
    public var resolvedAt: Date?
    public var redactedPathToken: String?
}

public enum IssueResolutionAction: String, Codable, Hashable, Sendable {
    case retry
    case reconnect
    case deleteAnyway
    case keepRemote
    case deleteDuplicate
    case renameDuplicate
}

public struct IssueRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var mountID: UUID?
    public var itemID: UUID?
    public var kind: IssueKind
    public var diagnosticCode: String
    public var message: String
    public var retryable: Bool
    public var createdAt: Date
    public var resolvedAt: Date?
    public var remoteObjectID: String?
    public var remotePath: String?
    public var redactedPathToken: String?
    public var defaultRename: String?
    public var suggestedActions: [IssueResolutionAction]

    public init(
        id: UUID = UUID(),
        mountID: UUID? = nil,
        itemID: UUID? = nil,
        kind: IssueKind,
        diagnosticCode: String,
        message: String,
        retryable: Bool,
        createdAt: Date = .now,
        resolvedAt: Date? = nil,
        remoteObjectID: String? = nil,
        remotePath: String? = nil,
        redactedPathToken: String? = nil,
        defaultRename: String? = nil,
        suggestedActions: [IssueResolutionAction]
    ) {
        self.id = id
        self.mountID = mountID
        self.itemID = itemID
        self.kind = kind
        self.diagnosticCode = diagnosticCode
        self.message = message
        self.retryable = retryable
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.remoteObjectID = remoteObjectID
        self.remotePath = remotePath
        self.redactedPathToken = redactedPathToken
        self.defaultRename = defaultRename
        self.suggestedActions = suggestedActions
    }
}

public struct IssueResolutionRequest: Codable, Hashable, Sendable {
    public var issueID: UUID
    public var mountID: UUID?
    public var action: IssueResolutionAction
    public var renameTo: String?
    public var requestedAt: Date

    public init(
        issueID: UUID,
        mountID: UUID?,
        action: IssueResolutionAction,
        renameTo: String?,
        requestedAt: Date
    ) {
        self.issueID = issueID
        self.mountID = mountID
        self.action = action
        self.renameTo = renameTo
        self.requestedAt = requestedAt
    }
}

import CoreFoundation
import Foundation

public struct ManagedPolicy: Codable, Equatable, Sendable {
    public static let supportedVersion = 1

    public var policyVersion: Int
    public var allowedBackendTypes: Set<String>?
    public var allowConfigImport: Bool
    public var allowConfigExport: Bool
    public var allowInsecureTLS: Bool
    public var forceReadOnly: Bool
    public var allowCellular: Bool
    public var maximumConcurrentTransfers: Int?
    public var supportURL: URL?

    public init(
        policyVersion: Int = Self.supportedVersion,
        allowedBackendTypes: Set<String>? = nil,
        allowConfigImport: Bool = true,
        allowConfigExport: Bool = true,
        allowInsecureTLS: Bool = false,
        forceReadOnly: Bool = false,
        allowCellular: Bool = true,
        maximumConcurrentTransfers: Int? = nil,
        supportURL: URL? = nil
    ) {
        self.policyVersion = policyVersion
        self.allowedBackendTypes = allowedBackendTypes
        self.allowConfigImport = allowConfigImport
        self.allowConfigExport = allowConfigExport
        self.allowInsecureTLS = allowInsecureTLS
        self.forceReadOnly = forceReadOnly
        self.allowCellular = allowCellular
        self.maximumConcurrentTransfers = maximumConcurrentTransfers
        self.supportURL = supportURL
    }
}

public enum RemoteIdentityPolicyError: Error, Equatable, Sendable {
    case disabledSSHHostValidation

    public var diagnosticCode: String {
        switch self {
        case .disabledSSHHostValidation: "SSH_HOST_IDENTITY_DISABLED"
        }
    }
}

extension RemoteIdentityPolicyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .disabledSSHHostValidation:
            "SFTP host identity verification cannot be disabled. Choose a known_hosts file or let Mountli pin the server key on first connection."
        }
    }
}

public enum RemoteIdentityPolicy {
    public static func secureOptions(
        backendType: String,
        options: [String: String]
    ) throws -> [String: String] {
        guard backendType == "sftp" else { return options }
        var result = options
        let knownHosts = result["known_hosts_file"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if knownHosts?.lowercased() == "none" {
            throw RemoteIdentityPolicyError.disabledSSHHostValidation
        }
        let externalSSH = result["ssh"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedKeys = result["host_keys"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if knownHosts?.isEmpty != false,
            externalSSH?.isEmpty != false,
            pinnedKeys?.isEmpty != false
        {
            result["pin_host_key"] = "true"
        }
        return result
    }
}

public enum ManagedPolicyRestriction: Error, Equatable, Sendable {
    case configImportDisabled
    case configExportDisabled
    case backendNotAllowed
    case insecureTLSNotAllowed
    case readOnly

    public var diagnosticCode: String {
        switch self {
        case .configImportDisabled: "POLICY_CONFIG_IMPORT_BLOCKED"
        case .configExportDisabled: "POLICY_CONFIG_EXPORT_BLOCKED"
        case .backendNotAllowed: "POLICY_BACKEND_BLOCKED"
        case .insecureTLSNotAllowed: "POLICY_INSECURE_TLS_BLOCKED"
        case .readOnly: "POLICY_READ_ONLY"
        }
    }

    public var impact: String {
        switch self {
        case .configImportDisabled:
            "Your organization does not allow rclone configuration import."
        case .configExportDisabled:
            "Your organization does not allow rclone configuration export."
        case .backendNotAllowed:
            "This remote is blocked because its storage backend is not allowed by your organization."
        case .insecureTLSNotAllowed:
            "This remote is blocked because it disables secure TLS certificate verification."
        case .readOnly:
            "Changes are blocked because this location is read-only under the current managed policy."
        }
    }
}

extension ManagedPolicyRestriction: LocalizedError {
    public var errorDescription: String? { impact }
}

extension ManagedPolicy {
    public func violations(for remote: RemoteProfile) -> [ManagedPolicyRestriction] {
        var result: [ManagedPolicyRestriction] = []
        if let allowedBackendTypes, !allowedBackendTypes.contains(remote.backendType) {
            result.append(.backendNotAllowed)
        }
        if !allowInsecureTLS && Self.requestsInsecureTLS(remote.options) {
            result.append(.insecureTLSNotAllowed)
        }
        return result
    }

    public func requireRemoteAccess(_ remote: RemoteProfile) throws {
        if let violation = violations(for: remote).first {
            throw violation
        }
    }

    public func issues(for document: VaultDocument) -> [MountliIssue] {
        let graph = try? RemoteDependencyGraph(remotes: document.remotes)
        let remotesByID = Dictionary(uniqueKeysWithValues: document.remotes.map { ($0.id, $0) })
        return document.remotes.flatMap { remote in
            let mountIDs = document.mounts.compactMap { mount -> UUID? in
                guard let mountedRemote = remotesByID[mount.remoteID] else { return nil }
                var pending = [mountedRemote.engineName]
                var visited: Set<String> = []
                while let name = pending.popLast(), visited.insert(name).inserted {
                    if name == remote.engineName { return mount.id }
                    pending.append(contentsOf: graph?.dependencies[name] ?? [])
                }
                return nil
            }
            let affectedMountIDs: [UUID?] = mountIDs.isEmpty ? [nil] : mountIDs.map(Optional.some)
            return violations(for: remote).flatMap { violation in
                affectedMountIDs.map { mountID in
                    MountliIssue(
                        id: UUID(),
                        mountID: mountID,
                        itemID: nil,
                        kind: .policy,
                        diagnosticCode: violation.diagnosticCode,
                        impact: violation.impact,
                        createdAt: .now,
                        resolvedAt: nil,
                        redactedPathToken: nil
                    )
                }
            }
        }
    }

    public static func requestsInsecureTLS(_ options: [String: String]) -> Bool {
        let insecureKeys: Set<String> = [
            "disable_certificate_validation",
            "insecure_skip_verify",
            "insecure_tls",
            "no_check_certificate",
            "skip_certificate_verify",
            "skip_tls_verify",
            "tls_insecure_skip_verify",
            "tls_skip_verify",
        ]
        return options.contains { key, value in
            let normalizedKey = key.lowercased().replacingOccurrences(of: "-", with: "_")
            guard insecureKeys.contains(normalizedKey) else { return false }
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "on", "true", "yes":
                return true
            default:
                return false
            }
        }
    }
}

public enum ManagedPolicyCache {
    public static let suiteName = "group.ch.benavo.mountli"
    private static let policyKey = "ManagedPolicy.effective.v1"

    public static func publish(_ policy: ManagedPolicy) {
        guard
            let defaults = UserDefaults(suiteName: suiteName),
            let encoded = try? JSONEncoder().encode(policy)
        else { return }
        defaults.set(encoded, forKey: policyKey)
    }

    public static func load() -> ManagedPolicy? {
        guard
            let defaults = UserDefaults(suiteName: suiteName),
            let encoded = defaults.data(forKey: policyKey)
        else { return nil }
        return try? JSONDecoder().decode(ManagedPolicy.self, from: encoded)
    }
}

public struct ManagedPolicyResult: Sendable {
    public var policy: ManagedPolicy
    public var issues: [MountliIssue]
}

public enum ManagedPolicyReader {
    public static func parse(
        dictionary: [String: Any],
        catalog: Set<String>,
        platformTransferRange: ClosedRange<Int>
    ) -> ManagedPolicyResult {
        var policy = ManagedPolicy()
        var issues: [MountliIssue] = []

        func issue(_ code: String, _ impact: String) {
            issues.append(
                MountliIssue(
                    id: UUID(), mountID: nil, itemID: nil, kind: .policy,
                    diagnosticCode: code, impact: impact, createdAt: .now,
                    resolvedAt: nil, redactedPathToken: nil
                ))
        }

        if let value = dictionary["PolicyVersion"] {
            if let version = integer(value) {
                if version == ManagedPolicy.supportedVersion {
                    policy.policyVersion = version
                } else {
                    issue("POLICY_VERSION_UNSUPPORTED", "Managed settings use an unsupported policy version and were ignored.")
                    return ManagedPolicyResult(policy: policy, issues: issues)
                }
            } else {
                issue("POLICY_VERSION_INVALID", "Managed PolicyVersion must be an integer.")
            }
        }

        if let values = dictionary["AllowedBackendTypes"] as? [String] {
            let valid = Set(values.filter(catalog.contains))
            let invalid = Set(values).subtracting(valid)
            if !invalid.isEmpty {
                issue("POLICY_BACKEND_INVALID", "One or more managed backend names are not present in this rclone build.")
            }
            policy.allowedBackendTypes = valid
        } else if dictionary["AllowedBackendTypes"] != nil {
            issue("POLICY_BACKEND_TYPE_INVALID", "AllowedBackendTypes must be an array of backend names.")
        }

        policy.allowConfigImport = bool("AllowConfigImport", in: dictionary, default: true, issue: issue)
        policy.allowConfigExport = bool("AllowConfigExport", in: dictionary, default: true, issue: issue)
        policy.allowInsecureTLS = bool("AllowInsecureTLS", in: dictionary, default: false, issue: issue)
        policy.forceReadOnly = bool("ForceReadOnly", in: dictionary, default: false, issue: issue)
        policy.allowCellular = bool("AllowCellular", in: dictionary, default: true, issue: issue)

        if let value = dictionary["MaximumConcurrentTransfers"] {
            if let maximum = integer(value) {
                policy.maximumConcurrentTransfers = min(
                    max(maximum, platformTransferRange.lowerBound),
                    platformTransferRange.upperBound
                )
                if !platformTransferRange.contains(maximum) {
                    issue("POLICY_TRANSFER_LIMIT_CLAMPED", "Managed transfer concurrency was clamped to the supported platform range.")
                }
            } else {
                issue("POLICY_TRANSFER_LIMIT_INVALID", "MaximumConcurrentTransfers must be an integer.")
            }
        }

        if let support = dictionary["SupportURL"] as? String {
            if let url = URL(string: support), url.scheme?.lowercased() == "https", url.host != nil {
                policy.supportURL = url
            } else {
                issue("POLICY_SUPPORT_URL_INVALID", "Managed SupportURL must be a valid HTTPS URL.")
            }
        } else if dictionary["SupportURL"] != nil {
            issue("POLICY_SUPPORT_URL_TYPE_INVALID", "SupportURL must be a string.")
        }
        return ManagedPolicyResult(policy: policy, issues: issues)
    }

    private static func bool(
        _ key: String,
        in dictionary: [String: Any],
        default defaultValue: Bool,
        issue: (String, String) -> Void
    ) -> Bool {
        guard let value = dictionary[key] else { return defaultValue }
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            issue("POLICY_\(key.uppercased())_INVALID", "Managed \(key) must be true or false.")
            return defaultValue
        }
        return number.boolValue
    }

    private static func integer(_ value: Any) -> Int? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return Int(number.stringValue)
    }
}

public struct EffectiveSettings: Sendable {
    public var readOnly: Bool
    public var allowConfigImport: Bool
    public var allowConfigExport: Bool
    public var allowInsecureTLS: Bool
    public var allowCellular: Bool
    public var maximumConcurrentTransfers: Int
    public var supportURL: URL

    public init(
        userSettings: GlobalSettings,
        mount: MountDefinition,
        policy: ManagedPolicy,
        isMacOS: Bool
    ) {
        readOnly = mount.readOnly || policy.forceReadOnly
        allowConfigImport = policy.allowConfigImport
        allowConfigExport = policy.allowConfigExport
        allowInsecureTLS = policy.allowInsecureTLS
        allowCellular = policy.allowCellular
        let userLimit = isMacOS ? userSettings.maximumConcurrentTransfersMacOS : userSettings.maximumConcurrentTransfersIOS
        maximumConcurrentTransfers = policy.maximumConcurrentTransfers ?? userLimit
        supportURL = policy.supportURL ?? URL(string: "https://benavo.ch/apps/mountli")!
    }
}

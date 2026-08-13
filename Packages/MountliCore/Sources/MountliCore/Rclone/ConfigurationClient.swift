import Foundation
import RcloneCore

public struct ConfigurationStep: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case question, complete }
    public var sessionID: String
    public var status: Status
    public var state: String?
    public var message: String?
    public var engineName: String?
    public var backendType: String?
    public var options: [String: String]?
    public var option: ProviderOption?
}

public struct ImportedRemote: Codable, Sendable {
    public var engineName: String
    public var backendType: String
    public var options: [String: String]
}

public struct ImportedResourceRequirement: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(engineName)\u{1f}\(optionName)" }
    public var engineName: String
    public var backendType: String
    public var optionName: String
    public var path: String
    public var kind: String
}

public struct ConfigImportResult: Codable, Sendable {
    public var sections: [ImportedRemote]
    public var encrypted: Bool
    public var resourceRequirements: [ImportedResourceRequirement]

    private enum CodingKeys: String, CodingKey {
        case sections, encrypted, resourceRequirements
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sections = try values.decode([ImportedRemote].self, forKey: .sections)
        encrypted = try values.decode(Bool.self, forKey: .encrypted)
        resourceRequirements =
            try values.decodeIfPresent(
                [ImportedResourceRequirement].self,
                forKey: .resourceRequirements
            ) ?? []
    }
}

public protocol RcloneConfigurationClient: Sendable {
    func start(engineName: String, backendType: String, advanced: Bool) async throws -> ConfigurationStep
    func continueConfiguration(sessionID: String, answer: String) async throws -> ConfigurationStep
    func cancelConfiguration(sessionID: String) async
    func importConfig(url: URL, password: String?) async throws -> ConfigImportResult
    func exportConfig(snapshot: VaultSnapshot, password: String?, destination: URL) async throws
}

extension RcloneConfigurationClient {
    public func start(engineName: String, backendType: String) async throws -> ConfigurationStep {
        try await start(engineName: engineName, backendType: backendType, advanced: false)
    }
}

public actor GoConfigurationClient: RcloneConfigurationClient {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder = JSONDecoder()
    }

    public func start(engineName: String, backendType: String, advanced: Bool) async throws -> ConfigurationStep {
        try decode(MountliStartConfigurationAdvanced(engineName, backendType, advanced), as: ConfigurationStep.self)
    }

    public func start(
        engineName: String,
        backendType: String,
        initialOptions: [String: String],
        advanced: Bool
    ) async throws -> ConfigurationStep {
        let optionsJSON = String(decoding: try encoder.encode(initialOptions), as: UTF8.self)
        return try decode(
            MountliStartConfigurationWithOptions(engineName, backendType, optionsJSON, advanced),
            as: ConfigurationStep.self
        )
    }

    public func continueConfiguration(sessionID: String, answer: String) async throws -> ConfigurationStep {
        try decode(MountliContinueConfiguration(sessionID, answer), as: ConfigurationStep.self)
    }

    public func cancelConfiguration(sessionID: String) async {
        MountliCancelConfiguration(sessionID)
    }

    public func importConfig(url: URL, password: String?) async throws -> ConfigImportResult {
        try decode(MountliImportConfig(url.path, password ?? ""), as: ConfigImportResult.self)
    }

    public func exportConfig(snapshot: VaultSnapshot, password: String?, destination: URL) async throws {
        let bridgeVault = ExportVault(
            schemaVersion: snapshot.document.schemaVersion,
            revision: snapshot.revision,
            remotes: snapshot.document.remotes.map {
                ExportRemote(engineName: $0.engineName, backendType: $0.backendType, options: $0.options)
            }
        )
        let json = String(decoding: try encoder.encode(bridgeVault), as: UTF8.self)
        let _: ExportResult = try decode(
            MountliExportConfig(json, password ?? "", destination.path),
            as: ExportResult.self
        )
    }

    private func decode<Value: Codable & Sendable>(_ json: String, as type: Value.Type) throws -> Value {
        let envelope = try decoder.decode(BridgeEnvelope<Value>.self, from: Data(json.utf8))
        return try envelope.value()
    }
}

private struct ExportVault: Encodable {
    var schemaVersion: Int
    var revision: UInt64
    var remotes: [ExportRemote]
}

private struct ExportRemote: Encodable {
    var engineName: String
    var backendType: String
    var options: [String: String]
}

private struct ExportResult: Codable, Sendable {
    var path: String
    var encrypted: Bool
}

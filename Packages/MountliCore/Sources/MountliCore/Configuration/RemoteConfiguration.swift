import Foundation
import Security

public enum DependencyGraphError: Error, Equatable, Sendable {
    case missingDependency(remote: String, dependency: String)
    case cycle([String])
    case remoteInUse(remote: String, dependents: [String])
}

extension DependencyGraphError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingDependency(let remote, let dependency):
            "“\(remote)” refers to a remote named “\(dependency)” that does not exist."
        case .cycle(let names):
            "These remotes refer to each other in a loop: \(names.joined(separator: " → "))."
        case .remoteInUse(let remote, let dependents):
            "“\(remote)” is still used by \(dependents.joined(separator: ", ")). Remove those first."
        }
    }
}

public struct RemoteDependencyGraph: Sendable {
    public let dependencies: [String: Set<String>]

    public init(remotes: [RemoteProfile]) throws {
        let names = Set(remotes.map(\.engineName))
        var result: [String: Set<String>] = [:]
        for remote in remotes {
            var references = Set<String>()
            for value in remote.options.values {
                guard let separator = value.firstIndex(of: ":") else { continue }
                let candidate = String(value[..<separator])
                if names.contains(candidate) {
                    references.insert(candidate)
                } else if Self.isRemoteReferenceOption(value: value, backendType: remote.backendType) {
                    throw DependencyGraphError.missingDependency(remote: remote.engineName, dependency: candidate)
                }
            }
            result[remote.engineName] = references
        }
        dependencies = result
        _ = try topologicalOrder()
    }

    private static func isRemoteReferenceOption(value: String, backendType: String) -> Bool {
        let overlayBackends: Set<String> = ["alias", "archive", "cache", "chunker", "combine", "compress", "crypt", "hasher", "union"]
        return overlayBackends.contains(backendType) && value.contains(":") && !value.contains("://")
    }

    public func topologicalOrder() throws -> [String] {
        enum Mark { case temporary, permanent }
        var marks: [String: Mark] = [:]
        var order: [String] = []
        var stack: [String] = []

        func visit(_ name: String) throws {
            if marks[name] == .permanent { return }
            if marks[name] == .temporary {
                let start = stack.firstIndex(of: name) ?? stack.startIndex
                throw DependencyGraphError.cycle(Array(stack[start...]) + [name])
            }
            marks[name] = .temporary
            stack.append(name)
            for dependency in dependencies[name, default: []].sorted() {
                try visit(dependency)
            }
            _ = stack.popLast()
            marks[name] = .permanent
            order.append(name)
        }

        for name in dependencies.keys.sorted() {
            try visit(name)
        }
        return order
    }

    public func assertCanDelete(_ engineName: String) throws {
        let dependents = dependencies.compactMap { name, values in
            values.contains(engineName) ? name : nil
        }.sorted()
        guard dependents.isEmpty else {
            throw DependencyGraphError.remoteInUse(remote: engineName, dependents: dependents)
        }
    }
}

public struct CryptDraft: Sendable {
    public enum FilenameEncryption: String, CaseIterable, Sendable {
        case standard
        case obfuscate
        case off
    }

    public var baseEngineName: String
    public var root: String
    public var filenameEncryption: FilenameEncryption
    public var encryptDirectoryNames: Bool
    public var password: String
    public var secondPassword: String
    public var acknowledgedSecondPassword: Bool

    public init(
        baseEngineName: String,
        root: String,
        filenameEncryption: FilenameEncryption = .standard,
        encryptDirectoryNames: Bool = true,
        password: String,
        secondPassword: String = Self.generateSecondPassword(),
        acknowledgedSecondPassword: Bool = false
    ) {
        self.baseEngineName = baseEngineName
        self.root = root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.filenameEncryption = filenameEncryption
        self.encryptDirectoryNames = encryptDirectoryNames
        self.password = password
        self.secondPassword = secondPassword
        self.acknowledgedSecondPassword = acknowledgedSecondPassword
    }

    public func rawOptions() throws -> [String: String] {
        guard password.count >= 12 else {
            throw BridgeFailure(kind: .unsupported, message: "Use a passphrase of at least 12 characters", retryable: false)
        }
        guard acknowledgedSecondPassword else {
            throw BridgeFailure(kind: .unsupported, message: "Save the generated second password before continuing", retryable: false)
        }
        return [
            "remote": "\(baseEngineName):\(root)",
            "filename_encryption": filenameEncryption.rawValue,
            "directory_name_encryption": encryptDirectoryNames ? "true" : "false",
            "password": password,
            "password2": secondPassword,
        ]
    }

    public static func generateSecondPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure randomness is unavailable")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum LocalResourceValidator {
    public static func validateSelectedDirectory(
        _ selectedURL: URL,
        appGroupURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileProviderStorageURLs: [URL]
    ) throws {
        let candidate = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        let forbidden = [appGroupURL, temporaryDirectory] + fileProviderStorageURLs
        for root in forbidden.map({ $0.standardizedFileURL.resolvingSymlinksInPath() }) {
            if candidate == root || candidate.path.hasPrefix(root.path + "/") {
                throw BridgeFailure(
                    kind: .permissionDenied,
                    message: "Choose a directory outside Mountli, temporary, and File Provider storage",
                    retryable: false
                )
            }
        }
    }
}

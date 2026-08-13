import Foundation

public struct DiagnosticPolicy: Codable, Sendable {
    public var policyVersion: Int
    public var allowedBackendTypes: [String]?
    public var allowConfigImport: Bool
    public var allowConfigExport: Bool
    public var allowInsecureTLS: Bool
    public var forceReadOnly: Bool
    public var allowCellular: Bool
    public var maximumConcurrentTransfers: Int?
    public var supportURLConfigured: Bool

    public init(_ policy: ManagedPolicy) {
        policyVersion = policy.policyVersion
        allowedBackendTypes = policy.allowedBackendTypes?.sorted()
        allowConfigImport = policy.allowConfigImport
        allowConfigExport = policy.allowConfigExport
        allowInsecureTLS = policy.allowInsecureTLS
        forceReadOnly = policy.forceReadOnly
        allowCellular = policy.allowCellular
        maximumConcurrentTransfers = policy.maximumConcurrentTransfers
        supportURLConfigured = policy.supportURL != nil
    }
}

public struct DiagnosticMount: Codable, Sendable {
    public var backendType: String
    public var status: MountStatus
    public var pendingOperations: Int
    public var unresolvedIssues: Int
    public var capabilities: BackendCapabilities?

    public init(
        backendType: String,
        status: MountStatus,
        pendingOperations: Int,
        unresolvedIssues: Int,
        capabilities: BackendCapabilities? = nil
    ) {
        self.backendType = backendType
        self.status = status
        self.pendingOperations = pendingOperations
        self.unresolvedIssues = unresolvedIssues
        self.capabilities = capabilities
    }
}

public struct DiagnosticSnapshot: Codable, Sendable {
    public var schemaVersion: Int
    public var appVersion: String
    public var buildNumber: String
    public var rcloneVersion: String
    public var operatingSystem: String
    public var deviceClass: String
    public var policy: DiagnosticPolicy
    public var mounts: [DiagnosticMount]
    public var issueCodes: [String]
    public var operationTimingMilliseconds: [String: Double]
    public var sqliteIntegrity: String
    public var recentLogs: [String]
    public var fileNamesIncluded: Bool
    public var includedFileNames: [String]

    public init(
        appVersion: String,
        buildNumber: String,
        rcloneVersion: String,
        deviceClass: String,
        policy: ManagedPolicy,
        mounts: [DiagnosticMount],
        issueCodes: [String],
        operationTimingMilliseconds: [String: Double],
        sqliteIntegrity: String,
        recentLogs: [String],
        includedFileNames: [String] = []
    ) {
        schemaVersion = 2
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.rcloneVersion = rcloneVersion
        operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        self.deviceClass = deviceClass
        self.policy = DiagnosticPolicy(policy)
        self.mounts = mounts
        self.issueCodes = issueCodes
        self.operationTimingMilliseconds = operationTimingMilliseconds
        self.sqliteIntegrity = sqliteIntegrity
        self.recentLogs = recentLogs.suffix(2_000).map(DiagnosticsRedactor.redact)
        fileNamesIncluded = !includedFileNames.isEmpty
        self.includedFileNames = Array(includedFileNames.prefix(500))
    }
}

public enum DiagnosticsRedactor {
    public static func redact(_ input: String) -> String {
        var value =
            input
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let replacements: [(String, String)] = [
            (#"(?i)\b(?:https?|file)://[^\s]+"#, "<redacted-url>"),
            (
                #"(?i)\b(?:access[_-]?token|refresh[_-]?token|client[_-]?secret|password|secret|authorization|cookie|access[_-]?key)\b\s*[:=]\s*\"?[^\s\",}]+"#,
                "<redacted-secret>"
            ),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<redacted-email>"),
            (#"(?<![A-Za-z0-9])/(?:[^\s/]+/)*[^\s]*"#, "<redacted-path>"),
            (#"(?i)(?<![A-Za-z0-9])~/(?:[^\s/]+/)*[^\s]*"#, "<redacted-path>"),
            (#"(?i)\b[A-Z]:\\(?:[^\s\\]+\\)*[^\s]*"#, "<redacted-path>"),
        ]
        for (pattern, replacement) in replacements {
            value = value.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return String(value.prefix(2_048))
    }
}

public actor DiagnosticsExporter {
    private var temporaryExports: Set<URL> = []

    public init() {}

    public func export(_ snapshot: DiagnosticSnapshot, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try removeExpiredExports(in: directory, olderThan: 15 * 60)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(snapshot)
        let archive = ZipArchive.singleFile(name: "diagnostics.json", contents: payload)
        let destination = directory.appendingPathComponent("MOUNTLI-Diagnostics-\(UUID().uuidString).zip")
        do {
            try archive.write(
                to: destination,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDestination = destination
            try mutableDestination.setResourceValues(values)
            temporaryExports.insert(destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func finishSharing(_ url: URL) throws {
        guard temporaryExports.remove(url) != nil else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func removeExpiredExports(olderThan age: TimeInterval = 15 * 60) throws {
        let directories = Set(temporaryExports.map { $0.deletingLastPathComponent() })
        for directory in directories {
            try removeExpiredExports(in: directory, olderThan: age)
        }
    }

    private func removeExpiredExports(in directory: URL, olderThan age: TimeInterval) throws {
        let cutoff = Date.now.addingTimeInterval(-age)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls
        where url.lastPathComponent.hasPrefix("MOUNTLI-Diagnostics-")
            && url.pathExtension.lowercased() == "zip"
        {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                values?.contentModificationDate.map({ $0 < cutoff }) ?? true
            else { continue }
            try? FileManager.default.removeItem(at: url)
            temporaryExports.remove(url)
        }
    }
}

private enum ZipArchive {
    static func singleFile(name: String, contents: Data) -> Data {
        let nameData = Data(name.utf8)
        let checksum = crc32(contents)
        var local = Data()
        local.appendLittleEndian(UInt32(0x0403_4b50))
        local.appendLittleEndian(UInt16(20))
        local.appendLittleEndian(UInt16(0))
        local.appendLittleEndian(UInt16(0))
        local.appendLittleEndian(UInt16(0))
        local.appendLittleEndian(UInt16(0))
        local.appendLittleEndian(checksum)
        local.appendLittleEndian(UInt32(contents.count))
        local.appendLittleEndian(UInt32(contents.count))
        local.appendLittleEndian(UInt16(nameData.count))
        local.appendLittleEndian(UInt16(0))
        local.append(nameData)
        local.append(contents)

        let centralOffset = local.count
        var central = Data()
        central.appendLittleEndian(UInt32(0x0201_4b50))
        central.appendLittleEndian(UInt16(20))
        central.appendLittleEndian(UInt16(20))
        central.appendLittleEndian(UInt16(0))
        central.appendLittleEndian(UInt16(0))
        central.appendLittleEndian(UInt16(0))
        central.appendLittleEndian(UInt16(0))
        central.appendLittleEndian(checksum)
        central.appendLittleEndian(UInt32(contents.count))
        central.appendLittleEndian(UInt32(contents.count))
        central.appendLittleEndian(UInt16(nameData.count))
        central.appendLittleEndian(UInt16(0))
        central.appendLittleEndian(UInt16(0))
        central.appendLittleEndian(UInt16(0))
        central.appendLittleEndian(UInt16(0))
        central.appendLittleEndian(UInt32(0))
        central.appendLittleEndian(UInt32(0))
        central.append(nameData)

        var result = local
        result.append(central)
        result.appendLittleEndian(UInt32(0x0605_4b50))
        result.appendLittleEndian(UInt16(0))
        result.appendLittleEndian(UInt16(0))
        result.appendLittleEndian(UInt16(1))
        result.appendLittleEndian(UInt16(1))
        result.appendLittleEndian(UInt32(central.count))
        result.appendLittleEndian(UInt32(centralOffset))
        result.appendLittleEndian(UInt16(0))
        return result
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ UInt32.max
    }
}

extension Data {
    fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

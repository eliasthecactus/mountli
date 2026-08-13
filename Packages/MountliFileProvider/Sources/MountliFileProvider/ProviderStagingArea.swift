import Foundation

struct ProviderStagingArea: @unchecked Sendable {
    private static let prefix = "mountli-"
    private static let stageExtension = "stage"

    let directory: URL

    init(root: URL) throws {
        directory = root.appendingPathComponent("ProviderStages", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: directoryAttributes
        )
        try FileManager.default.setAttributes(directoryAttributes, ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(values)
    }

    func destination(for operationID: UUID) throws -> URL {
        let url =
            directory
            .appendingPathComponent(Self.prefix + operationID.uuidString.lowercased())
            .appendingPathExtension(Self.stageExtension)
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: protectedAttributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedURL = url
        try protectedURL.setResourceValues(values)
        return url
    }

    func cleanupStale(
        olderThan cutoff: Date,
        activeOperationIDs: Set<UUID>
    ) throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        for url in files {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                let modified = values.contentModificationDate,
                modified < cutoff,
                let operationID = Self.operationID(for: url),
                !activeOperationIDs.contains(operationID)
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func remove(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func operationID(for url: URL) -> UUID? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count)))
    }

    private var directoryAttributes: [FileAttributeKey: Any] {
        var attributes = protectedAttributes
        attributes[.posixPermissions] = NSNumber(value: Int16(0o700))
        return attributes
    }

    private var protectedAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o600))
        ]
        #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        return attributes
    }
}

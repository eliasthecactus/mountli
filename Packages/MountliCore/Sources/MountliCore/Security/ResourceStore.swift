import Foundation

public enum ResourceStoreError: Error, Equatable, Sendable {
    case missing(UUID)
    case staleBookmark(UUID)
    case invalidSelection(String)
}

extension ResourceStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missing:
            "A file this remote depends on is missing. Relink it in Settings › Protected resource files."
        case .staleBookmark:
            "Mountli lost access to a folder this remote uses. Relink it in Settings › Protected resource files."
        case .invalidSelection(let message):
            message
        }
    }
}

public actor ResourceStore {
    private let runtimeRoot: URL
    private let appGroupRoot: URL
    private static let maximumResourceBytes = 16 * 1_024 * 1_024
    public static let optionPrefix = "mountli-resource://"
    public init(appGroupRoot: URL) {
        self.appGroupRoot = appGroupRoot.standardizedFileURL
        runtimeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mountli-resource-runtime-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        ResourceRuntimeCoordinator.shared.prepare(runtimeRoot)
    }

    public func importFile(
        from source: URL,
        kind: ManagedResourceReference.Kind,
        displayName: String
    ) throws -> ManagedResourceReference {
        guard source.isFileURL else { throw ResourceStoreError.invalidSelection("Resource must be a local file") }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ResourceStoreError.invalidSelection("Resource must be a regular file")
        }
        guard let size = values.fileSize, size <= Self.maximumResourceBytes else {
            throw ResourceStoreError.invalidSelection("Resource exceeds the 16 MB safety limit")
        }
        let payload = try Self.readPayload(from: source, reservingCapacity: size)
        return ManagedResourceReference(
            kind: kind,
            displayName: displayName,
            originalFilename: source.lastPathComponent,
            encryptedPayload: payload,
            originalPath: source.path
        )
    }

    public func importDirectoryBookmark(
        from source: URL,
        displayName: String,
        fileProviderStorageURLs: [URL]
    ) throws -> ManagedResourceReference {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        try LocalResourceValidator.validateSelectedDirectory(
            source,
            appGroupURL: appGroupRoot,
            fileProviderStorageURLs: fileProviderStorageURLs
        )
        let bookmark = try source.bookmarkData(
            options: Self.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return ManagedResourceReference(
            kind: .securityScopedDirectory,
            displayName: displayName,
            originalFilename: source.lastPathComponent,
            bookmark: bookmark
        )
    }

    public func resolve(_ reference: ManagedResourceReference) throws -> URL {
        if reference.kind == .securityScopedDirectory {
            guard let bookmark = reference.bookmark else { throw ResourceStoreError.missing(reference.id) }
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: Self.bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard !stale else { throw ResourceStoreError.staleBookmark(reference.id) }
            return url
        }
        guard let payload = reference.encryptedPayload else { throw ResourceStoreError.missing(reference.id) }
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let url = runtimeRoot.appendingPathComponent(reference.id.uuidString.lowercased(), isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            try payload.write(to: url, options: .atomic)
            try protect(url)
        }
        return url
    }

    public func relink(
        _ reference: ManagedResourceReference,
        to source: URL,
        fileProviderStorageURLs: [URL]
    ) throws -> ManagedResourceReference {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        if reference.kind == .securityScopedDirectory {
            try LocalResourceValidator.validateSelectedDirectory(
                source,
                appGroupURL: appGroupRoot,
                fileProviderStorageURLs: fileProviderStorageURLs
            )
            var updated = reference
            updated.bookmark = try source.bookmarkData(
                options: Self.bookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            updated.originalFilename = source.lastPathComponent
            return updated
        }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ResourceStoreError.invalidSelection("Resource must be a regular file")
        }
        guard let size = values.fileSize, size <= Self.maximumResourceBytes else {
            throw ResourceStoreError.invalidSelection("Resource exceeds the 16 MB safety limit")
        }
        var updated = reference
        updated.encryptedPayload = try Data(contentsOf: source, options: .mappedIfSafe)
        updated.originalPath = source.path
        updated.originalFilename = source.lastPathComponent
        let materialized = runtimeRoot.appendingPathComponent(reference.id.uuidString.lowercased(), isDirectory: false)
        try? FileManager.default.removeItem(at: materialized)
        return updated
    }

    public func remove(_ reference: ManagedResourceReference) throws {
        guard reference.kind != .securityScopedDirectory else { return }
        let url = runtimeRoot.appendingPathComponent(reference.id.uuidString.lowercased(), isDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: runtimeRoot.path) {
            try FileManager.default.removeItem(at: runtimeRoot)
        }
    }

    public func optionValue(for reference: ManagedResourceReference) -> String {
        Self.optionPrefix + reference.id.uuidString.lowercased()
    }

    public func materializeOptions(
        _ options: [String: String],
        resources: [ManagedResourceReference]
    ) throws -> [String: String] {
        var result = options
        let references = Dictionary(
            uniqueKeysWithValues: resources.map {
                (Self.optionPrefix + $0.id.uuidString.lowercased(), $0)
            })
        for (key, value) in options {
            guard let reference = references[value] else { continue }
            result[key] = try resolve(reference).path
        }
        return result
    }

    public func materialize(_ snapshot: VaultSnapshot) throws -> VaultSnapshot {
        var document = snapshot.document
        for index in document.remotes.indices {
            document.remotes[index].options = try materializeOptions(
                document.remotes[index].options,
                resources: document.remotes[index].resources
            )
        }
        return VaultSnapshot(revision: snapshot.revision, document: document)
    }

    public func exportable(_ snapshot: VaultSnapshot) throws -> VaultSnapshot {
        var document = snapshot.document
        for index in document.remotes.indices {
            let references = Dictionary(
                uniqueKeysWithValues: document.remotes[index].resources.map {
                    (Self.optionPrefix + $0.id.uuidString.lowercased(), $0)
                })
            for (key, value) in document.remotes[index].options {
                guard let reference = references[value] else { continue }
                guard let originalPath = reference.originalPath else {
                    throw ResourceStoreError.missing(reference.id)
                }
                document.remotes[index].options[key] = originalPath
            }
        }
        return VaultSnapshot(revision: snapshot.revision, document: document)
    }

    private static func readPayload(from url: URL, reservingCapacity size: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var payload = Data()
        payload.reserveCapacity(size)
        while payload.count <= maximumResourceBytes {
            let remaining = maximumResourceBytes + 1 - payload.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                !chunk.isEmpty
            else { return payload }
            payload.append(chunk)
        }
        throw ResourceStoreError.invalidSelection("Resource exceeds the 16 MB safety limit")
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
    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
            [.withSecurityScope]
        #else
            []
        #endif
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
            [.withSecurityScope, .withoutUI]
        #else
            []
        #endif
    }
}

private final class ResourceRuntimeCoordinator: @unchecked Sendable {
    static let shared = ResourceRuntimeCoordinator()
    private let lock = NSLock()
    private var preparedPaths: Set<String> = []

    func prepare(_ url: URL) {
        let firstInProcess = lock.withLock { preparedPaths.insert(url.path).inserted }
        guard firstInProcess else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

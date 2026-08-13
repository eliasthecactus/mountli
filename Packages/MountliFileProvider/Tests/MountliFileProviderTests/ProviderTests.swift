import FileProvider
import Foundation
import Testing

@testable import MountliCore
@testable import MountliFileProvider

@Test func bridgeErrorsMapToFileProviderErrors() {
    let cases: [(BridgeErrorKind, NSFileProviderError.Code)] = [
        (.notAuthenticated, .notAuthenticated),
        (.unreachable, .serverUnreachable),
        (.quotaExceeded, .insufficientQuota),
        (.notFound, .noSuchItem),
        (.alreadyExists, .filenameCollision),
        (.conflict, .versionNoLongerAvailable),
        (.unsupported, .cannotSynchronize),
    ]
    for (kind, expected) in cases {
        let error = ProviderErrorMapper.map(BridgeFailure(kind: kind, message: "test", retryable: false)) as NSError
        #expect(error.domain == NSFileProviderErrorDomain)
        #expect(error.code == expected.rawValue)
    }
}

@Test func repositoryLeaseLossMapsToTransientServerUnreachable() {
    let error =
        ProviderErrorMapper.map(
            ItemRepositoryError.enumerationLeaseLost(nil)
        ) as NSError
    #expect(error.domain == NSFileProviderErrorDomain)
    #expect(error.code == NSFileProviderError.Code.serverUnreachable.rawValue)
}

@Test func providerItemUsesOpaqueStableIdentityAndVersions() {
    let remote = RemoteProfile.make(displayName: "Remote", backendType: "memory")
    let mount = MountDefinition(remoteID: remote.id, displayName: "Documents")
    let id = UUID()
    let stored = StoredItem(
        id: id, mountID: mount.id, parentID: nil, remoteID: "backend-object",
        remotePath: "renamed.txt", displayName: "renamed.txt", isDirectory: false,
        size: 7, modificationDate: .now, contentVersion: Data(repeating: 1, count: 32),
        metadataVersion: Data(repeating: 2, count: 32), listGeneration: 1,
        materialized: false, pinned: false, lastAccessedAt: nil
    )
    let item = MountliFileProviderItem(stored: stored, mount: mount)
    #expect(item.itemIdentifier.rawValue == "item.\(id.uuidString.lowercased())")
    #expect(!item.itemIdentifier.rawValue.contains("renamed.txt"))
    #expect(item.itemVersion.contentVersion == stored.contentVersion)
    #expect(!item.capabilities.contains(.allowsWriting))

    var readOnlyMount = mount
    readOnlyMount.readOnly = true
    let readOnly = MountliFileProviderItem(stored: stored, mount: readOnlyMount)
    #expect(!readOnly.capabilities.contains(.allowsWriting))
    #expect(!readOnly.capabilities.contains(.allowsDeleting))
    #expect(!readOnly.capabilities.contains(.allowsRenaming))
    #expect(!readOnly.capabilities.contains(.allowsReparenting))
}

@Test func writableRootAdvertisesCreationAndReadOnlyRootDoesNot() throws {
    let remote = RemoteProfile.make(displayName: "Remote", backendType: "memory")
    let mount = MountDefinition(remoteID: remote.id, displayName: "Documents")
    let capabilities = try writableCapabilities()
    let writableRoot = MountliFileProviderItem(
        stored: nil,
        mount: mount,
        backendCapabilities: capabilities
    )
    #expect(writableRoot.capabilities.contains(.allowsAddingSubItems))

    var readOnlyMount = mount
    readOnlyMount.readOnly = true
    let readOnlyRoot = MountliFileProviderItem(
        stored: nil,
        mount: readOnlyMount,
        backendCapabilities: capabilities
    )
    #expect(!readOnlyRoot.capabilities.contains(.allowsAddingSubItems))
}

@Test func duplicateProjectionIsDeterministicAndAliasesAreReadOnly() throws {
    let capabilities = try writableCapabilities()
    let now = Date(timeIntervalSince1970: 100)
    let remoteItems = [
        RemoteItem(
            path: "Same.txt",
            name: "Same.txt",
            size: 1,
            modificationDate: now,
            isDirectory: false,
            objectID: "object-b",
            fingerprint: "b",
            mimeType: nil
        ),
        RemoteItem(
            path: "same.txt",
            name: "same.txt",
            size: 1,
            modificationDate: now,
            isDirectory: false,
            objectID: "object-a",
            fingerprint: "a",
            mimeType: nil
        ),
    ]
    let first = ProviderDuplicateProjection.project(remoteItems, capabilities: capabilities)
    let second = ProviderDuplicateProjection.project(Array(remoteItems.reversed()), capabilities: capabilities)
    #expect(first.map(\.name) == second.map(\.name))
    #expect(Set(first.map(\.name)).count == 2)

    guard let alias = first.first(where: { $0.name.contains(" (duplicate ") }) else {
        Issue.record("Expected a projected duplicate alias")
        return
    }
    let remote = RemoteProfile.make(displayName: "Remote", backendType: "memory")
    let mount = MountDefinition(remoteID: remote.id, displayName: "Documents")
    let stored = StoredItem(
        id: UUID(),
        mountID: mount.id,
        parentID: nil,
        remoteID: alias.objectID,
        remotePath: alias.path,
        displayName: alias.name,
        isDirectory: false,
        size: alias.size,
        modificationDate: alias.modificationDate,
        contentVersion: Data(repeating: 1, count: 32),
        metadataVersion: Data(repeating: 2, count: 32),
        listGeneration: 1,
        materialized: false,
        pinned: false,
        lastAccessedAt: nil
    )
    let item = MountliFileProviderItem(
        stored: stored,
        mount: mount,
        backendCapabilities: capabilities
    )
    #expect(item.capabilities.contains(.allowsReading))
    #expect(!item.capabilities.contains(.allowsWriting))
    #expect(!item.capabilities.contains(.allowsDeleting))
    #expect(!item.capabilities.contains(.allowsRenaming))
    #expect(!item.capabilities.contains(.allowsReparenting))
}

@Test func createOperationIdentityIsStableAndScoped() {
    let template = NSFileProviderItemIdentifier("temporary.apple-template-id")
    let first = MountliFileProviderExtension.createOperationIdentifier(
        template,
        domainIdentifier: "mountli.first"
    )
    let second = MountliFileProviderExtension.createOperationIdentifier(
        template,
        domainIdentifier: "mountli.first"
    )
    let otherDomain = MountliFileProviderExtension.createOperationIdentifier(
        template,
        domainIdentifier: "mountli.second"
    )
    let move = MountliFileProviderExtension.operationIdentifier(template, scope: "move")
    #expect(first == second)
    #expect(first != otherDomain)
    #expect(first != move)
}

@Test func unsupportedCreateMetadataRemainsPending() {
    let requested: NSFileProviderItemFields = [
        .filename,
        .parentItemIdentifier,
        .contents,
        .contentModificationDate,
        .favoriteRank,
    ]
    let applied = MountliFileProviderExtension.appliedCreateFields(
        isDirectory: false,
        hasContents: true
    )
    let pending = requested.subtracting(applied)
    #expect(!pending.contains(.filename))
    #expect(!pending.contains(.parentItemIdentifier))
    #expect(!pending.contains(.contents))
    #expect(pending.contains(.contentModificationDate))
    #expect(pending.contains(.favoriteRank))
}

@Test func protectedStagesPreserveSparseOffsetsAndOnlyCleanInactiveFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = try ProviderStagingArea(root: root)
    let activeID = UUID()
    let inactiveID = UUID()
    let active = try staging.destination(for: activeID)
    let inactive = try staging.destination(for: inactiveID)

    let handle = try FileHandle(forWritingTo: active)
    try handle.seek(toOffset: 4_096)
    try handle.write(contentsOf: Data([0x4D, 0x4C, 0x49]))
    try handle.synchronize()
    try handle.close()

    let staged = try Data(contentsOf: active)
    #expect(staged.count == 4_099)
    #expect(staged.prefix(4_096).allSatisfy { $0 == 0 })
    #expect(staged.suffix(3) == Data([0x4D, 0x4C, 0x49]))
    let permissions = try FileManager.default.attributesOfItem(atPath: active.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)

    let old = Date(timeIntervalSince1970: 1)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: active.path)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: inactive.path)
    try staging.cleanupStale(olderThan: .now, activeOperationIDs: [activeID])
    #expect(FileManager.default.fileExists(atPath: active.path))
    #expect(!FileManager.default.fileExists(atPath: inactive.path))
}

@Test func durableProviderIssuesExposeOnlySafeExactIdentityActions() {
    let mountID = UUID()
    var stored = StoredItem(
        id: UUID(),
        mountID: mountID,
        parentID: nil,
        remoteID: "stable-object-id",
        remotePath: "private/folder/file.txt",
        displayName: "file.txt (duplicate abc123)",
        isDirectory: false,
        size: 1,
        modificationDate: .now,
        contentVersion: Data(repeating: 1, count: 32),
        metadataVersion: Data(repeating: 2, count: 32),
        listGeneration: 1,
        materialized: false,
        pinned: false,
        lastAccessedAt: nil
    )

    let deleteConflict = ProviderEnvironment.versionConflictIssue(
        item: stored,
        mountID: mountID,
        operationKind: .delete
    )
    #expect(deleteConflict.remotePath == nil)
    #expect(deleteConflict.redactedPathToken == nil)
    #expect(deleteConflict.remoteObjectID == "stable-object-id")
    #expect(deleteConflict.suggestedActions == [.deleteAnyway, .keepRemote])

    let duplicate = ProviderEnvironment.duplicateIssue(item: stored, mountID: mountID)
    #expect(duplicate.remotePath == nil)
    #expect(duplicate.remoteObjectID == "stable-object-id")
    #expect(duplicate.suggestedActions == [.deleteDuplicate, .renameDuplicate])

    stored.remoteID = nil
    let unidentifiedDelete = ProviderEnvironment.versionConflictIssue(
        item: stored,
        mountID: mountID,
        operationKind: .delete
    )
    #expect(unidentifiedDelete.remoteObjectID == nil)
    #expect(unidentifiedDelete.suggestedActions == [.keepRemote])
    #expect(ProviderEnvironment.duplicateIssue(item: stored, mountID: mountID).suggestedActions.isEmpty)
}

private func writableCapabilities() throws -> BackendCapabilities {
    try JSONDecoder().decode(
        BackendCapabilities.self,
        from: Data(
            #"""
            {
              "readOnly": false,
              "caseInsensitive": true,
              "duplicateFiles": true,
              "readMimeType": true,
              "writeMimeType": true,
              "emptyDirectories": true,
              "serverSideCopy": true,
              "serverSideMove": true,
              "serverSideDirectoryMove": true,
              "changeNotify": false,
              "listP": true,
              "listR": false,
              "about": false,
              "precisionNanoseconds": 1,
              "hashes": []
            }
            """#.utf8
        )
    )
}

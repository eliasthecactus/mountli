import Foundation
import Testing

@testable import MountliCore

@Test func engineNameIsStableAndASCII() {
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    let remote = RemoteProfile.make(displayName: "Mÿ Storage / Work", backendType: "webdav", id: id)
    #expect(remote.engineName == "my-storage-work-123456")
    var renamed = remote
    renamed.displayName = "Personal"
    #expect(renamed.engineName == remote.engineName)
}

@Test func dependencyGraphOrdersBasesAndRejectsCycles() throws {
    let base = RemoteProfile.make(displayName: "Base", backendType: "memory")
    let crypt = RemoteProfile.make(
        displayName: "Crypt",
        backendType: "crypt",
        options: ["remote": "\(base.engineName):encrypted"]
    )
    let graph = try RemoteDependencyGraph(remotes: [crypt, base])
    let order = try graph.topologicalOrder()
    #expect(order.firstIndex(of: base.engineName)! < order.firstIndex(of: crypt.engineName)!)
    #expect(throws: DependencyGraphError.self) { try graph.assertCanDelete(base.engineName) }

    let a = RemoteProfile.make(displayName: "A", backendType: "crypt")
    let b = RemoteProfile.make(displayName: "B", backendType: "crypt")
    var cycleA = a
    var cycleB = b
    cycleA.options["remote"] = "\(b.engineName):x"
    cycleB.options["remote"] = "\(a.engineName):x"
    #expect(throws: DependencyGraphError.self) { try RemoteDependencyGraph(remotes: [cycleA, cycleB]) }
}

@Test func vaultIntegrityFailureRequiresExplicitBackupRecovery() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = FixedKeyProvider(data: Data(repeating: 0xA5, count: 32))
    let store = EncryptedVaultStore(directory: directory, keyProvider: key)
    let firstRemote = RemoteProfile.make(displayName: "Primary", backendType: "memory")
    let first = try await store.save(VaultDocument(remotes: [firstRemote]), expectedRevision: 0)
    #expect(first.revision == 1)
    #expect(try await store.load() == first)
    await #expect(throws: VaultStoreError.self) {
        try await store.save(VaultDocument(), expectedRevision: 0)
    }

    var secondDocument = first.document
    secondDocument.settings.showMenuBarExtra = false
    let second = try await store.save(secondDocument, expectedRevision: 1)
    #expect(second.revision == 2)

    let vaultURL = directory.appendingPathComponent("vault.bin")
    var damaged = try Data(contentsOf: vaultURL)
    damaged[damaged.startIndex] ^= 0xFF
    try damaged.write(to: vaultURL)
    await #expect(throws: VaultStoreError.self) {
        try await store.load()
    }
    let candidate = try await store.backupCandidate()
    #expect(candidate == first)
    let recovered = try await store.restoreBackup()
    #expect(recovered.revision == 3)
    #expect(recovered.document == first.document)
    #expect(try await store.load() == recovered)
}

@Test func rcloneMutationPersistsWithRevisionContract() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = EncryptedVaultStore(
        directory: directory,
        keyProvider: FixedKeyProvider(data: Data(repeating: 0x5A, count: 32))
    )
    let remote = RemoteProfile.make(displayName: "OAuth", backendType: "memory")
    let first = try await store.save(VaultDocument(remotes: [remote]), expectedRevision: 0)
    let mutation = RcloneVaultMutation(
        expectedRevision: first.revision,
        action: .set,
        section: remote.engineName,
        key: "token",
        value: "refreshed"
    )
    let updated = try await store.applyRcloneMutation(mutation)
    #expect(updated.revision == 2)
    #expect(updated.document.remotes[0].options["token"] == "refreshed")
    await #expect(throws: VaultStoreError.self) {
        try await store.applyRcloneMutation(mutation)
    }
}

@Test func staleRcloneMutationMergesOnlyWhenItsKeyIsUnchanged() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = EncryptedVaultStore(
        directory: directory,
        keyProvider: FixedKeyProvider(data: Data(repeating: 0x39, count: 32))
    )
    let remote = RemoteProfile.make(displayName: "OAuth merge", backendType: "memory")
    let first = try await store.save(VaultDocument(remotes: [remote]), expectedRevision: 0)
    var unrelated = first.document
    unrelated.settings.showMenuBarExtra = false
    _ = try await store.save(unrelated, expectedRevision: first.revision)

    let merged = try await store.applyRcloneMutation(
        RcloneVaultMutation(
            expectedRevision: first.revision,
            action: .set,
            section: remote.engineName,
            key: "token",
            value: "refreshed",
            previousValuePresent: false
        ))
    #expect(merged.document.settings.showMenuBarExtra == false)
    #expect(merged.document.remotes[0].options["token"] == "refreshed")

    await #expect(throws: VaultStoreError.self) {
        try await store.applyRcloneMutation(
            RcloneVaultMutation(
                expectedRevision: first.revision,
                action: .set,
                section: remote.engineName,
                key: "token",
                value: "stale",
                previousValuePresent: false
            ))
    }
}

@Test func staleAppSaveMergesTokenRefreshWithoutRevisionConflict() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = EncryptedVaultStore(
        directory: directory,
        keyProvider: FixedKeyProvider(data: Data(repeating: 0x71, count: 32))
    )
    let remote = RemoteProfile.make(
        displayName: "OAuth account",
        backendType: "memory",
        options: ["token": "original"]
    )
    let base = try await store.save(VaultDocument(remotes: [remote]), expectedRevision: 0)

    var appDraft = base.document
    appDraft.settings.showMenuBarExtra = false
    appDraft.remotes[0].displayName = "Renamed account"
    appDraft.remotes[0].updatedAt = .now

    _ = try await store.applyRcloneMutation(
        RcloneVaultMutation(
            expectedRevision: base.revision,
            action: .set,
            section: remote.engineName,
            key: "token",
            value: "refreshed"
        ))
    let merged = try await store.saveMergingChanges(appDraft, basedOn: base)

    #expect(merged.document.settings.showMenuBarExtra == false)
    #expect(merged.document.remotes[0].displayName == "Renamed account")
    #expect(merged.document.remotes[0].options["token"] == "refreshed")
}

@Test func staleAppSaveRejectsAnOverlappingOptionEdit() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = EncryptedVaultStore(
        directory: directory,
        keyProvider: FixedKeyProvider(data: Data(repeating: 0x72, count: 32))
    )
    let remote = RemoteProfile.make(
        displayName: "OAuth account",
        backendType: "memory",
        options: ["token": "original"]
    )
    let base = try await store.save(VaultDocument(remotes: [remote]), expectedRevision: 0)
    var appDraft = base.document
    appDraft.remotes[0].options["token"] = "manual"
    appDraft.remotes[0].updatedAt = .now

    _ = try await store.applyRcloneMutation(
        RcloneVaultMutation(
            expectedRevision: base.revision,
            action: .set,
            section: remote.engineName,
            key: "token",
            value: "refreshed"
        ))
    await #expect(throws: VaultStoreError.self) {
        try await store.saveMergingChanges(appDraft, basedOn: base)
    }
}

@Test func sqliteMigratesReconcilesAndKeepsIdentityAcrossRename() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
    #expect(try await store.userVersion() == MountliMigrations.latestVersion)
    #expect(try await store.integrityCheck() == "ok")

    let mountID = UUID()
    let firstRemote = RemoteItem(
        path: "before.txt", name: "before.txt", size: 4, modificationDate: .now,
        isDirectory: false, objectID: "stable-object", fingerprint: "v1", mimeType: "text/plain"
    )
    let first = try await store.reconcile(mountID: mountID, parentID: nil, remoteItems: [firstRemote])
    #expect(first.created.count == 1)
    let identity = first.created[0].id

    var renamed = firstRemote
    renamed.path = "after.txt"
    renamed.name = "after.txt"
    renamed.fingerprint = "v2"
    let second = try await store.reconcile(mountID: mountID, parentID: nil, remoteItems: [renamed])
    #expect(second.updated.count == 1)
    #expect(second.updated[0].id == identity)
    #expect(try await store.item(remoteID: "stable-object", mountID: mountID)?.remotePath == "after.txt")
    #expect(try await store.currentSyncAnchor(mountID: mountID) > 0)

    let operation = OperationRecord(mountID: mountID, itemID: identity, kind: .upload, outcome: .running)
    try await store.recordOperation(operation)
    try await store.updateOperationProgress(id: operation.id, completedBytes: 2, totalBytes: 4)
    #expect(try await store.pendingOperationCount(mountID: mountID) == 1)
    #expect(try await store.recoverInterruptedOperations(now: .now) == 1)
    let recent = try await store.recentOperations(limit: 1)
    #expect(recent.first?.id == operation.id)
    #expect(recent.first?.outcome == .retryableFailure)
    #expect(recent.first?.completedBytes == 2)
    #expect(recent.first?.totalBytes == 4)

    let firstLeaseID = UUID()
    let secondLeaseID = UUID()
    #expect(
        try await store.acquireTransferLease(
            operationID: firstLeaseID,
            mountID: mountID,
            owner: "test-owner",
            limit: 1
        ))
    #expect(
        try await store.acquireTransferLease(
            operationID: secondLeaseID,
            mountID: mountID,
            owner: "test-owner",
            limit: 1
        ) == false)
    try await store.releaseTransferLease(operationID: firstLeaseID, owner: "test-owner")
    #expect(
        try await store.acquireTransferLease(
            operationID: secondLeaseID,
            mountID: mountID,
            owner: "test-owner",
            limit: 1
        ))
}

@Test func clearingActivityHistoryPreservesPendingWorkAndOpenIssues() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
    let mountID = UUID()
    let completed = OperationRecord(
        mountID: mountID,
        kind: .download,
        outcome: .succeeded,
        completedAt: .now
    )
    let pending = OperationRecord(mountID: mountID, kind: .upload, outcome: .running)
    let retryable = OperationRecord(
        mountID: mountID,
        kind: .upload,
        outcome: .retryableFailure,
        completedAt: .now
    )
    try await store.recordOperation(completed)
    try await store.recordOperation(pending)
    try await store.recordOperation(retryable)
    let issue = IssueRecord(
        mountID: mountID,
        kind: .syncFailure,
        diagnosticCode: "SYNC_RETRY",
        message: "A transfer needs attention.",
        retryable: true,
        suggestedActions: [.retry]
    )
    _ = try await store.recordIssue(issue)

    #expect(try await store.clearCompletedOperationHistory() == 1)
    #expect(Set(try await store.recentOperations().map(\.id)) == [pending.id, retryable.id])
    #expect(try await store.openIssues(mountID: mountID, limit: 10).map(\.id) == [issue.id])
}

@Test func sqliteScopesJournalsAndSkipsUnchangedListings() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
    let mountID = UUID()
    let timestamp = Date(timeIntervalSince1970: 1_000)
    let folderRemote = RemoteItem(
        path: "folder", name: "folder", size: 0, modificationDate: timestamp,
        isDirectory: true, objectID: "folder-id", fingerprint: "folder-v1", mimeType: nil
    )
    let folderBatch = try await store.reconcile(
        mountID: mountID,
        parentID: nil,
        remoteItems: [folderRemote]
    )
    let folder = try #require(folderBatch.created.first)
    let rootAnchor = try await store.currentSyncAnchor(mountID: mountID)

    let unchanged = try await store.reconcile(
        mountID: mountID,
        parentID: nil,
        remoteItems: [folderRemote]
    )
    #expect(unchanged.updated.isEmpty)
    #expect(try await store.currentSyncAnchor(mountID: mountID) == rootAnchor)

    let childRemote = RemoteItem(
        path: "folder/child.txt", name: "child.txt", size: 5, modificationDate: timestamp,
        isDirectory: false, objectID: "child-id", fingerprint: "child-v1", mimeType: "text/plain"
    )
    let childBatch = try await store.reconcile(
        mountID: mountID,
        parentID: folder.id,
        remoteItems: [childRemote]
    )
    let child = try #require(childBatch.created.first)
    let rootChanges = try await store.changes(
        mountID: mountID,
        containerID: nil,
        after: rootAnchor,
        limit: 500
    )
    #expect(rootChanges.changes.isEmpty)
    let folderChanges = try await store.changes(
        mountID: mountID,
        containerID: folder.id,
        after: rootAnchor,
        limit: 500
    )
    #expect(folderChanges.changes.map(\.itemID) == [child.id])
    #expect(folderChanges.changes.allSatisfy { $0.containerID == folder.id })
}

@Test func sqliteWorkingSetUsageReparentAndRecursiveDeleteAreAtomic() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
    let mountID = UUID()
    let timestamp = Date(timeIntervalSince1970: 2_000)
    let parentRemotes = [
        RemoteItem(
            path: "a", name: "a", size: 0, modificationDate: timestamp,
            isDirectory: true, objectID: "a-id", fingerprint: "a-v1", mimeType: nil
        ),
        RemoteItem(
            path: "b", name: "b", size: 0, modificationDate: timestamp,
            isDirectory: true, objectID: "b-id", fingerprint: "b-v1", mimeType: nil
        ),
    ]
    let parents = try await store.reconcile(
        mountID: mountID,
        parentID: nil,
        remoteItems: parentRemotes
    ).created
    let parentA = try #require(parents.first { $0.remoteID == "a-id" })
    let parentB = try #require(parents.first { $0.remoteID == "b-id" })
    let childRemote = RemoteItem(
        path: "a/file.txt", name: "file.txt", size: 4, modificationDate: timestamp,
        isDirectory: false, objectID: "file-id", fingerprint: "file-v1", mimeType: "text/plain"
    )
    let childBatch = try await store.reconcile(
        mountID: mountID,
        parentID: parentA.id,
        remoteItems: [childRemote]
    )
    let child = try #require(childBatch.created.first)

    try await store.markAccessed(itemID: child.id, mountID: mountID, at: .now)
    #expect(
        try await store.workingSet(
            mountID: mountID,
            accessedAfter: .now.addingTimeInterval(-30 * 24 * 60 * 60)
        ).map(\.id) == [child.id])

    var movedRemote = childRemote
    movedRemote.path = "b/file.txt"
    let moved = try await store.update(
        itemID: child.id,
        mountID: mountID,
        parentID: parentB.id,
        remoteItem: movedRemote
    )
    #expect(moved.id == child.id)
    #expect(moved.parentID == parentB.id)
    #expect(try await store.item(id: child.id, mountID: mountID)?.remotePath == "b/file.txt")

    let deleted = try await store.deleteItem(itemID: parentB.id, mountID: mountID)
    #expect(Set(deleted.map(\.id)) == Set([parentB.id, child.id]))
    #expect(try await store.item(id: child.id, mountID: mountID) == nil)
    let childContainerChanges = try await store.changes(
        mountID: mountID,
        containerID: parentB.id,
        after: 0,
        limit: 500
    )
    #expect(
        childContainerChanges.changes.contains {
            $0.itemID == child.id && $0.kind == .delete
        })
}

@Test func sqliteExpiresAnchorsAndEnforcesCrossProcessAdmissions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
    let mountID = UUID()
    let remote = RemoteItem(
        path: "file.txt", name: "file.txt", size: 1, modificationDate: .now,
        isDirectory: false, objectID: "file-id", fingerprint: "v1", mimeType: "text/plain"
    )
    _ = try await store.reconcile(mountID: mountID, parentID: nil, remoteItems: [remote])
    #expect(try await store.compactJournal(retainingAfter: .now.addingTimeInterval(1)) == 1)
    await #expect(throws: ItemRepositoryError.self) {
        _ = try await store.changes(mountID: mountID, containerID: nil, after: 0, limit: 500)
    }

    #expect(
        try await store.acquireEnumerationLease(
            mountID: mountID,
            containerID: nil,
            owner: "process-a",
            ttl: 30
        ))
    #expect(
        try await store.acquireEnumerationLease(
            mountID: mountID,
            containerID: nil,
            owner: "process-b",
            ttl: 30
        ) == false)
    await #expect(throws: ItemRepositoryError.self) {
        _ = try await store.reconcile(
            mountID: mountID,
            parentID: nil,
            remoteItems: [remote],
            enumerationOwner: "process-b"
        )
    }
    try await store.releaseEnumerationLease(mountID: mountID, containerID: nil, owner: "process-a")

    let operation = OperationRecord(mountID: mountID, kind: .upload, outcome: .running)
    try await store.recordOperation(operation)
    #expect(
        try await store.acquireOperationLease(
            operationID: operation.id,
            mountID: mountID,
            owner: "process-a",
            ttl: 30
        ))
    #expect(
        try await store.acquireTransferLease(
            operationID: operation.id,
            mountID: mountID,
            owner: "process-a",
            limit: 1,
            ttl: 30
        ))
    #expect(try await store.recoverInterruptedOperations(now: .now) == 0)
    #expect(
        try await store.acquireRemovalAdmission(
            mountID: mountID,
            owner: "remover",
            ttl: 30
        ) == 1)
    try await store.releaseRemovalAdmission(mountID: mountID, owner: "remover")
    #expect(try await store.recoverInterruptedOperations(now: .now.addingTimeInterval(31)) == 1)

    #expect(
        try await store.acquireRemovalAdmission(
            mountID: mountID,
            owner: "remover",
            ttl: 30
        ) == 1)
    #expect(
        try await store.acquireEnumerationLease(
            mountID: mountID,
            containerID: UUID(),
            owner: "process-c",
            ttl: 30
        ) == false)
    try await store.releaseRemovalAdmission(mountID: mountID, owner: "remover")
}

@Test func sqliteDurablyDeduplicatesIssuesAndCarriesCrossProcessRequests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
    let mountID = UUID()
    let itemID = UUID()
    let issue = IssueRecord(
        mountID: mountID,
        itemID: itemID,
        kind: .conflict,
        diagnosticCode: "CONFLICT_REMOTE_CHANGED",
        message: "The remote item changed.",
        retryable: false,
        remoteObjectID: "backend-object",
        redactedPathToken: "path-token",
        defaultRename: "file (conflict).txt",
        suggestedActions: [.keepRemote, .deleteAnyway]
    )
    let first = try await store.recordIssue(issue)
    var repeated = issue
    repeated.id = UUID()
    repeated.message = "The remote item changed again."
    let deduplicated = try await store.recordIssue(repeated)
    #expect(deduplicated.id == first.id)
    #expect(deduplicated.createdAt == first.createdAt)
    #expect(try await store.openIssues(mountID: mountID, limit: 10).count == 1)
    #expect(try await store.issue(id: first.id)?.message == repeated.message)

    #expect(
        try await store.requestIssueResolution(
            issueID: first.id,
            action: .keepRemote,
            renameTo: nil,
            at: .now
        ))
    let requests = try await store.pendingIssueResolutionRequests(mountID: mountID, limit: 10)
    #expect(requests.count == 1)
    #expect(requests.first?.issueID == first.id)
    #expect(requests.first?.action == .keepRemote)
    try await store.clearIssueResolutionRequest(issueID: first.id)
    #expect(try await store.pendingIssueResolutionRequests(mountID: mountID, limit: 10).isEmpty)

    let operation = OperationRecord(mountID: mountID, itemID: itemID, kind: .upload, outcome: .running)
    try await store.recordOperation(operation)
    #expect(try await store.requestOperationCancellation(id: operation.id, at: .now))
    #expect(try await store.isOperationCancellationRequested(id: operation.id))
    try await store.finishOperation(id: operation.id, outcome: .cancelled)
    #expect(try await store.isOperationCancellationRequested(id: operation.id) == false)

    #expect(try await store.resolveIssue(id: first.id, at: .now))
    #expect(try await store.openIssues(mountID: mountID, limit: 10).isEmpty)
}

@Test func conflictDuplicateStatusAndPolicyContracts() throws {
    let operationID = UUID(uuidString: "abcdef00-0000-0000-0000-000000000000")!
    let date = Date(timeIntervalSince1970: 0)
    let decision = ConflictResolver.decide(
        kind: .upload,
        displayName: "report.txt",
        expectedVersion: Data([1]),
        currentRemoteVersion: Data([2]),
        localChanged: true,
        operationID: operationID,
        now: date
    )
    guard case .preserveLocalAs(let name) = decision else {
        Issue.record("Expected preserved conflict")
        return
    }
    #expect(name.hasPrefix("report (conflict from MOUNTLI 1970-01-01"))
    #expect(name.hasSuffix("abcdef).txt"))

    let now = Date.now
    let duplicates = DuplicateResolver.project(
        [
            RemoteItem(path: "a", name: "Same", size: 1, modificationDate: now, isDirectory: false, objectID: "1", fingerprint: "1", mimeType: nil),
            RemoteItem(path: "b", name: "same", size: 1, modificationDate: now, isDirectory: false, objectID: "2", fingerprint: "2", mimeType: nil),
        ], caseInsensitive: true)
    #expect(duplicates.count == 1)
    #expect(duplicates[0].duplicates.count == 1)

    #expect(
        StatusAggregator.mountStatus(
            enabled: true, paused: false, reachable: true, authenticated: false,
            activeTransfers: 0, retryableFailures: 0, nonRetryableFailures: 0, cachedDataUsable: true
        ) == .authenticationRequired)

    let policyResult = ManagedPolicyReader.parse(
        dictionary: [
            "PolicyVersion": 1,
            "AllowedBackendTypes": ["webdav", "made-up"],
            "ForceReadOnly": true,
            "MaximumConcurrentTransfers": 99,
            "SupportURL": "http://insecure.invalid",
        ],
        catalog: ["webdav", "sftp"],
        platformTransferRange: 1...4
    )
    #expect(policyResult.policy.allowedBackendTypes == ["webdav"])
    #expect(policyResult.policy.maximumConcurrentTransfers == 4)
    #expect(policyResult.policy.forceReadOnly)
    #expect(policyResult.issues.count == 3)
}

@Test func managedPolicyRejectsMalformedBridgedValuesWithoutWeakeningRestrictions() {
    let valid = ManagedPolicyReader.parse(
        dictionary: [
            "PolicyVersion": NSNumber(value: 1),
            "MaximumConcurrentTransfers": NSNumber(value: 3),
        ],
        catalog: ["webdav"],
        platformTransferRange: 1...4
    )
    #expect(valid.policy.maximumConcurrentTransfers == 3)

    let malformed = ManagedPolicyReader.parse(
        dictionary: [
            "PolicyVersion": NSNumber(value: 1),
            "ForceReadOnly": NSNumber(value: 1),
            "MaximumConcurrentTransfers": NSNumber(value: true),
        ],
        catalog: ["webdav"],
        platformTransferRange: 1...4
    )
    #expect(!malformed.policy.forceReadOnly)
    #expect(malformed.policy.maximumConcurrentTransfers == nil)
    #expect(malformed.issues.map(\.diagnosticCode).contains("POLICY_FORCEREADONLY_INVALID"))
    #expect(malformed.issues.map(\.diagnosticCode).contains("POLICY_TRANSFER_LIMIT_INVALID"))
}

@Test func managedPolicyBlocksDisallowedAndInsecureRemotesWithoutExposingOptions() {
    let remote = RemoteProfile.make(
        displayName: "Private storage",
        backendType: "webdav",
        options: [
            "no_check_certificate": "true",
            "password": "top-secret-value",
        ]
    )
    let policy = ManagedPolicy(allowedBackendTypes: ["sftp"], allowInsecureTLS: false)
    #expect(policy.violations(for: remote) == [.backendNotAllowed, .insecureTLSNotAllowed])
    let document = VaultDocument(remotes: [remote])
    let issues = policy.issues(for: document)
    #expect(issues.count == 2)
    #expect(issues.allSatisfy { !$0.impact.contains("top-secret-value") })
}

@Test func managedPolicyAttributesBlockedOverlayDependenciesToMountedLocation() {
    let base = RemoteProfile.make(displayName: "Base", backendType: "s3")
    let overlay = RemoteProfile.make(
        displayName: "Encrypted",
        backendType: "crypt",
        options: ["remote": "\(base.engineName):data"]
    )
    let mount = MountDefinition(remoteID: overlay.id, displayName: "Files")
    let policy = ManagedPolicy(allowedBackendTypes: ["crypt"])
    let issues = policy.issues(for: VaultDocument(remotes: [base, overlay], mounts: [mount]))
    #expect(issues.contains { $0.mountID == mount.id && $0.diagnosticCode == "POLICY_BACKEND_BLOCKED" })
}

@Test func remoteIdentityPolicyPinsSFTPAndRejectsDisabledVerification() throws {
    let secured = try RemoteIdentityPolicy.secureOptions(
        backendType: "sftp",
        options: ["host": "storage.example"]
    )
    #expect(secured["pin_host_key"] == "true")
    #expect(
        try RemoteIdentityPolicy.secureOptions(
            backendType: "sftp",
            options: ["known_hosts_file": "/protected/known_hosts"]
        )["pin_host_key"] == nil)
    #expect(throws: RemoteIdentityPolicyError.disabledSSHHostValidation) {
        try RemoteIdentityPolicy.secureOptions(
            backendType: "sftp",
            options: ["known_hosts_file": "none"]
        )
    }
    #expect(
        try RemoteIdentityPolicy.secureOptions(
            backendType: "webdav",
            options: ["url": "https://storage.example"]
        )["pin_host_key"] == nil)
}

@Test func networkPoliciesRespectPathCostAndInterface() {
    let cellular = NetworkPathSnapshot(
        isOnline: true,
        isWiFiOrWired: false,
        isExpensive: true,
        isConstrained: false,
        isCellular: true
    )
    #expect(cellular.allows(.allNetworks))
    #expect(!cellular.allows(.allNetworks, allowCellular: false))
    #expect(!cellular.allows(.wifiOnly))
    #expect(!cellular.allows(.avoidConstrained))

    let wired = NetworkPathSnapshot(
        isOnline: true,
        isWiFiOrWired: true,
        isExpensive: false,
        isConstrained: false
    )
    #expect(wired.allows(.wifiOnly))
    #expect(wired.allows(.avoidConstrained))
    #expect(
        !NetworkPathSnapshot(
            isOnline: false,
            isWiFiOrWired: true,
            isExpensive: false,
            isConstrained: false
        ).allows(.allNetworks))
}

@Test func structuredLogsPersistTokensWithoutRawPaths() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
    let key = Data(repeating: 0x42, count: 32)
    let tokenizer = PathTokenizer(keyData: key)
    let logger = MountliLogger(category: .transfer, tokenizer: tokenizer) {
        category, level, message, createdAt in
        try? await store.recordDiagnosticLog(
            category: category,
            level: level,
            message: message,
            createdAt: createdAt
        )
    }
    let privatePath = "/Users/example/Secret/customer-list.txt"
    let expectedToken = tokenizer.token(for: privatePath)
    logger.notice(
        "download https://secret.example/private access_token=top-secret user@example.com",
        path: privatePath
    )
    var logs: [String] = []
    for _ in 0..<100 where logs.isEmpty {
        await Task.yield()
        logs = try await store.recentDiagnosticLogs()
    }
    #expect(logs.count == 1)
    #expect(logs[0].contains("path-token=\(expectedToken)"))
    #expect(!logs[0].contains(privatePath))
    #expect(!logs[0].contains("customer-list"))
    #expect(!logs[0].contains("secret.example"))
    #expect(!logs[0].contains("top-secret"))
    #expect(!logs[0].contains("user@example.com"))
}

@Test func diagnosticsExportIsPrivateZipAndCleansUp() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stale = directory.appendingPathComponent("MOUNTLI-Diagnostics-stale.zip")
    try Data("stale".utf8).write(to: stale)
    try FileManager.default.setAttributes(
        [.modificationDate: Date.now.addingTimeInterval(-3_600)],
        ofItemAtPath: stale.path
    )
    let exporter = DiagnosticsExporter()
    let snapshot = DiagnosticSnapshot(
        appVersion: "1.0",
        buildNumber: "1",
        rcloneVersion: "1.75.2",
        deviceClass: "Test",
        policy: ManagedPolicy(supportURL: URL(string: "https://secret.example/private-support")),
        mounts: [
            DiagnosticMount(
                backendType: "memory",
                status: .online,
                pendingOperations: 0,
                unresolvedIssues: 0
            )
        ],
        issueCodes: ["TEST_CODE"],
        operationTimingMilliseconds: ["list": 12],
        sqliteIntegrity: "ok",
        recentLogs: [
            "code=TEST_CODE path=/Users/example/Secret/customer-list.txt access_token=top-secret user@example.com"
        ],
        includedFileNames: ["user-approved.txt"]
    )
    let archive = try await exporter.export(snapshot, in: directory)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    let data = try Data(contentsOf: archive)
    #expect(data.starts(with: [0x50, 0x4b, 0x03, 0x04]))
    let archiveText = String(decoding: data, as: UTF8.self)
    #expect(!archiveText.contains("secret.example"))
    #expect(!archiveText.contains("customer-list.txt"))
    #expect(!archiveText.contains("top-secret"))
    #expect(!archiveText.contains("user@example.com"))
    #expect(archiveText.contains("<redacted-path>"))
    #expect(archiveText.contains("user-approved.txt"))
    #expect(snapshot.policy.supportURLConfigured)
    #expect(snapshot.fileNamesIncluded)
    let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try await exporter.finishSharing(archive)
    #expect(!FileManager.default.fileExists(atPath: archive.path))
}

@Test func bridgeCatalogAndConfigurationEnvelopeDecode() async throws {
    let client = GoRcloneClient()
    let catalog = try await client.providerCatalog()
    #expect(catalog.count > 50)
    #expect(catalog.contains { $0.name == "crypt" })
    #expect(catalog.contains { $0.name == "memory" && $0.testOnly })

    let configuration = GoConfigurationClient()
    var step = try await configuration.start(engineName: "contract-memory", backendType: "memory")
    while step.status == .question {
        step = try await configuration.continueConfiguration(
            sessionID: step.sessionID,
            answer: step.option?.defaultValue ?? ""
        )
    }
    #expect(step.status == .complete)
    #expect(step.backendType == "memory")
    #expect(step.options?.isEmpty == true)
}

@Test func importedConfigurationPreservesSectionNamesAndResourceRequirements() throws {
    let data = Data(
        """
        {
          "sections": [
            {"engineName":"base","backendType":"sftp","options":{"key_file":"/tmp/key"}},
            {"engineName":"encrypted","backendType":"crypt","options":{"remote":"base:private"}}
          ],
          "encrypted":true,
          "resourceRequirements":[
            {
              "engineName":"base",
              "backendType":"sftp",
              "optionName":"key_file",
              "path":"/tmp/key",
              "kind":"sshPrivateKey"
            }
          ]
        }
        """.utf8
    )
    let result = try JSONDecoder().decode(ConfigImportResult.self, from: data)
    #expect(result.sections.map(\.engineName) == ["base", "encrypted"])
    #expect(result.sections[1].options["remote"] == "base:private")
    #expect(result.resourceRequirements.first?.kind == "sshPrivateKey")
}

@Test func managedResourcePayloadIsStoredOnlyInsideEncryptedVault() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("private-key")
    let secret = Data("private-resource-secret".utf8)
    try secret.write(to: source)
    let resources = ResourceStore(appGroupRoot: directory)
    let reference = try await resources.importFile(
        from: source,
        kind: .sshPrivateKey,
        displayName: "private-key"
    )
    let token = await resources.optionValue(for: reference)
    #expect(token.hasPrefix(ResourceStore.optionPrefix))

    var remote = RemoteProfile.make(
        displayName: "Resource remote",
        backendType: "sftp",
        options: ["key_file": token]
    )
    remote.resources = [reference]
    let vault = EncryptedVaultStore(
        directory: directory,
        keyProvider: FixedKeyProvider(data: Data(repeating: 0x27, count: 32))
    )
    let snapshot = try await vault.save(VaultDocument(remotes: [remote]), expectedRevision: 0)
    let encrypted = try Data(contentsOf: directory.appendingPathComponent("vault.bin"))
    #expect(encrypted.range(of: secret) == nil)

    let runtime = try await resources.materialize(snapshot)
    let materializedPath = try #require(runtime.document.remotes[0].options["key_file"])
    #expect(try Data(contentsOf: URL(fileURLWithPath: materializedPath)) == secret)
    let exportable = try await resources.exportable(snapshot)
    #expect(exportable.document.remotes[0].options["key_file"] == source.path)
    try await resources.removeAll()
    #expect(!FileManager.default.fileExists(atPath: materializedPath))
}

@Test func localResourceSandboxRejectsPrivateAndProviderStorage() throws {
    let appGroup = URL(fileURLWithPath: "/tmp/mountli-sandbox/app-group", isDirectory: true)
    let temporary = URL(fileURLWithPath: "/tmp/mountli-sandbox/temporary", isDirectory: true)
    let provider = URL(fileURLWithPath: "/tmp/mountli-sandbox/provider", isDirectory: true)

    #expect(throws: BridgeFailure.self) {
        try LocalResourceValidator.validateSelectedDirectory(
            appGroup.appendingPathComponent("cache", isDirectory: true),
            appGroupURL: appGroup,
            temporaryDirectory: temporary,
            fileProviderStorageURLs: [provider]
        )
    }
    #expect(throws: BridgeFailure.self) {
        try LocalResourceValidator.validateSelectedDirectory(
            provider.appendingPathComponent("nested", isDirectory: true),
            appGroupURL: appGroup,
            temporaryDirectory: temporary,
            fileProviderStorageURLs: [provider]
        )
    }
    try LocalResourceValidator.validateSelectedDirectory(
        URL(fileURLWithPath: "/tmp/mountli-sandbox/user-selected", isDirectory: true),
        appGroupURL: appGroup,
        temporaryDirectory: temporary,
        fileProviderStorageURLs: [provider]
    )
}

@Test func userFacingErrorsCarryReadableMessages() {
    let auth = BridgeFailure(kind: .notAuthenticated, message: "401 Unauthorized", retryable: false) as Error
    #expect(auth.localizedDescription.hasPrefix("The storage provider rejected the credentials."))
    #expect(auth.localizedDescription.hasSuffix("401 Unauthorized"))
    let bare = BridgeFailure(kind: .unreachable, message: "", retryable: true) as Error
    #expect(!bare.localizedDescription.contains("\n"))

    let errors: [any Error] = [
        DomainRegistryError.unavailable("Enter a name for this mount."),
        DomainRegistryError.dirtyOperations(2),
        ResourceStoreError.invalidSelection("Choose a local folder before adding this mount."),
        DependencyGraphError.remoteInUse(remote: "base", dependents: ["Photos"]),
        ItemRepositoryError.removalInProgress(UUID()),
    ]
    for error in errors {
        #expect(!error.localizedDescription.contains("MountliCore."))
    }
    #expect(DomainRegistryError.unavailable("Enter a name for this mount.").localizedDescription == "Enter a name for this mount.")
    #expect(DomainRegistryError.dirtyOperations(1).localizedDescription.hasPrefix("1 change is"))
}

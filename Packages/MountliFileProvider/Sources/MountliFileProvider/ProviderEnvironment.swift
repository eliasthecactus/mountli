@preconcurrency import FileProvider
import Foundation
import MountliCore

public enum ProviderEnvironmentError: Error, Sendable {
    case missingAppGroup
    case missingAccessGroup
    case unknownDomain(String)
    case missingRemote(UUID)
    case invalidItemIdentifier(String)
}

public actor ProviderEnvironment {
    public let domain: NSFileProviderDomain
    private let vaultStore: EncryptedVaultStore
    private let stateStore: SQLiteStore
    private let resourceStore: ResourceStore
    private let stagingArea: ProviderStagingArea
    private let client: any RcloneClient
    private let logger: MountliLogger?
    private let processRuntime: ProviderProcessRuntime?
    private var snapshot: VaultSnapshot?
    private var loadedRevision: UInt64?
    private var managedPolicy = ManagedPolicy()
    private let networkMonitor = ProviderNetworkMonitor()
    private let operationOwner = "provider-\(UUID().uuidString.lowercased())"
    private var transferLimit: Int
    private let explicitTransferLimit: Int?
    private let watcherID = "domain-\(UUID().uuidString.lowercased())"
    private var watcherStarted = false
    private var invalidated = false
    private var activeResourceIDs: Set<UUID> = []
    private var activeResourceURLs: [URL] = []
    nonisolated private let progressRegistry: ProviderProgressRegistry

    public init(
        domainIdentifier: String,
        displayName: String,
        appGroupURL: URL,
        keychainAccessGroup: String,
        transferLimit: Int? = nil,
        client: (any RcloneClient)? = nil
    ) async throws {
        domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(domainIdentifier),
            displayName: displayName
        )
        vaultStore = EncryptedVaultStore(
            directory: appGroupURL,
            keyProvider: KeychainKeyProvider(accessGroup: keychainAccessGroup)
        )
        resourceStore = ResourceStore(appGroupRoot: appGroupURL)
        let stagingArea = try ProviderStagingArea(root: appGroupURL)
        let stateStore = try await SQLiteStore(databaseURL: appGroupURL.appendingPathComponent("state.sqlite3"))
        _ = try await stateStore.recoverInterruptedOperations()
        try? stagingArea.cleanupStale(
            olderThan: .now.addingTimeInterval(-86_400),
            activeOperationIDs: try await stateStore.activeOperationIDs()
        )
        self.stagingArea = stagingArea
        self.stateStore = stateStore
        if let keyData = try? MountliLogging.installLocalKey(
            provider: KeychainKeyProvider(
                service: "ch.benavo.mountli.logging",
                account: "path-tokenizer",
                accessGroup: keychainAccessGroup
            )
        ) {
            logger = MountliLogger(
                category: .provider,
                tokenizer: PathTokenizer(keyData: keyData)
            ) { category, level, message, createdAt in
                try? await stateStore.recordDiagnosticLog(
                    category: category,
                    level: level,
                    message: message,
                    createdAt: createdAt
                )
            }
        } else {
            logger = nil
        }
        #if os(macOS)
            let platformMaximum = 8
            let platformDefault = 4
        #else
            let platformMaximum = 4
            let platformDefault = 2
        #endif
        explicitTransferLimit = transferLimit
        self.transferLimit = min(max(transferLimit ?? platformDefault, 1), platformMaximum)
        let processRuntime: ProviderProcessRuntime?
        let effectiveClient: any RcloneClient
        let progressRegistry: ProviderProgressRegistry
        if let client {
            processRuntime = nil
            effectiveClient = client
            progressRegistry = ProviderProgressRegistry()
        } else {
            let runtime = ProviderProcessRuntime.shared
            processRuntime = runtime
            effectiveClient = runtime.client
            progressRegistry = runtime.progressRegistry
        }
        self.processRuntime = processRuntime
        self.progressRegistry = progressRegistry
        self.client = effectiveClient
        if let processRuntime {
            await processRuntime.retain(vaultStore: vaultStore, stateStore: stateStore)
        } else {
            let mutationStore = vaultStore
            await effectiveClient.configureVaultMutations { mutation in
                _ = try await mutationStore.applyRcloneMutation(mutation)
            }
            await effectiveClient.configureProgress { operationID, completed, total in
                Task {
                    try? await stateStore.updateOperationProgress(
                        id: operationID,
                        completedBytes: completed,
                        totalBytes: total
                    )
                    progressRegistry.update(operationID: operationID, completed: completed, total: total)
                }
            }
        }
    }

    public static func live(domainIdentifier: String, displayName: String) async throws -> ProviderEnvironment {
        guard
            let appGroupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.ch.benavo.mountli"
            )
        else { throw ProviderEnvironmentError.missingAppGroup }
        guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: "MOUNTLIKeychainAccessGroup") as? String,
            !accessGroup.isEmpty
        else { throw ProviderEnvironmentError.missingAccessGroup }
        return try await ProviderEnvironment(
            domainIdentifier: domainIdentifier,
            displayName: displayName,
            appGroupURL: appGroupURL,
            keychainAccessGroup: accessGroup
        )
    }

    public func configuration() async throws -> (VaultSnapshot, MountDefinition, RemoteProfile) {
        let latest = try await vaultStore.load()
        refreshManagedPolicy(document: latest.document)
        let domainIdentifier = domain.identifier.rawValue
        guard var mount = latest.document.mounts.first(where: { $0.domainIdentifier == domainIdentifier }) else {
            throw ProviderEnvironmentError.unknownDomain(domainIdentifier)
        }
        guard let remote = latest.document.remotes.first(where: { $0.id == mount.remoteID }) else {
            throw ProviderEnvironmentError.missingRemote(mount.remoteID)
        }
        let dependencies = try dependencyRemotes(for: remote, in: latest.document.remotes)
        let restrictions = dependencies.flatMap { managedPolicy.violations(for: $0) }
        mount.readOnly = mount.readOnly || managedPolicy.forceReadOnly || !restrictions.isEmpty

        if snapshot?.revision != latest.revision {
            deactivateResources()
            await stopChangeNotifications()
            snapshot = latest
        }
        if restrictions.isEmpty {
            for dependency in dependencies {
                try await activateResources(for: dependency)
            }
            mount.root = try await resolvedRoot(for: mount.root, remote: remote)
            if loadedRevision != latest.revision {
                let providerSnapshot = try await materializedSnapshot(latest)
                try await client.loadVault(providerSnapshot)
                loadedRevision = latest.revision
                logger?.notice("provider configuration loaded", path: mount.root)
            }
            do {
                try networkMonitor.requireAccess(
                    for: mount.networkPolicy,
                    allowCellular: managedPolicy.allowCellular
                )
                await ensureChangeNotifications(remote: remote, mount: mount)
            } catch {
                await stopChangeNotifications()
            }
        } else {
            logger?.error(
                code: "POLICY_REMOTE_BLOCKED",
                message: "managed policy blocked provider access",
                path: mount.root
            )
            deactivateResources()
            await stopChangeNotifications()
        }
        return (latest, mount, remote)
    }

    private func refreshManagedPolicy(document: VaultDocument) {
        #if os(macOS)
            let platformMaximum = 8
            let userLimit = document.settings.maximumConcurrentTransfersMacOS
        #else
            let platformMaximum = 4
            let userLimit = document.settings.maximumConcurrentTransfersIOS
        #endif
        let dictionary = UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed") ?? [:]
        if dictionary.isEmpty {
            managedPolicy = ManagedPolicyCache.load() ?? ManagedPolicy()
        } else {
            let declaredBackends = Set(dictionary["AllowedBackendTypes"] as? [String] ?? [])
            let knownBackends = Set(document.remotes.map(\.backendType)).union(declaredBackends)
            managedPolicy =
                ManagedPolicyReader.parse(
                    dictionary: dictionary,
                    catalog: knownBackends,
                    platformTransferRange: 1...platformMaximum
                ).policy
        }
        guard explicitTransferLimit == nil else { return }
        transferLimit = min(
            max(managedPolicy.maximumConcurrentTransfers ?? userLimit, 1),
            platformMaximum
        )
    }

    private func activateResources(for remote: RemoteProfile) async throws {
        for reference in remote.resources
        where reference.kind == .securityScopedDirectory && !activeResourceIDs.contains(reference.id) {
            let url = try await resourceStore.resolve(reference)
            guard url.startAccessingSecurityScopedResource() else {
                throw ResourceStoreError.invalidSelection("The selected local folder is no longer accessible.")
            }
            activeResourceIDs.insert(reference.id)
            activeResourceURLs.append(url)
        }
    }

    private func dependencyRemotes(
        for remote: RemoteProfile,
        in remotes: [RemoteProfile]
    ) throws -> [RemoteProfile] {
        let graph = try RemoteDependencyGraph(remotes: remotes)
        let byName = Dictionary(uniqueKeysWithValues: remotes.map { ($0.engineName, $0) })
        var names = Set([remote.engineName])
        var pending = [remote.engineName]
        while let name = pending.popLast() {
            for dependency in graph.dependencies[name, default: []] where names.insert(dependency).inserted {
                pending.append(dependency)
            }
        }
        return names.sorted().compactMap { byName[$0] }
    }

    private func resolvedRoot(for root: String, remote: RemoteProfile) async throws -> String {
        guard remote.backendType == "local" else { return root }
        let references = remote.resources.filter { $0.kind == .securityScopedDirectory }
        if root.hasPrefix(ResourceStore.optionPrefix) {
            guard
                let reference = references.first(where: {
                    let marker = ResourceStore.optionPrefix + $0.id.uuidString.lowercased()
                    return root == marker || root.hasPrefix(marker + "/")
                })
            else {
                throw BridgeFailure(
                    kind: .permissionDenied,
                    message: "The local folder reference for this mount is unavailable.",
                    retryable: false
                )
            }
            let marker = ResourceStore.optionPrefix + reference.id.uuidString.lowercased()
            let suffix = String(root.dropFirst(marker.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let url = try await resourceStore.resolve(reference)
            return suffix.isEmpty ? url.path : url.appendingPathComponent(suffix).path
        }
        guard let reference = references.first else { return root }
        return try await resourceStore.resolve(reference).path
    }

    private func materializedSnapshot(_ snapshot: VaultSnapshot) async throws -> VaultSnapshot {
        var materialized = try await resourceStore.materialize(snapshot)
        let references = Dictionary(
            uniqueKeysWithValues: snapshot.document.remotes
                .flatMap(\.resources)
                .filter { $0.kind == .securityScopedDirectory }
                .map { (ResourceStore.optionPrefix + $0.id.uuidString.lowercased(), $0) })
        guard !references.isEmpty else { return materialized }
        for index in materialized.document.remotes.indices {
            for (key, value) in materialized.document.remotes[index].options {
                var rewritten = value
                for (marker, reference) in references where rewritten.contains(marker) {
                    let resolved = try await resourceStore.resolve(reference)
                    rewritten = rewritten.replacingOccurrences(of: marker, with: resolved.path)
                }
                materialized.document.remotes[index].options[key] = rewritten
            }
        }
        return materialized
    }

    private func deactivateResources() {
        activeResourceURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        activeResourceURLs.removeAll()
        activeResourceIDs.removeAll()
    }

    private func stopChangeNotifications() async {
        guard watcherStarted else { return }
        await client.stopChangeNotifications(watcherID: watcherID)
        if let processRuntime {
            await processRuntime.unregisterChanges(watcherID: watcherID)
        }
        watcherStarted = false
    }

    private func ensureChangeNotifications(remote: RemoteProfile, mount: MountDefinition) async {
        guard !watcherStarted else { return }
        watcherStarted = true
        let notificationDomain = ProviderUncheckedSendable(domain)
        let expectedWatcherID = watcherID
        let handler: @Sendable ([String]) async -> Void = { [weak self] paths in
            await self?.refreshRemoteChanges(
                paths: paths,
                mount: mount,
                domain: notificationDomain.value
            )
        }
        if let processRuntime {
            await processRuntime.registerChanges(watcherID: watcherID, handler: handler)
        } else {
            await client.configureChangeNotifications { receivedWatcherID, paths in
                guard receivedWatcherID == expectedWatcherID else { return }
                Task { await handler(paths) }
            }
        }
        let interval: Int
        switch mount.pollingPolicy {
        case .frequent: interval = 60
        case .batterySaving: interval = 900
        case .automatic: interval = 300
        }
        do {
            try await client.startChangeNotifications(
                watcherID: watcherID,
                remote: remote,
                root: mount.root,
                interval: interval
            )
        } catch {
            watcherStarted = false
            if let processRuntime {
                await processRuntime.unregisterChanges(watcherID: watcherID)
            }
        }
    }

    private func refreshRemoteChanges(
        paths: [String],
        mount: MountDefinition,
        domain: NSFileProviderDomain
    ) async {
        var changedContainers: Set<NSFileProviderItemIdentifier> = [.rootContainer]
        do {
            _ = try await children(parent: .rootContainer)
            let root = normalizedRemotePath(mount.root)
            var directoryPaths: Set<String> = []
            for path in paths {
                let normalized = normalizedRemotePath(path)
                guard normalized == root || root.isEmpty || normalized.hasPrefix(root + "/") else {
                    continue
                }
                let parent = normalized.split(separator: "/", omittingEmptySubsequences: true)
                    .dropLast()
                    .joined(separator: "/")
                if parent != root {
                    directoryPaths.insert(parent)
                }
                if let item = try await stateStore.item(remotePath: normalized, mountID: mount.id),
                    item.isDirectory
                {
                    directoryPaths.insert(normalized)
                }
            }
            for directoryPath in directoryPaths.sorted() {
                guard
                    let parent = try await stateStore.item(
                        remotePath: directoryPath,
                        mountID: mount.id
                    )
                else { continue }
                let identifier = NSFileProviderItemIdentifier(
                    "item.\(parent.id.uuidString.lowercased())"
                )
                _ = try await children(parent: identifier)
                changedContainers.insert(identifier)
            }
        } catch {
            // Signaling still lets File Provider retry each affected enumeration.
        }
        guard let manager = NSFileProviderManager(for: domain) else { return }
        for identifier in changedContainers.sorted(by: { $0.rawValue < $1.rawValue }) {
            try? await manager.signalEnumerator(for: identifier)
        }
        try? await manager.signalEnumerator(for: .workingSet)
    }

    private func normalizedRemotePath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
    }

    public func requireNetworkAccess(for mount: MountDefinition) throws {
        if let document = snapshot?.document {
            refreshManagedPolicy(document: document)
        }
        try requirePolicyAccess(for: mount)
        try networkMonitor.requireAccess(
            for: mount.networkPolicy,
            allowCellular: managedPolicy.allowCellular
        )
    }

    private func requirePolicyAccess(for mount: MountDefinition) throws {
        guard
            let document = snapshot?.document,
            let remote = document.remotes.first(where: { $0.id == mount.remoteID })
        else { throw ProviderEnvironmentError.missingRemote(mount.remoteID) }
        let dependencies = try dependencyRemotes(for: remote, in: document.remotes)
        if let restriction = dependencies.lazy.compactMap({ self.managedPolicy.violations(for: $0).first }).first {
            throw BridgeFailure(
                kind: .permissionDenied,
                message: restriction.impact,
                retryable: false
            )
        }
    }

    private func requireMutationAdmission(kind: OperationKind, mount: MountDefinition) throws {
        switch kind {
        case .upload, .createDirectory, .move, .delete:
            try requirePolicyAccess(for: mount)
            guard !mount.readOnly && !managedPolicy.forceReadOnly else {
                throw BridgeFailure(
                    kind: .permissionDenied,
                    message: ManagedPolicyRestriction.readOnly.impact,
                    retryable: false
                )
            }
        case .enumerate, .download, .refresh:
            break
        }
    }

    public func storedItem(identifier: NSFileProviderItemIdentifier) async throws -> StoredItem? {
        if identifier == .rootContainer { return nil }
        guard identifier.rawValue.hasPrefix("item."),
            let id = UUID(uuidString: String(identifier.rawValue.dropFirst("item.".count)))
        else { throw ProviderEnvironmentError.invalidItemIdentifier(identifier.rawValue) }
        let (_, mount, _) = try await configuration()
        guard let item = try await stateStore.item(id: id, mountID: mount.id) else {
            throw BridgeFailure(kind: .notFound, message: "The parent or item no longer exists.", retryable: false)
        }
        return item
    }

    public func children(parent: NSFileProviderItemIdentifier) async throws -> [StoredItem] {
        let (_, mount, remote) = try await configuration()
        try requireNetworkAccess(for: mount)
        try await processPendingIssueResolutionRequests(mount: mount, remote: remote)
        let parentItem = try await storedItem(identifier: parent)
        let directory = parentItem?.remotePath ?? mount.root
        let owner = "\(operationOwner)-enumeration-\(UUID().uuidString.lowercased())"
        while try await stateStore.acquireEnumerationLease(
            mountID: mount.id,
            containerID: parentItem?.id,
            owner: owner,
            ttl: 30
        ) == false {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
        let renewal = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                _ = try? await stateStore.renewEnumerationLease(
                    mountID: mount.id,
                    containerID: parentItem?.id,
                    owner: owner,
                    ttl: 30
                )
            }
        }
        do {
            let capabilities = try await client.capabilities(remote: remote, root: mount.root)
            var token: String?
            var remoteItems: [RemoteItem] = []
            repeat {
                let page = try await client.list(
                    remote: remote,
                    directory: directory,
                    pageToken: token,
                    pageSize: 500
                )
                remoteItems.append(contentsOf: page.items)
                token = page.nextPageToken
                guard
                    try await stateStore.renewEnumerationLease(
                        mountID: mount.id,
                        containerID: parentItem?.id,
                        owner: owner,
                        ttl: 30
                    )
                else {
                    throw BridgeFailure(
                        kind: .unreachable,
                        message: "The directory listing lease expired; retrying is safe.",
                        retryable: true
                    )
                }
            } while token != nil
            let projected = ProviderDuplicateProjection.project(remoteItems, capabilities: capabilities)
            _ = try await stateStore.reconcile(
                mountID: mount.id,
                parentID: parentItem?.id,
                remoteItems: projected,
                enumerationOwner: owner
            )
            renewal.cancel()
            try await stateStore.releaseEnumerationLease(
                mountID: mount.id,
                containerID: parentItem?.id,
                owner: owner
            )
            let children = try await stateStore.children(parentID: parentItem?.id, mountID: mount.id)
            try await reconcileDuplicateIssues(in: children, mountID: mount.id)
            return children
        } catch {
            renewal.cancel()
            try? await stateStore.releaseEnumerationLease(
                mountID: mount.id,
                containerID: parentItem?.id,
                owner: owner
            )
            throw error
        }
    }

    public func workingSet() async throws -> [StoredItem] {
        let (_, mount, _) = try await configuration()
        return try await stateStore.workingSet(
            mountID: mount.id,
            accessedAfter: .now.addingTimeInterval(-30 * 24 * 60 * 60)
        )
    }

    public func backendCapabilities() async throws -> BackendCapabilities {
        let (_, mount, remote) = try await configuration()
        try requirePolicyAccess(for: mount)
        return try await effectiveCapabilities(remote: remote, mount: mount)
    }

    private func effectiveCapabilities(
        remote: RemoteProfile,
        mount: MountDefinition
    ) async throws -> BackendCapabilities {
        var capabilities = try await client.capabilities(remote: remote, root: mount.root)
        if mount.readOnly || managedPolicy.forceReadOnly {
            capabilities.readOnly = true
            capabilities.writeMimeType = false
            capabilities.serverSideCopy = false
            capabilities.serverSideMove = false
            capabilities.serverSideDirectoryMove = false
        }
        return capabilities
    }

    public func authorizeFreshVersion(
        of item: StoredItem,
        baseContentVersion: Data,
        remote: RemoteProfile,
        operationKind: OperationKind
    ) async throws -> RemoteItem {
        let (_, mount, currentRemote) = try await configuration()
        try requireNetworkAccess(for: mount)
        guard currentRemote.id == remote.id else {
            throw ProviderEnvironmentError.missingRemote(remote.id)
        }
        guard baseContentVersion == item.contentVersion else {
            try await recordVersionConflict(
                item: item,
                mountID: mount.id,
                operationKind: operationKind
            )
            throw BridgeFailure(kind: .conflict, message: "The remote version changed.", retryable: false)
        }
        let fresh = try await client.stat(remote: remote, path: item.remotePath, objectID: item.remoteID)
        guard StoredItemVersion.contentVersion(for: fresh) == baseContentVersion else {
            try await recordVersionConflict(
                item: item,
                mountID: mount.id,
                operationKind: operationKind
            )
            throw BridgeFailure(kind: .conflict, message: "The remote version changed.", retryable: false)
        }
        return fresh
    }

    public func resolveVersionConflicts(for itemID: UUID) async throws {
        let (_, mount, _) = try await configuration()
        for issue in try await stateStore.openIssues(mountID: mount.id, limit: 500)
        where issue.kind == .conflict && issue.itemID == itemID {
            _ = try await stateStore.resolveIssue(id: issue.id, at: .now)
        }
    }

    public func recordVersionConflict(
        item: StoredItem,
        mountID: UUID,
        operationKind: OperationKind
    ) async throws {
        _ = try await stateStore.recordIssue(
            Self.versionConflictIssue(
                item: item,
                mountID: mountID,
                operationKind: operationKind
            ))
    }

    static func versionConflictIssue(
        item: StoredItem,
        mountID: UUID,
        operationKind: OperationKind
    ) -> IssueRecord {
        let hasStableIdentity = item.remoteID?.isEmpty == false
        let actions: [IssueResolutionAction]
        if operationKind == .delete {
            actions = hasStableIdentity ? [.deleteAnyway, .keepRemote] : [.keepRemote]
        } else {
            actions = [.retry]
        }
        return IssueRecord(
            mountID: mountID,
            itemID: item.id,
            kind: .conflict,
            diagnosticCode: "provider.versionConflict.\(operationKind.rawValue)",
            message: "The remote item changed before Mountli could safely apply the requested operation. No overwrite or deletion was attempted.",
            retryable: operationKind != .delete,
            remoteObjectID: hasStableIdentity ? item.remoteID : nil,
            remotePath: nil,
            redactedPathToken: nil,
            defaultRename: nil,
            suggestedActions: actions
        )
    }

    private func reconcileDuplicateIssues(in items: [StoredItem], mountID: UUID) async throws {
        let aliases = items.filter(ProviderDuplicateProjection.isReadOnlyAlias)
        let activeItemIDs = Set(aliases.map(\.id))
        for item in aliases {
            _ = try await stateStore.recordIssue(Self.duplicateIssue(item: item, mountID: mountID))
        }
        for issue in try await stateStore.openIssues(mountID: mountID, limit: 500)
        where issue.kind == .duplicate
            && issue.itemID.map(activeItemIDs.contains) != true
        {
            _ = try await stateStore.resolveIssue(id: issue.id, at: .now)
        }
    }

    static func duplicateIssue(item: StoredItem, mountID: UUID) -> IssueRecord {
        let hasStableIdentity = item.remoteID?.isEmpty == false
        return IssueRecord(
            mountID: mountID,
            itemID: item.id,
            kind: .duplicate,
            diagnosticCode: "provider.duplicateName",
            message: hasStableIdentity
                ? "Another remote object projects to the same Finder or Files name. This alias is read-only until you resolve it."
                : "Another remote object projects to the same Finder or Files name. The backend exposes no stable object identifier, so resolve it using the provider's website or rclone.",
            retryable: false,
            remoteObjectID: hasStableIdentity ? item.remoteID : nil,
            remotePath: nil,
            redactedPathToken: nil,
            defaultRename: nil,
            suggestedActions: hasStableIdentity ? [.deleteDuplicate, .renameDuplicate] : []
        )
    }

    private func processPendingIssueResolutionRequests(
        mount: MountDefinition,
        remote: RemoteProfile
    ) async throws {
        let requests = try await stateStore.pendingIssueResolutionRequests(mountID: mount.id, limit: 100)
        for request in requests {
            guard let issue = try await stateStore.issue(id: request.issueID),
                issue.resolvedAt == nil,
                issue.mountID == mount.id,
                issue.suggestedActions.contains(request.action)
            else {
                try await stateStore.clearIssueResolutionRequest(issueID: request.issueID)
                continue
            }
            do {
                switch request.action {
                case .retry, .reconnect:
                    try await stateStore.clearIssueResolutionRequest(issueID: issue.id)
                    await signalIssueEnumerators(issue, mountID: mount.id)
                case .keepRemote:
                    _ = try await stateStore.resolveIssue(id: issue.id, at: .now)
                    try await stateStore.clearIssueResolutionRequest(issueID: issue.id)
                    await signalIssueEnumerators(issue, mountID: mount.id)
                case .deleteAnyway, .deleteDuplicate:
                    try await resolveDeleteIssue(issue, mount: mount, remote: remote)
                case .renameDuplicate:
                    guard let renameTo = request.renameTo else { continue }
                    try await resolveRenameIssue(issue, renameTo: renameTo, mount: mount, remote: remote)
                }
            } catch {
                // Keep the durable request pending; a later provider callback can retry it safely.
                continue
            }
        }
    }

    private func signalIssueEnumerators(_ issue: IssueRecord, mountID: UUID) async {
        guard let itemID = issue.itemID,
            let item = try? await stateStore.item(id: itemID, mountID: mountID)
        else {
            await signalEnumerators(parentIdentifier: .workingSet)
            return
        }
        let parentIdentifier =
            item.parentID.map {
                NSFileProviderItemIdentifier("item.\($0.uuidString.lowercased())")
            } ?? .rootContainer
        await signalEnumerators(parentIdentifier: parentIdentifier)
    }

    private func resolveDeleteIssue(
        _ issue: IssueRecord,
        mount: MountDefinition,
        remote: RemoteProfile
    ) async throws {
        guard let itemID = issue.itemID,
            let expectedObjectID = issue.remoteObjectID,
            !expectedObjectID.isEmpty,
            let stored = try await stateStore.item(id: itemID, mountID: mount.id),
            stored.remoteID == expectedObjectID
        else {
            throw BridgeFailure(
                kind: .conflict,
                message: "The exact remote object can no longer be identified safely.",
                retryable: false
            )
        }
        let fresh = try await client.stat(
            remote: remote,
            path: stored.remotePath,
            objectID: expectedObjectID
        )
        guard fresh.objectID == expectedObjectID else {
            throw BridgeFailure(
                kind: .conflict,
                message: "The exact remote object can no longer be identified safely.",
                retryable: false
            )
        }
        try await performOperation(
            operationID: issue.id,
            kind: .delete,
            itemID: stored.id
        ) {
            try await self.client.delete(
                operationID: issue.id,
                remote: remote,
                item: fresh
            )
        }
        let parentIdentifier =
            stored.parentID.map {
                NSFileProviderItemIdentifier("item.\($0.uuidString.lowercased())")
            } ?? .rootContainer
        _ = try await stateStore.deleteItem(itemID: stored.id, mountID: mount.id)
        _ = try await stateStore.resolveIssue(id: issue.id, at: .now)
        try await stateStore.clearIssueResolutionRequest(issueID: issue.id)
        await signalEnumerators(parentIdentifier: parentIdentifier)
    }

    private func resolveRenameIssue(
        _ issue: IssueRecord,
        renameTo: String,
        mount: MountDefinition,
        remote: RemoteProfile
    ) async throws {
        let trimmedName = renameTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
            trimmedName != ".",
            trimmedName != "..",
            !trimmedName.contains("/"),
            let itemID = issue.itemID,
            let expectedObjectID = issue.remoteObjectID,
            !expectedObjectID.isEmpty,
            let stored = try await stateStore.item(id: itemID, mountID: mount.id),
            stored.remoteID == expectedObjectID
        else {
            throw BridgeFailure(
                kind: .unsupported,
                message: "Choose a valid single-component filename for this exact duplicate.",
                retryable: false
            )
        }
        let fresh = try await client.stat(
            remote: remote,
            path: stored.remotePath,
            objectID: expectedObjectID
        )
        guard fresh.objectID == expectedObjectID else {
            throw BridgeFailure(
                kind: .conflict,
                message: "The exact remote object can no longer be identified safely.",
                retryable: false
            )
        }
        let parentPath: String
        if let parentID = stored.parentID,
            let parent = try await stateStore.item(id: parentID, mountID: mount.id)
        {
            parentPath = parent.remotePath
        } else {
            parentPath = mount.root
        }
        let destination = Self.joinRemotePath(parentPath, trimmedName)
        let moved = try await performOperation(
            operationID: issue.id,
            kind: .move,
            itemID: stored.id
        ) {
            try await self.client.move(
                operationID: issue.id,
                remote: remote,
                source: fresh,
                destinationPath: destination,
                expectedDestinationVersion: nil
            )
        }
        _ = try await stateStore.update(
            itemID: stored.id,
            mountID: mount.id,
            parentID: stored.parentID,
            remoteItem: moved
        )
        _ = try await stateStore.resolveIssue(id: issue.id, at: .now)
        try await stateStore.clearIssueResolutionRequest(issueID: issue.id)
        let parentIdentifier =
            stored.parentID.map {
                NSFileProviderItemIdentifier("item.\($0.uuidString.lowercased())")
            } ?? .rootContainer
        await signalEnumerators(parentIdentifier: parentIdentifier)
    }

    private static func joinRemotePath(_ parent: String, _ child: String) -> String {
        [parent.trimmingCharacters(in: CharacterSet(charactersIn: "/")), child]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    public func markAccessed(_ item: StoredItem, materialized: Bool = false) async throws {
        try await stateStore.markAccessed(itemID: item.id, mountID: item.mountID, at: .now)
        if materialized {
            try await stateStore.setMaterialized(true, itemID: item.id, mountID: item.mountID)
        }
    }
    public func replaceMaterializedDirectories(
        with identifiers: [NSFileProviderItemIdentifier]
    ) async throws {
        let (_, mount, _) = try await configuration()
        let current = try await stateStore.workingSet(
            mountID: mount.id,
            accessedAfter: .now.addingTimeInterval(-30 * 24 * 60 * 60)
        )
        for item in current where item.isDirectory && item.materialized {
            try await stateStore.setMaterialized(false, itemID: item.id, mountID: mount.id)
        }
        for identifier in identifiers {
            guard identifier.rawValue.hasPrefix("item."),
                let id = UUID(uuidString: String(identifier.rawValue.dropFirst("item.".count))),
                let item = try await stateStore.item(id: id, mountID: mount.id),
                item.isDirectory
            else { continue }
            try await stateStore.setMaterialized(true, itemID: id, mountID: mount.id)
            try await stateStore.markAccessed(itemID: id, mountID: mount.id, at: .now)
        }
    }
    public func setPinned(_ pinned: Bool, item: StoredItem) async throws {
        try await stateStore.setPinned(pinned, itemID: item.id, mountID: item.mountID)
    }

    public func updateStoredItem(
        _ item: StoredItem,
        parentID: UUID?,
        remoteItem: RemoteItem
    ) async throws -> StoredItem {
        try await stateStore.update(
            itemID: item.id,
            mountID: item.mountID,
            parentID: parentID,
            remoteItem: remoteItem
        )
    }

    @discardableResult
    public func deleteStoredItem(_ item: StoredItem) async throws -> [StoredItem] {
        try await stateStore.deleteItem(itemID: item.id, mountID: item.mountID)
    }

    public func operation(id: UUID) async throws -> OperationRecord? {
        try await stateStore.operation(id: id)
    }

    public func signalEnumerators(parentIdentifier: NSFileProviderItemIdentifier) async {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        try? await manager.signalEnumerator(for: parentIdentifier)
        try? await manager.signalEnumerator(for: .workingSet)
    }
    public func prepareOperation(
        id: UUID,
        kind: OperationKind,
        item: StoredItem,
        totalBytes: Int64 = 0
    ) async throws {
        let (_, mount, _) = try await configuration()
        try requireMutationAdmission(kind: kind, mount: mount)
        guard try await stateStore.operation(id: id) == nil else { return }
        try await stateStore.recordOperation(
            OperationRecord(
                id: id,
                mountID: item.mountID,
                itemID: item.id,
                kind: kind,
                outcome: .pending,
                totalBytes: totalBytes
            ))
    }

    public func fileProviderItem(identifier: NSFileProviderItemIdentifier) async throws -> MountliFileProviderItem {
        let (_, mount, remote) = try await configuration()
        let stored = try await storedItem(identifier: identifier)
        if let stored {
            try await stateStore.markAccessed(itemID: stored.id, mountID: mount.id, at: .now)
        }
        let state = try await stateStore.state(mountID: mount.id)?.status ?? .online
        let capabilities: BackendCapabilities?
        do {
            try requirePolicyAccess(for: mount)
            capabilities = try await effectiveCapabilities(remote: remote, mount: mount)
        } catch {
            capabilities = nil
        }
        return MountliFileProviderItem(
            stored: stored,
            mount: mount,
            status: state,
            backendCapabilities: capabilities
        )
    }
    nonisolated public func trackProgress(_ progress: Progress, operationID: UUID) {
        progressRegistry.register(progress, operationID: operationID)
    }

    public func performOperation<Value: Sendable>(
        operationID: UUID,
        kind: OperationKind,
        itemID: UUID? = nil,
        totalBytes: Int64 = 0,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        defer { progressRegistry.remove(operationID: operationID) }
        let (_, mount, _) = try await configuration()
        let leaseOwner = "\(operationOwner)-operation-\(UUID().uuidString.lowercased())"
        try requireNetworkAccess(for: mount)
        try requireMutationAdmission(kind: kind, mount: mount)

        while try await stateStore.acquireOperationLease(
            operationID: operationID,
            mountID: mount.id,
            owner: leaseOwner,
            ttl: 30
        ) == false {
            try Task.checkCancellation()
            try requireNetworkAccess(for: mount)
            try requireMutationAdmission(kind: kind, mount: mount)
            try await Task.sleep(for: .milliseconds(250))
        }
        let operationRenewal = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                let renewed = try? await stateStore.renewOperationLease(
                    operationID: operationID,
                    owner: leaseOwner,
                    ttl: 30
                )
                guard renewed == true else { return }
            }
        }
        let cancellationWatcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                guard (try? await stateStore.isOperationCancellationRequested(id: operationID)) == true else {
                    continue
                }
                await client.cancel(operationID: operationID)
                return
            }
        }

        var operationRecorded = false
        var transferLeaseAcquired = false
        var countedAsActive = false
        var transferRenewal: Task<Void, Never>?
        do {
            if try await stateStore.operation(id: operationID) == nil {
                try await stateStore.recordOperation(
                    OperationRecord(
                        id: operationID,
                        mountID: mount.id,
                        itemID: itemID,
                        kind: kind,
                        outcome: .running,
                        totalBytes: totalBytes
                    ))
            } else {
                try await stateStore.finishOperation(id: operationID, outcome: .running)
            }
            operationRecorded = true

            var state =
                try await stateStore.state(mountID: mount.id)
                ?? MountOperationalState(mountID: mount.id)
            state.pendingOperations = try await stateStore.pendingOperationCount(mountID: mount.id)
            state.status = .connecting
            try await stateStore.setState(state)

            while try await stateStore.acquireTransferLease(
                operationID: operationID,
                mountID: mount.id,
                owner: leaseOwner,
                limit: transferLimit
            ) == false {
                if try await stateStore.isOperationCancellationRequested(id: operationID) {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                try requireNetworkAccess(for: mount)
                try requireMutationAdmission(kind: kind, mount: mount)
                try await Task.sleep(for: .milliseconds(250))
            }
            transferLeaseAcquired = true
            try requireNetworkAccess(for: mount)
            try requireMutationAdmission(kind: kind, mount: mount)
            guard
                try await stateStore.renewOperationLease(
                    operationID: operationID,
                    owner: leaseOwner,
                    ttl: 30
                )
            else {
                throw BridgeFailure(
                    kind: .unreachable,
                    message: "The operation ownership lease expired; retrying is safe.",
                    retryable: true
                )
            }

            state =
                try await stateStore.state(mountID: mount.id)
                ?? MountOperationalState(mountID: mount.id)
            state.activeTransfers += 1
            state.status = .transferring
            try await stateStore.setState(state)
            countedAsActive = true
            transferRenewal = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    let renewed = try? await stateStore.renewTransferLease(
                        operationID: operationID,
                        owner: leaseOwner
                    )
                    guard renewed == true else { return }
                }
            }
            if try await stateStore.isOperationCancellationRequested(id: operationID) {
                throw CancellationError()
            }

            let value = try await operation()
            cancellationWatcher.cancel()
            transferRenewal?.cancel()
            operationRenewal.cancel()
            try await finishOperation(
                operationID,
                mountID: mount.id,
                outcome: .succeeded,
                diagnosticCode: nil,
                decrementActiveTransfer: true
            )
            try? await stateStore.releaseTransferLease(
                operationID: operationID,
                owner: leaseOwner
            )
            transferLeaseAcquired = false
            try await stateStore.releaseOperationLease(
                operationID: operationID,
                owner: leaseOwner
            )
            return value
        } catch is CancellationError {
            cancellationWatcher.cancel()
            transferRenewal?.cancel()
            if transferLeaseAcquired {
                try? await stateStore.releaseTransferLease(
                    operationID: operationID,
                    owner: leaseOwner
                )
            }
            operationRenewal.cancel()
            if operationRecorded {
                try await finishOperation(
                    operationID,
                    mountID: mount.id,
                    outcome: .cancelled,
                    diagnosticCode: "cancelled",
                    decrementActiveTransfer: countedAsActive
                )
            }
            try? await stateStore.releaseOperationLease(
                operationID: operationID,
                owner: leaseOwner
            )
            throw CancellationError()
        } catch {
            cancellationWatcher.cancel()
            transferRenewal?.cancel()
            if transferLeaseAcquired {
                try? await stateStore.releaseTransferLease(
                    operationID: operationID,
                    owner: leaseOwner
                )
            }
            operationRenewal.cancel()
            let bridge = error as? BridgeFailure
            let persistedCancellation =
                (try? await stateStore.isOperationCancellationRequested(id: operationID)) == true
            let cancellationRequested = bridge?.kind == .cancelled || persistedCancellation
            if operationRecorded {
                let outcome: OperationOutcome =
                    cancellationRequested
                    ? .cancelled
                    : (bridge?.retryable == true ? .retryableFailure : .failed)
                let code =
                    cancellationRequested
                    ? BridgeErrorKind.cancelled.rawValue
                    : (bridge?.kind.rawValue
                        ?? "\((error as NSError).domain):\((error as NSError).code)")
                try await finishOperation(
                    operationID,
                    mountID: mount.id,
                    outcome: outcome,
                    diagnosticCode: code,
                    decrementActiveTransfer: countedAsActive
                )
            }
            try? await stateStore.releaseOperationLease(
                operationID: operationID,
                owner: leaseOwner
            )
            if cancellationRequested {
                throw CancellationError()
            }
            throw error
        }
    }

    private func finishOperation(
        _ operationID: UUID,
        mountID: UUID,
        outcome: OperationOutcome,
        diagnosticCode: String?,
        decrementActiveTransfer: Bool
    ) async throws {
        try await stateStore.finishOperation(id: operationID, outcome: outcome, diagnosticCode: diagnosticCode)
        var state = try await stateStore.state(mountID: mountID) ?? MountOperationalState(mountID: mountID)
        state.pendingOperations = try await stateStore.pendingOperationCount(mountID: mountID)
        if decrementActiveTransfer {
            state.activeTransfers = max(0, state.activeTransfers - 1)
        }
        switch outcome {
        case .succeeded, .cancelled:
            state.status = state.activeTransfers > 0 ? .transferring : .online
        case .retryableFailure:
            state.status = .degraded
        case .failed:
            state.status = .error
        case .pending, .running:
            state.status = .connecting
        }
        try await stateStore.setState(state)
    }

    public func download(
        operationID: UUID,
        item: StoredItem,
        requestedVersion: NSFileProviderItemVersion?,
        range: Range<Int64>? = nil
    ) async throws -> URL {
        let (_, mount, remote) = try await configuration()
        try requireNetworkAccess(for: mount)
        if let requestedVersion, requestedVersion.contentVersion != item.contentVersion {
            try await recordVersionConflict(
                item: item,
                mountID: mount.id,
                operationKind: .download
            )
            throw BridgeFailure(
                kind: .conflict,
                message: "The requested version is no longer available.",
                retryable: false
            )
        }
        let before = try await client.stat(remote: remote, path: item.remotePath, objectID: item.remoteID)
        guard StoredItemVersion.contentVersion(for: before) == item.contentVersion else {
            try await recordVersionConflict(
                item: item,
                mountID: mount.id,
                operationKind: .download
            )
            throw BridgeFailure(
                kind: .conflict,
                message: "The requested version is no longer available.",
                retryable: false
            )
        }
        let destination = try stagingArea.destination(for: operationID)
        do {
            let result = try await performOperation(
                operationID: operationID,
                kind: .download,
                itemID: item.id,
                totalBytes: range.map { $0.upperBound - $0.lowerBound } ?? item.size
            ) {
                try await self.client.download(
                    operationID: operationID,
                    remote: remote,
                    path: item.remotePath,
                    objectID: item.remoteID,
                    destination: destination,
                    range: range
                )
            }
            let expectedBytes = range.map { $0.upperBound - $0.lowerBound } ?? item.size
            let expectedStageSize = range?.upperBound ?? item.size
            let stageSize =
                try destination.resourceValues(forKeys: [.fileSizeKey])
                .fileSize
                .map(Int64.init) ?? -1
            guard result.bytes == expectedBytes,
                stageSize == expectedStageSize,
                result.fingerprint == before.fingerprint
            else {
                throw BridgeFailure(kind: .internal, message: "The downloaded bytes failed validation.", retryable: true)
            }
            let after = try await client.stat(remote: remote, path: item.remotePath, objectID: item.remoteID)
            guard StoredItemVersion.contentVersion(for: before) == StoredItemVersion.contentVersion(for: after) else {
                try await recordVersionConflict(
                    item: item,
                    mountID: mount.id,
                    operationKind: .download
                )
                throw BridgeFailure(
                    kind: .conflict,
                    message: "The item changed while it was downloading.",
                    retryable: false
                )
            }
            try await markAccessed(item, materialized: true)
            try await resolveVersionConflicts(for: item.id)
            return destination
        } catch {
            stagingArea.remove(destination)
            throw error
        }
    }

    public func invalidate() async {
        guard !invalidated else { return }
        invalidated = true
        if watcherStarted {
            await client.stopChangeNotifications(watcherID: watcherID)
            watcherStarted = false
        }
        if let processRuntime {
            await processRuntime.unregisterChanges(watcherID: watcherID)
        }
        deactivateResources()
        let removeRuntimeResources: Bool
        if let processRuntime {
            removeRuntimeResources = await processRuntime.release()
        } else {
            await client.shutdown()
            removeRuntimeResources = true
        }
        if removeRuntimeResources {
            try? await resourceStore.removeAll()
        }
        try? stagingArea.cleanupStale(
            olderThan: .now.addingTimeInterval(-86_400),
            activeOperationIDs: (try? await stateStore.activeOperationIDs()) ?? []
        )
    }

    public var repository: SQLiteStore { stateStore }
    public var rclone: any RcloneClient { client }
}

private final class ProviderUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

final class ProviderProgressRegistry: @unchecked Sendable {
    private final class WeakProgress {
        weak var value: Progress?
        init(_ value: Progress) { self.value = value }
    }

    private let lock = NSLock()
    private var values: [UUID: WeakProgress] = [:]

    func register(_ progress: Progress, operationID: UUID) {
        lock.withLock { values[operationID] = WeakProgress(progress) }
    }

    func update(operationID: UUID, completed: Int64, total: Int64) {
        let progress = lock.withLock { values[operationID]?.value }
        guard let progress else { return }
        progress.totalUnitCount = total
        progress.completedUnitCount = completed
    }

    func remove(operationID: UUID) {
        _ = lock.withLock { values.removeValue(forKey: operationID) }
    }
}

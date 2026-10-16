import FileProvider
import Foundation
import MountliCore
import Observation
import Security
import UserNotifications

#if os(iOS)
    import BackgroundTasks
    import UIKit
#endif
#if os(macOS)
    import AppKit
    import ServiceManagement
#endif

enum ImportedRemoteCollisionPolicy {
    case cancel
    case replaceAll
}

@MainActor
@Observable
final class MountliAppModel {
    var snapshot = VaultSnapshot(revision: 0, document: VaultDocument())
    var catalog: [ProviderDescriptor] = []
    var domainIssues: [String] = []
    var recentOperations: [OperationRecord] = []
    var durableIssues: [IssueRecord] = []
    var cancellationRequestedIDs: Set<UUID> = []
    var managedPolicy = ManagedPolicy()
    var policyIssues: [MountliIssue] = []
    var vaultRecoveryCandidate: VaultSnapshot?
    var vaultResetRequired = false
    var operationalStates: [UUID: MountOperationalState] = [:]
    var isLoading = true
    var presentedError: String?
    var showingAddRemote = false
    var showingAddMount = false
    var showingConfigImport = false
    var requestedSection: String?
    var selectedRemoteID: UUID?
    var selectedMountID: UUID?
    var preservedDataURL: URL?
    var requestedOperationID: UUID?
    var requestedIssueID: UUID?

    @ObservationIgnored private var appLogger: MountliLogger?
    @ObservationIgnored private var vaultLogger: MountliLogger?
    @ObservationIgnored private var policyLogger: MountliLogger?
    private var vault: EncryptedVaultStore?
    private var stateStore: SQLiteStore?
    private var resourceStore: ResourceStore?
    private let rclone = GoRcloneClient()
    let configuration = GoConfigurationClient()
    private var activeConfigurationSessionID: String?
    @ObservationIgnored private lazy var oauth = OAuthCoordinator { [weak self] in
        Task { @MainActor in await self?.cancelActiveConfiguration() }
    }
    private let diagnostics = DiagnosticsExporter()
    private let domains = DomainRegistry()
    private var fullCatalog: [ProviderDescriptor] = []
    @ObservationIgnored private let notificationRouter = MountliNotificationRouter.shared
    private static let notificationCheckpointKey = "notifications.lastActivityScan.v1"

    var remotes: [RemoteProfile] { snapshot.document.remotes.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending } }
    var mounts: [MountDefinition] { snapshot.document.mounts.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending } }

    var overallStatus: MountStatus {
        StatusAggregator.aggregate(
            mounts.map { mount in
                operationalStates[mount.id] ?? MountOperationalState(mountID: mount.id)
            })
    }

    var unresolvedIssueCount: Int {
        let durableKeys = Set(
            durableIssues.compactMap { issue -> String? in
                guard let mountID = issue.mountID else { return nil }
                return "\(mountID.uuidString):\(issue.diagnosticCode)"
            })
        let fallback = operationalStates.values.reduce(0) { count, state in
            guard let code = state.lastErrorCode,
                !durableKeys.contains("\(state.mountID.uuidString):\(code)")
            else { return count }
            return count + 1
        }
        return durableIssues.count + fallback + policyIssues.count + domainIssues.count
    }

    func handleRecoveryURL(_ url: URL) {
        guard url.scheme?.lowercased() == "mountli" else { return }
        switch url.host?.lowercased() {
        case "activity":
            requestedOperationID = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:))
            requestedSection = "Activity"
        case "issue":
            requestedIssueID = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:))
            requestedSection = "Issues"
        case "recover", "action":
            requestedSection = "Issues"
        default:
            return
        }
    }

    func installInterfaceTestFixture() {
        let fixtureCatalog = """
            [
              {"name":"sftp","description":"SFTP","aliases":["ssh"],"options":[],"testOnly":false,"overlay":false},
              {"name":"crypt","description":"Crypt","aliases":["encrypted"],"options":[],"testOnly":false,"overlay":true}
            ]
            """
        catalog =
            (try? JSONDecoder().decode([ProviderDescriptor].self, from: Data(fixtureCatalog.utf8)))
            ?? []
        fullCatalog = catalog
        let remote = RemoteProfile.make(displayName: "Fixture Storage", backendType: "sftp")
        snapshot = VaultSnapshot(revision: 1, document: VaultDocument(remotes: [remote]))
        isLoading = false
    }

    func bootstrap() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let activityScanStarted = Date()
            oauth.install()
            let root = try applicationSupportRoot()
            let accessGroup =
                (Bundle.main.object(forInfoDictionaryKey: "MOUNTLIKeychainAccessGroup") as? String)
                ?? "$(AppIdentifierPrefix)ch.benavo.mountli.shared"
            let vault = EncryptedVaultStore(directory: root, keyProvider: KeychainKeyProvider(accessGroup: accessGroup))
            let stateStore = try await SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
            _ = try await stateStore.recoverInterruptedOperations()
            let logKeyProvider = KeychainKeyProvider(
                service: "ch.benavo.mountli.logging",
                account: "path-tokenizer",
                accessGroup: accessGroup
            )
            let logKeyData = try MountliLogging.installLocalKey(provider: logKeyProvider)
            let tokenizer = PathTokenizer(keyData: logKeyData)
            let sink: MountliLogSink = { category, level, message, createdAt in
                try? await stateStore.recordDiagnosticLog(
                    category: category,
                    level: level,
                    message: message,
                    createdAt: createdAt
                )
            }
            appLogger = MountliLogger(category: .app, tokenizer: tokenizer, sink: sink)
            vaultLogger = MountliLogger(category: .vault, tokenizer: tokenizer, sink: sink)
            policyLogger = MountliLogger(category: .policy, tokenizer: tokenizer, sink: sink)
            appLogger?.info("application bootstrap started")
            self.vault = vault
            resourceStore = ResourceStore(appGroupRoot: root)
            notificationRouter.install { [weak self] url in
                Task { @MainActor in self?.handleRecoveryURL(url) }
            }
            self.stateStore = stateStore
            do {
                snapshot = try await vault.load()
            } catch VaultStoreError.notFound {
                snapshot = VaultSnapshot(revision: 0, document: VaultDocument())
            } catch VaultStoreError.integrityFailure {
                vaultRecoveryCandidate = try? await vault.backupCandidate()
                throw VaultStoreError.integrityFailure
            } catch let VaultStoreError.keychain(status) where status == errSecItemNotFound {
                vaultResetRequired = true
                throw VaultStoreError.keychain(status)
            }
            let configuredMountIDs = Set(snapshot.document.mounts.map(\.id))
            recentOperations = try await stateStore.recentOperations(limit: 500).filter {
                configuredMountIDs.contains($0.mountID)
            }
            durableIssues = try await stateStore.openIssues(mountID: nil, limit: 500).filter {
                $0.mountID.map(configuredMountIDs.contains) ?? true
            }
            if let checkpoint = UserDefaults.standard.object(
                forKey: Self.notificationCheckpointKey
            ) as? Date {
                await scheduleNotifications(
                    operations: recentOperations.filter { ($0.completedAt ?? .distantPast) > checkpoint },
                    issues: durableIssues.filter { $0.createdAt > checkpoint }
                )
            }
            UserDefaults.standard.set(activityScanStarted, forKey: Self.notificationCheckpointKey)
            await rclone.configureVaultMutations { [weak self, vault] mutation in
                let updated = try await vault.applyRcloneMutation(mutation)
                await MainActor.run { self?.snapshot = updated }
            }
            try await loadSnapshotIntoRclone()
            for mount in snapshot.document.mounts {
                operationalStates[mount.id] =
                    try await stateStore.state(mountID: mount.id)
                    ?? MountOperationalState(mountID: mount.id)
            }
            fullCatalog = try await rclone.providerCatalog().filter { !$0.testOnly }
            refreshManagedPolicy()
            domainIssues = try await domains.reconcile(mounts: snapshot.document.mounts) { _ in false }
            #if os(iOS)
                scheduleBackgroundRefresh()
            #endif
            appLogger?.info("application bootstrap completed")
        } catch {
            vaultLogger?.error(code: "BOOTSTRAP_FAILED", message: String(describing: type(of: error)), path: nil)
            presentedError = error.localizedDescription
        }
    }
    func restoreVaultBackup() async throws {
        guard let vault else { throw VaultStoreError.notFound }
        snapshot = try await vault.restoreBackup()
        vaultRecoveryCandidate = nil
        presentedError = nil
        await bootstrap()
    }

    func restoreDomain(_ mount: MountDefinition) async throws {
        try await domains.add(mount)
        domainIssues.removeAll { $0 == "missing:\(mount.domainIdentifier)" }
    }

    func removeOrphanDomain(_ identifier: String) async throws {
        try await domains.removeOrphan(identifier: identifier)
        domainIssues.removeAll { $0 == "orphan:\(identifier)" }
    }

    func resetVaultAfterKeyLoss() async throws {
        guard vaultResetRequired, let vault else {
            throw VaultStoreError.mutationRejected("Vault reset is not currently available")
        }
        try await domains.removeMountliDomainsAfterExplicitVaultReset()
        try await vault.reset()
        try? await resourceStore?.removeAll()
        snapshot = try await vault.save(VaultDocument(), expectedRevision: 0)
        vaultResetRequired = false
        vaultRecoveryCandidate = nil
        presentedError = nil
        try await loadSnapshotIntoRclone()
    }

    func setShowMenuBarExtra(_ enabled: Bool) async throws {
        let base = snapshot
        var document = base.document
        document.settings.showMenuBarExtra = enabled
        try await commit(document, basedOn: base)
    }

    func setLaunchAtLogin(_ enabled: Bool) async throws {
        #if os(macOS)
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try await SMAppService.mainApp.unregister()
            }
        #endif
        let base = snapshot
        var document = base.document
        document.settings.launchAtLogin = enabled
        try await commit(document, basedOn: base)
    }

    func setMaximumConcurrentTransfers(_ value: Int) async throws {
        let base = snapshot
        var document = base.document
        #if os(macOS)
            document.settings.maximumConcurrentTransfersMacOS = min(max(value, 1), 8)
        #else
            document.settings.maximumConcurrentTransfersIOS = min(max(value, 1), 4)
        #endif
        try await commit(document, basedOn: base)
    }

    func setDefaultNetworkPolicy(_ policy: NetworkPolicy) async throws {
        let base = snapshot
        var document = base.document
        document.settings.defaultNetworkPolicy = managedPolicy.allowCellular ? policy : .wifiOnly
        try await commit(document, basedOn: base)
    }

    func setNotificationSettings(_ notifications: NotificationSettings) async throws {
        let base = snapshot
        var document = base.document
        document.settings.notifications = notifications
        try await commit(document, basedOn: base)
    }

    func setIncludeFilenamesInDiagnostics(_ enabled: Bool) async throws {
        let base = snapshot
        var document = base.document
        document.settings.includeFilenamesInDiagnostics = enabled
        try await commit(document, basedOn: base)
    }

    var effectiveMaximumConcurrentTransfers: Int {
        if let managed = managedPolicy.maximumConcurrentTransfers { return managed }
        #if os(macOS)
            return snapshot.document.settings.maximumConcurrentTransfersMacOS
        #else
            return snapshot.document.settings.maximumConcurrentTransfersIOS
        #endif
    }

    func trackConfigurationSession(_ sessionID: String?) {
        activeConfigurationSessionID = sessionID
    }

    func cancelActiveConfiguration() async {
        oauth.cancel()
        guard let sessionID = activeConfigurationSessionID else { return }
        activeConfigurationSessionID = nil
        await configuration.cancelConfiguration(sessionID: sessionID)
    }

    func refreshActivity(presentingErrors: Bool = true) async {
        guard let stateStore else { return }
        let activityScanStarted = Date()
        do {
            let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            let checkpoint =
                UserDefaults.standard.object(
                    forKey: Self.notificationCheckpointKey
                ) as? Date ?? activityScanStarted
            let mountIDs = Set(mounts.map(\.id))
            recentOperations = try await stateStore.recentOperations(limit: 500).filter {
                mountIDs.contains($0.mountID) && ($0.completedAt.map { $0 >= cutoff } ?? true)
            }
            let activeIDs = Set(
                recentOperations.filter {
                    $0.outcome == .pending || $0.outcome == .running || $0.outcome == .retryableFailure
                }.map(\.id))
            cancellationRequestedIDs.formIntersection(activeIDs)
            durableIssues = try await stateStore.openIssues(mountID: nil, limit: 500).filter {
                $0.mountID.map(mountIDs.contains) ?? true
            }
            for mount in mounts {
                operationalStates[mount.id] =
                    try await stateStore.state(mountID: mount.id)
                    ?? MountOperationalState(mountID: mount.id)
            }
            await scheduleNotifications(
                operations: recentOperations.filter { ($0.completedAt ?? .distantPast) > checkpoint },
                issues: durableIssues.filter { $0.createdAt > checkpoint }
            )
            UserDefaults.standard.set(activityScanStarted, forKey: Self.notificationCheckpointKey)
        } catch {
            appLogger?.error(code: "ACTIVITY_REFRESH_FAILED", message: String(describing: type(of: error)), path: nil)
            if presentingErrors { presentedError = error.localizedDescription }
        }
    }

    func monitorActivity() async {
        while !Task.isCancelled {
            let isActive = recentOperations.contains {
                $0.outcome == .pending || $0.outcome == .running
            }
            do {
                try await Task.sleep(for: .seconds(isActive ? 2 : 15))
            } catch {
                return
            }
            await refreshActivity(presentingErrors: false)
        }
    }

    func clearActivityHistory() async throws {
        guard let stateStore else {
            throw DomainRegistryError.unavailable("Mountli is still starting up. Try again in a moment.")
        }
        _ = try await stateStore.clearCompletedOperationHistory()
        requestedOperationID = nil
        await refreshActivity()
    }

    private func scheduleNotifications(
        operations: [OperationRecord],
        issues: [IssueRecord]
    ) async {
        let settings = snapshot.document.settings.notifications
        let center = UNUserNotificationCenter.current()
        if settings.actionRequired {
            for issue in issues {
                let mount = issue.mountID.flatMap { id in mounts.first { $0.id == id } }
                let content = UNMutableNotificationContent()
                content.title = mount.map { "\($0.displayName) needs attention" } ?? "Mountli needs attention"
                content.body = issue.message
                content.sound = .default
                content.threadIdentifier = issue.mountID.map { "mount-\($0.uuidString.lowercased())" } ?? "mountli"
                content.targetContentIdentifier = issue.id.uuidString.lowercased()
                content.userInfo = ["mountliURL": "mountli://issue/\(issue.id.uuidString.lowercased())"]
                try? await center.add(
                    UNNotificationRequest(
                        identifier: "issue-\(issue.id.uuidString.lowercased())",
                        content: content,
                        trigger: nil
                    ))
            }
        }
        if settings.transferCompleted {
            for operation in operations
            where operation.outcome == .succeeded
                && (operation.kind == .download || operation.kind == .upload)
            {
                guard let mount = mounts.first(where: { $0.id == operation.mountID }) else { continue }
                let content = UNMutableNotificationContent()
                content.title = "\(mount.displayName) transfer completed"
                content.body = operation.kind == .upload ? "Upload completed." : "Download completed."
                content.sound = .default
                content.threadIdentifier = "mount-\(mount.id.uuidString.lowercased())"
                content.targetContentIdentifier = operation.id.uuidString.lowercased()
                content.userInfo = ["mountliURL": "mountli://activity/\(operation.id.uuidString.lowercased())"]
                try? await center.add(
                    UNNotificationRequest(
                        identifier: "operation-\(operation.id.uuidString.lowercased())",
                        content: content,
                        trigger: nil
                    ))
            }
        }
    }

    #if os(iOS)
        func performBackgroundRefresh() async {
            defer { scheduleBackgroundRefresh() }
            guard ProcessInfo.processInfo.thermalState != .critical,
                !ProcessInfo.processInfo.isLowPowerModeEnabled
            else { return }
            if stateStore == nil {
                await bootstrap()
            } else {
                await refreshActivity(presentingErrors: false)
                domainIssues = (try? await domains.reconcile(mounts: mounts) { _ in false }) ?? domainIssues
            }
        }

        private func scheduleBackgroundRefresh() {
            let request = BGAppRefreshTaskRequest(identifier: "ch.benavo.mountli.refresh")
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                // Expected on Simulator and when Background App Refresh is off; the app still
                // refreshes whenever it is opened, so this is not something the user must fix.
                appLogger?.info("background refresh unavailable: \(String(describing: type(of: error)))")
            }
        }
    #endif

    func saveRemote(
        displayName: String,
        backendType: String,
        options: [String: String],
        resources: [ManagedResourceReference] = [],
        replacing id: UUID? = nil
    ) async throws {
        let base = snapshot
        refreshManagedPolicy()
        let existingForPolicy = id.flatMap { remoteID in
            base.document.remotes.first { $0.id == remoteID }
        }
        let candidateID = existingForPolicy?.id ?? UUID()
        let secureOptions = try RemoteIdentityPolicy.secureOptions(
            backendType: backendType,
            options: options
        )
        let candidate = RemoteProfile(
            id: candidateID,
            engineName: existingForPolicy?.engineName ?? EngineName.make(displayName: displayName, id: candidateID),
            displayName: displayName,
            backendType: backendType,
            options: secureOptions,
            resources: resources,
            createdAt: existingForPolicy?.createdAt ?? .now,
            updatedAt: .now
        )
        try managedPolicy.requireRemoteAccess(candidate)
        var document = base.document
        let runtimeOptions: [String: String]
        if let resourceStore {
            runtimeOptions = try await resourceStore.materializeOptions(secureOptions, resources: resources)
        } else {
            runtimeOptions = secureOptions
        }
        if let id, let index = document.remotes.firstIndex(where: { $0.id == id }) {
            let existing = document.remotes[index]
            let updated = RemoteProfile(
                id: existing.id,
                engineName: existing.engineName,
                displayName: displayName,
                backendType: backendType,
                options: secureOptions,
                resources: resources,
                createdAt: existing.createdAt,
                updatedAt: .now
            )
            document.remotes[index] = updated
            let graph = try RemoteDependencyGraph(remotes: document.remotes)
            var affectedNames: Set<String> = [existing.engineName]
            var changed = true
            while changed {
                changed = false
                for (name, dependencies) in graph.dependencies
                where !affectedNames.contains(name) && !dependencies.isDisjoint(with: affectedNames) {
                    affectedNames.insert(name)
                    changed = true
                }
            }
            let affectedRemoteIDs = Set(
                document.remotes.filter { affectedNames.contains($0.engineName) }.map(\.id)
            )
            let affectedMounts = document.mounts.filter { affectedRemoteIDs.contains($0.remoteID) }
            if let stateStore {
                for attempt in 0..<60 {
                    var pending = 0
                    for mount in affectedMounts {
                        pending += try await stateStore.pendingOperationCount(mountID: mount.id)
                    }
                    if pending == 0 { break }
                    if attempt == 59 { throw DomainRegistryError.dirtyOperations(pending) }
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
            var validationRoots = Set(
                affectedMounts.filter { $0.remoteID == id }.map(\.root)
            )
            for dependent in document.remotes where graph.dependencies[dependent.engineName]?.contains(existing.engineName) == true {
                for value in dependent.options.values where value.hasPrefix("\(existing.engineName):") {
                    validationRoots.insert(String(value.dropFirst(existing.engineName.count + 1)))
                }
            }
            var scopedURLs: [URL] = []
            if backendType == "local", let resourceStore {
                for reference in resources where reference.kind == .securityScopedDirectory {
                    let url = try await resourceStore.resolve(reference)
                    if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
                }
            }
            defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
            if validationRoots.isEmpty, backendType != "local" {
                validationRoots.insert("")
            }
            for root in validationRoots {
                try await rclone.validateConfiguration(backendType: backendType, options: runtimeOptions, root: root)
            }
        } else {
            if backendType != "local" {
                try await rclone.validateConfiguration(
                    backendType: backendType,
                    options: runtimeOptions,
                    root: ""
                )
            }
            document.remotes.append(candidate)
            _ = try RemoteDependencyGraph(remotes: document.remotes)
        }
        try await commit(document, basedOn: base)
    }

    func importConfigurationResource(
        from url: URL,
        optionName: String,
        requirementKind: String? = nil
    ) async throws -> (reference: ManagedResourceReference, path: String) {
        guard let resourceStore else { throw VaultStoreError.notFound }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let kind = Self.resourceKind(optionName: optionName, bridgeKind: requirementKind)
        let reference: ManagedResourceReference
        if kind == .securityScopedDirectory {
            try await Self.requireNonFileProviderDirectory(url)
            reference = try await resourceStore.importDirectoryBookmark(
                from: url,
                displayName: url.lastPathComponent,
                fileProviderStorageURLs: []
            )
        } else {
            reference = try await resourceStore.importFile(
                from: url,
                kind: kind,
                displayName: url.lastPathComponent
            )
        }
        return (reference, await resourceStore.optionValue(for: reference))
    }

    func resourceRequirementKind(optionName: String, backendType: String) -> String? {
        let key = optionName.lowercased()
        if backendType == "cache", ["db_path", "chunk_path", "tmp_upload_path"].contains(key) {
            return "managedDirectory"
        }
        return Self.fileBackedOptionKinds[key]
    }

    func isFileBackedOption(_ option: ProviderOption, backendType: String) -> Bool {
        resourceRequirementKind(optionName: option.name, backendType: backendType) != nil
    }

    private static let fileBackedOptionKinds: [String: String] = [
        "key_file": "sshPrivateKey",
        "pubkey_file": "sshPublicKey",
        "known_hosts_file": "knownHosts",
        "client_certificate_path": "clientCertificate",
        "client_cert": "clientCertificate",
        "client_key": "clientPrivateKey",
        "ca_cert": "certificateAuthority",
        "service_account_file": "configurationFile",
        "service_principal_file": "configurationFile",
        "box_config_file": "configurationFile",
        "config_file": "configurationFile",
        "shared_credentials_file": "configurationFile",
        "sse_customer_key_file": "configurationFile",
        "kerberos_ccache": "credentialCache",
    ]

    private static func resourceKind(
        optionName: String,
        bridgeKind: String?
    ) -> ManagedResourceReference.Kind {
        let key = optionName.lowercased()
        switch bridgeKind {
        case "managedDirectory": return .securityScopedDirectory
        case "sshPrivateKey": return .sshPrivateKey
        case "sshPublicKey": return .sshPublicKey
        case "knownHosts": return .knownHosts
        case "clientCertificate": return .clientCertificate
        case "clientPrivateKey": return .clientPrivateKey
        case "certificateAuthority": return .customCA
        case "credentialCache": return .credentialCache
        case "configurationFile":
            if key.contains("service_account") || key.contains("service_principal") || key == "box_config_file" {
                return .serviceAccount
            }
            return .configurationFile
        default:
            if key.contains("known_host") { return .knownHosts }
            if key.contains("service_account") || key.contains("credential") { return .serviceAccount }
            if key.contains("ca_") || key.contains("cacert") { return .customCA }
            if key.contains("client_cert") || key.contains("certificate") { return .clientCertificate }
            if key.contains("public_key") { return .sshPublicKey }
            if key.contains("private_key") || key == "key_file" || key.contains("ssh_key") { return .sshPrivateKey }
            if key.contains("token") || key.contains("cache") { return .credentialCache }
            if key.contains("config") { return .configurationFile }
            return .backendData
        }
    }

    func discardConfigurationResources(_ references: [ManagedResourceReference]) async {
        guard let resourceStore else { return }
        for reference in references {
            try? await resourceStore.remove(reference)
        }
    }

    func importConfig(from url: URL, password: String?) async throws -> ConfigImportResult {
        refreshManagedPolicy()
        guard managedPolicy.allowConfigImport else {
            throw ManagedPolicyRestriction.configImportDisabled
        }
        let imported = try await configuration.importConfig(url: url, password: password)
        refreshManagedPolicy()
        guard managedPolicy.allowConfigImport else {
            throw ManagedPolicyRestriction.configImportDisabled
        }
        return imported
    }

    func importedCollisions(_ imported: ConfigImportResult) -> [String] {
        let current = Set(snapshot.document.remotes.map(\.engineName))
        return Set(imported.sections.map(\.engineName)).intersection(current).sorted()
    }

    func addImportedRemotes(
        _ imported: ConfigImportResult,
        resourcesByEngineName: [String: [ManagedResourceReference]] = [:],
        collisionPolicy: ImportedRemoteCollisionPolicy = .cancel
    ) async throws {
        let base = snapshot
        refreshManagedPolicy()
        guard managedPolicy.allowConfigImport else {
            throw ManagedPolicyRestriction.configImportDisabled
        }
        let names = imported.sections.map(\.engineName)
        guard Set(names).count == names.count else {
            throw NSError(
                domain: "ch.benavo.mountli.import",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The configuration contains duplicate section names."]
            )
        }
        guard names.allSatisfy(Self.isValidImportedEngineName) else {
            throw NSError(
                domain: "ch.benavo.mountli.import",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "One or more rclone section names are invalid."]
            )
        }
        let collisions = importedCollisions(imported)
        guard collisions.isEmpty || collisionPolicy == .replaceAll else {
            throw NSError(
                domain: "ch.benavo.mountli.import",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Import cancelled because section names already exist."]
            )
        }
        var document = base.document
        var replacedResources: [ManagedResourceReference] = []
        if collisionPolicy == .replaceAll {
            let collisionSet = Set(collisions)
            let currentGraph = try RemoteDependencyGraph(remotes: document.remotes)
            var affectedNames = collisionSet
            var foundDependent = true
            while foundDependent {
                foundDependent = false
                for (name, dependencies) in currentGraph.dependencies
                where !affectedNames.contains(name) && !dependencies.isDisjoint(with: affectedNames) {
                    affectedNames.insert(name)
                    foundDependent = true
                }
            }
            let affectedIDs = Set(
                document.remotes.filter { affectedNames.contains($0.engineName) }.map(\.id)
            )
            guard document.mounts.allSatisfy({ !affectedIDs.contains($0.remoteID) }) else {
                throw NSError(
                    domain: "ch.benavo.mountli.import",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Remove mounts that use colliding sections or their overlays before replacing those sections."]
                )
            }
            replacedResources = document.remotes
                .filter { collisionSet.contains($0.engineName) }
                .flatMap(\.resources)
            document.remotes.removeAll { collisionSet.contains($0.engineName) }
        }
        for section in imported.sections {
            let secureOptions = try RemoteIdentityPolicy.secureOptions(
                backendType: section.backendType,
                options: section.options
            )
            let profile = RemoteProfile(
                engineName: section.engineName,
                displayName: section.engineName,
                backendType: section.backendType,
                options: secureOptions,
                resources: resourcesByEngineName[section.engineName] ?? []
            )
            try managedPolicy.requireRemoteAccess(profile)
            document.remotes.append(profile)
        }
        let graph = try RemoteDependencyGraph(remotes: document.remotes)
        var validationNames = Set(names)
        var addedDependency = true
        while addedDependency {
            addedDependency = false
            for name in Array(validationNames) {
                for dependency in graph.dependencies[name] ?? [] where validationNames.insert(dependency).inserted {
                    addedDependency = true
                }
            }
        }
        var addedDependent = true
        while addedDependent {
            addedDependent = false
            for (name, dependencies) in graph.dependencies
            where !validationNames.contains(name) && !dependencies.isDisjoint(with: validationNames) {
                validationNames.insert(name)
                addedDependent = true
            }
        }
        let validationOrder = try graph.topologicalOrder().filter { validationNames.contains($0) }
        let original = base
        do {
            try await validateDraft(document, order: validationOrder)
            refreshManagedPolicy()
            guard managedPolicy.allowConfigImport else {
                throw ManagedPolicyRestriction.configImportDisabled
            }
            for name in validationNames {
                if let remote = document.remotes.first(where: { $0.engineName == name }) {
                    try managedPolicy.requireRemoteAccess(remote)
                }
            }
            try await commit(document, basedOn: base)
            await discardConfigurationResources(replacedResources)
        } catch {
            if let vault, let latest = try? await vault.load() {
                snapshot = latest
                try? await reloadRclone(latest)
            } else {
                try? await reloadRclone(original)
            }
            throw error
        }
    }

    private static func isValidImportedEngineName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains(":")
            && !name.contains("[")
            && !name.contains("]")
            && !name.contains("\n")
            && !name.contains("\r")
    }

    private func validateDraft(_ document: VaultDocument, order: [String]) async throws {
        let draft = VaultSnapshot(revision: snapshot.revision &+ 1, document: document)
        try await reloadRclone(draft)
        let byName = Dictionary(uniqueKeysWithValues: document.remotes.map { ($0.engineName, $0) })
        for name in order {
            guard let remote = byName[name] else { continue }
            try await rclone.validate(remote: remote, root: "")
        }
    }

    private func reloadRclone(_ value: VaultSnapshot) async throws {
        if let resourceStore {
            try await rclone.reloadVault(resourceStore.materialize(value))
        } else {
            try await rclone.reloadVault(value)
        }
    }

    func deleteRemote(_ remote: RemoteProfile) async throws {
        let base = snapshot
        var document = base.document
        let graph = try RemoteDependencyGraph(remotes: document.remotes)
        try graph.assertCanDelete(remote.engineName)
        let mounted = document.mounts.filter { $0.remoteID == remote.id }.map(\.displayName)
        guard mounted.isEmpty else {
            throw DependencyGraphError.remoteInUse(remote: remote.engineName, dependents: mounted)
        }
        document.remotes.removeAll { $0.id == remote.id }
        try await commit(document, basedOn: base)
        await discardConfigurationResources(remote.resources)
    }

    func addMount(
        remoteID: UUID,
        name: String,
        root: String,
        readOnly: Bool,
        localDirectory: URL? = nil
    ) async throws {
        let name = try validatedMountName(name, excluding: nil)
        let base = snapshot
        refreshManagedPolicy()
        var document = base.document
        guard let remoteIndex = document.remotes.firstIndex(where: { $0.id == remoteID }) else {
            throw NSError(domain: "ch.benavo.mountli", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected remote no longer exists."])
        }
        var remote = document.remotes[remoteIndex]
        try managedPolicy.requireRemoteAccess(remote)
        var mountRoot = root
        var validationRoot = root
        var scopedURL: URL?
        var importedResource: ManagedResourceReference?
        if remote.backendType == "local" {
            guard let localDirectory, let resourceStore else {
                throw ResourceStoreError.invalidSelection("Choose a local folder before adding this mount.")
            }
            try await Self.requireNonFileProviderDirectory(localDirectory)
            let reference = try await resourceStore.importDirectoryBookmark(
                from: localDirectory,
                displayName: localDirectory.lastPathComponent,
                fileProviderStorageURLs: []
            )
            importedResource = reference
            remote.resources.append(reference)
            document.remotes[remoteIndex] = remote
            validationRoot = localDirectory.standardizedFileURL.path
            mountRoot = await resourceStore.optionValue(for: reference)
            if localDirectory.startAccessingSecurityScopedResource() {
                scopedURL = localDirectory
            }
        }
        defer { scopedURL?.stopAccessingSecurityScopedResource() }
        do {
            guard let stateStore else {
                throw DomainRegistryError.unavailable("Mountli is still starting up. Try again in a moment.")
            }
            refreshManagedPolicy()
            try managedPolicy.requireRemoteAccess(remote)
            try await rclone.validate(remote: remote, root: validationRoot)
            let mount = MountDefinition(
                remoteID: remoteID,
                root: mountRoot,
                displayName: name,
                readOnly: readOnly || managedPolicy.forceReadOnly,
                networkPolicy: base.document.settings.defaultNetworkPolicy,
                pollingPolicy: .automatic,
                isEnabled: true
            )
            document.mounts.append(mount)
            try await commit(document, basedOn: base)
            let state = MountOperationalState(mountID: mount.id, status: .connecting)
            do {
                try await domains.add(mount)
                try await stateStore.setState(state)
                operationalStates[mount.id] = state
            } catch {
                _ = try? await domains.remove(
                    mount,
                    repository: stateStore,
                    preserveDirtyUserData: false
                )
                let rollbackBase = snapshot
                var rollback = rollbackBase.document
                rollback.mounts.removeAll { $0.id == mount.id }
                if let importedResource,
                    let index = rollback.remotes.firstIndex(where: { $0.id == remoteID })
                {
                    rollback.remotes[index].resources.removeAll { $0.id == importedResource.id }
                }
                try? await commit(rollback, basedOn: rollbackBase)
                throw error
            }
        } catch {
            if let importedResource {
                try? await resourceStore?.remove(importedResource)
            }
            throw error
        }
    }

    @discardableResult
    func removeMount(_ mount: MountDefinition, preserveDirtyData: Bool = true) async throws -> URL? {
        guard let stateStore else {
            throw DomainRegistryError.unavailable("Mountli is still starting up. Try again in a moment.")
        }
        let preserved = try await domains.remove(
            mount,
            repository: stateStore,
            preserveDirtyUserData: preserveDirtyData
        )
        let base = snapshot
        var document = base.document
        document.mounts.removeAll { $0.id == mount.id }
        let previousState = operationalStates.removeValue(forKey: mount.id)
        do {
            try await commit(document, basedOn: base)
        } catch {
            try? await domains.add(mount)
            if let previousState { operationalStates[mount.id] = previousState }
            throw error
        }
        preservedDataURL = preserved
        return preserved
    }

    func reveal(_ mount: MountDefinition) async throws {
        let url = try await domains.userVisibleRoot(for: mount)
        #if os(macOS)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        #else
            guard await UIApplication.shared.open(url) else {
                throw DomainRegistryError.unavailable("Files could not open this location.")
            }
        #endif
    }

    func refresh(_ mount: MountDefinition) async throws {
        try await domains.signalWorkingSet(for: mount)
    }

    func probeMount(remoteID: UUID, root: String) async throws -> BackendCapabilities {
        guard let remote = snapshot.document.remotes.first(where: { $0.id == remoteID }) else {
            throw VaultStoreError.notFound
        }
        refreshManagedPolicy()
        try managedPolicy.requireRemoteAccess(remote)
        try await rclone.validate(remote: remote, root: root)
        return try await rclone.capabilities(remote: remote, root: root)
    }

    func quota(remoteID: UUID, root: String) async throws -> QuotaUsage {
        guard let remote = snapshot.document.remotes.first(where: { $0.id == remoteID }) else {
            throw VaultStoreError.notFound
        }
        refreshManagedPolicy()
        try managedPolicy.requireRemoteAccess(remote)
        return try await rclone.about(remote: remote, root: root)
    }

    func listFolders(remoteID: UUID, directory: String) async throws -> [RemoteItem] {
        guard let remote = snapshot.document.remotes.first(where: { $0.id == remoteID }) else {
            throw VaultStoreError.notFound
        }
        refreshManagedPolicy()
        try managedPolicy.requireRemoteAccess(remote)
        var result: [RemoteItem] = []
        var token: String?
        var seenTokens: Set<String> = []
        repeat {
            let page = try await rclone.list(
                remote: remote,
                directory: directory,
                pageToken: token,
                pageSize: 500
            )
            result.append(contentsOf: page.items.filter(\.isDirectory))
            token = page.nextPageToken
            if let token, !seenTokens.insert(token).inserted { break }
        } while token != nil
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func testConnection(_ remote: RemoteProfile) async throws {
        refreshManagedPolicy()
        try managedPolicy.requireRemoteAccess(remote)
        let roots = mounts.filter { $0.remoteID == remote.id }.map(\.root)
        if roots.isEmpty {
            try await rclone.validate(remote: remote, root: "")
        } else {
            for root in Set(roots) { try await rclone.validate(remote: remote, root: root) }
        }
    }

    func reconnect(_ remote: RemoteProfile) async throws {
        try await testConnection(remote)
        for mount in mounts where mount.remoteID == remote.id {
            var state = operationalStates[mount.id] ?? MountOperationalState(mountID: mount.id)
            state.isAuthenticated = true
            state.isReachable = true
            state.lastErrorCode = nil
            state.status = state.isPaused ? .paused : .connecting
            try await stateStore?.setState(state)
            operationalStates[mount.id] = state
            try await domains.signalWorkingSet(for: mount)
        }
    }

    func setPaused(_ paused: Bool, mount: MountDefinition) async throws {
        var state = operationalStates[mount.id] ?? MountOperationalState(mountID: mount.id)
        state.isPaused = paused
        state.status = paused ? .paused : .connecting
        try await stateStore?.setState(state)
        operationalStates[mount.id] = state
        if !paused { try await domains.signalWorkingSet(for: mount) }
    }

    func setAllPaused(_ paused: Bool) async throws {
        for mount in mounts { try await setPaused(paused, mount: mount) }
    }

    func refreshAll() async throws {
        for mount in mounts { try await domains.signalWorkingSet(for: mount) }
    }

    func renameMount(_ mount: MountDefinition, to displayName: String) async throws {
        let trimmed = try validatedMountName(displayName, excluding: mount.id)
        let base = snapshot
        var document = base.document
        guard let index = document.mounts.firstIndex(where: { $0.id == mount.id }) else {
            throw VaultStoreError.notFound
        }
        document.mounts[index].displayName = trimmed
        try await commit(document, basedOn: base)
        // Re-adding a domain with an existing identifier updates the name Finder and Files show.
        try await domains.add(document.mounts[index])
    }

    private func validatedMountName(_ proposed: String, excluding mountID: UUID?) throws -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DomainRegistryError.unavailable("Enter a name for this mount.")
        }
        guard !mounts.contains(where: { $0.id != mountID && $0.displayName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw DomainRegistryError.unavailable("Another mount already uses the name “\(trimmed)”.")
        }
        return trimmed
    }

    func setMountNetworkPolicy(_ policy: NetworkPolicy, mount: MountDefinition) async throws {
        let base = snapshot
        var document = base.document
        guard let index = document.mounts.firstIndex(where: { $0.id == mount.id }) else {
            throw VaultStoreError.notFound
        }
        document.mounts[index].networkPolicy = managedPolicy.allowCellular ? policy : .wifiOnly
        try await commit(document, basedOn: base)
    }

    func cancelOperation(_ operation: OperationRecord) async {
        guard let stateStore else { return }
        do {
            let accepted = try await stateStore.requestOperationCancellation(id: operation.id, at: .now)
            guard accepted else {
                await refreshActivity()
                return
            }
            cancellationRequestedIDs.insert(operation.id)
            await rclone.cancel(operationID: operation.id)
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func requestIssueResolution(
        _ issue: IssueRecord,
        action: IssueResolutionAction,
        renameTo: String? = nil
    ) async {
        guard let stateStore else { return }
        do {
            let accepted = try await stateStore.requestIssueResolution(
                issueID: issue.id,
                action: action,
                renameTo: renameTo,
                at: .now
            )
            guard accepted else {
                await refreshActivity()
                return
            }
            if let mountID = issue.mountID,
                let mount = mounts.first(where: { $0.id == mountID })
            {
                if action == .reconnect,
                    let remote = remotes.first(where: { $0.id == mount.remoteID })
                {
                    try await reconnect(remote)
                } else {
                    try await domains.signalWorkingSet(for: mount)
                }
            }
            await refreshActivity()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func relinkResource(remoteID: UUID, referenceID: UUID, to url: URL) async throws {
        guard let resourceStore else { throw VaultStoreError.notFound }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let base = snapshot
        var document = base.document
        guard let remoteIndex = document.remotes.firstIndex(where: { $0.id == remoteID }),
            let resourceIndex = document.remotes[remoteIndex].resources.firstIndex(where: { $0.id == referenceID })
        else { throw ResourceStoreError.missing(referenceID) }
        let old = document.remotes[remoteIndex].resources[resourceIndex]
        if old.kind == .securityScopedDirectory {
            try await Self.requireNonFileProviderDirectory(url)
        }
        let updated = try await resourceStore.relink(old, to: url, fileProviderStorageURLs: [])
        document.remotes[remoteIndex].resources[resourceIndex] = updated
        try await commit(document, basedOn: base)
    }

    func resetMountli() async throws {
        guard let vault, let stateStore else { throw VaultStoreError.notFound }
        for mount in mounts {
            let pending = try await stateStore.pendingOperationCount(mountID: mount.id)
            guard pending == 0 else { throw DomainRegistryError.dirtyOperations(pending) }
        }
        for mount in mounts {
            _ = try await domains.remove(mount, repository: stateStore, preserveDirtyUserData: true)
        }
        try await resourceStore?.removeAll()
        try await vault.reset()
        snapshot = try await vault.save(VaultDocument(), expectedRevision: 0)
        operationalStates.removeAll()
        recentOperations.removeAll()
        durableIssues.removeAll()
        domainIssues.removeAll()
        cancellationRequestedIDs.removeAll()
        requestedOperationID = nil
        requestedIssueID = nil
        try await reloadRclone(snapshot)
        refreshManagedPolicy()
    }

    func exportConfig(
        to url: URL,
        password: String?,
        selectedRemote: RemoteProfile?
    ) async throws {
        refreshManagedPolicy()
        guard managedPolicy.allowConfigExport else {
            throw ManagedPolicyRestriction.configExportDisabled
        }
        var exportSnapshot = try await resourceStore?.exportable(snapshot) ?? snapshot
        if let selectedRemote {
            let graph = try RemoteDependencyGraph(remotes: exportSnapshot.document.remotes)
            var names: Set<String> = [selectedRemote.engineName]
            var changed = true
            while changed {
                changed = false
                for name in Array(names) {
                    for dependency in graph.dependencies[name] ?? [] where names.insert(dependency).inserted {
                        changed = true
                    }
                }
            }
            exportSnapshot.document.remotes.removeAll { !names.contains($0.engineName) }
            exportSnapshot.document.mounts.removeAll()
        }
        try await configuration.exportConfig(snapshot: exportSnapshot, password: password, destination: url)
    }

    func exportConfig(to url: URL, password: String?) async throws {
        try await exportConfig(to: url, password: password, selectedRemote: nil)
    }

    func prepareDiagnostics() async throws -> URL {
        guard let stateStore else { throw VaultStoreError.notFound }
        let mountIDs = Set(mounts.map(\.id))
        recentOperations = try await stateStore.recentOperations(limit: 2_000).filter {
            mountIDs.contains($0.mountID)
        }
        let completed = recentOperations.compactMap { operation -> (String, Double)? in
            guard let completedAt = operation.completedAt else { return nil }
            return (operation.kind.rawValue, completedAt.timeIntervalSince(operation.startedAt) * 1_000)
        }
        let timing = Dictionary(grouping: completed, by: \.0).mapValues { samples in
            samples.reduce(0) { $0 + $1.1 } / Double(samples.count)
        }
        var diagnosticMounts: [DiagnosticMount] = []
        for mount in snapshot.document.mounts {
            let state = operationalStates[mount.id] ?? MountOperationalState(mountID: mount.id)
            let backend = snapshot.document.remotes.first { $0.id == mount.remoteID }?.backendType ?? "missing"
            let capabilities = try? await probeMount(remoteID: mount.remoteID, root: mount.root)
            diagnosticMounts.append(
                DiagnosticMount(
                    backendType: backend,
                    status: state.status,
                    pendingOperations: state.pendingOperations,
                    unresolvedIssues: state.unresolvedIssues,
                    capabilities: capabilities
                ))
        }
        let issueCodes = Set(
            policyIssues.map(\.diagnosticCode)
                + domainIssues.map { $0.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "domain" }
                + operationalStates.values.compactMap(\.lastErrorCode)
                + recentOperations.compactMap(\.diagnosticCode)
        ).sorted()
        var consentedFileNames: [String] = []
        if snapshot.document.settings.includeFilenamesInDiagnostics {
            let accessedAfter = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            for mount in snapshot.document.mounts where consentedFileNames.count < 500 {
                let items = try await stateStore.workingSet(mountID: mount.id, accessedAfter: accessedAfter)
                consentedFileNames.append(
                    contentsOf: items.prefix(500 - consentedFileNames.count).map(\.displayName)
                )
            }
        }
        let recentLogs = try await stateStore.recentDiagnosticLogs(limit: 2_000)
        #if os(iOS)
            let deviceClass = "iPhone or iPad"
        #else
            let deviceClass = "Mac"
        #endif
        let diagnosticSnapshot = DiagnosticSnapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            rcloneVersion: Bundle.main.object(forInfoDictionaryKey: "MOUNTLIRcloneVersion") as? String ?? "1.75.2",
            deviceClass: deviceClass,
            policy: managedPolicy,
            mounts: diagnosticMounts,
            issueCodes: issueCodes,
            operationTimingMilliseconds: timing,
            sqliteIntegrity: try await stateStore.integrityCheck(),
            recentLogs: recentLogs,
            includedFileNames: consentedFileNames
        )
        return try await diagnostics.export(
            diagnosticSnapshot,
            in: FileManager.default.temporaryDirectory.appendingPathComponent("MOUNTLI-Diagnostics", isDirectory: true)
        )
    }

    func finishDiagnostics(_ url: URL) async {
        try? await diagnostics.finishSharing(url)
    }

    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation() } catch { presentedError = error.localizedDescription }
        }
    }

    private func commit(_ document: VaultDocument, basedOn base: VaultSnapshot) async throws {
        // SwiftUI bindings (menu bar insertion, toggles, pickers) write back unchanged values,
        // sometimes before bootstrap has opened the vault; those must not surface an error.
        guard document != base.document else { return }
        guard let vault else { throw VaultStoreError.notFound }
        snapshot = try await vault.saveMergingChanges(document, basedOn: base)
        try await loadSnapshotIntoRclone()
        refreshManagedPolicy()
    }

    private func loadSnapshotIntoRclone() async throws {
        if let resourceStore {
            try await rclone.loadVault(resourceStore.materialize(snapshot))
        } else {
            try await rclone.loadVault(snapshot)
        }
    }

    private func refreshManagedPolicy() {
        let dictionary = UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed") ?? [:]
        #if os(macOS)
            let transferRange = 1...8
        #else
            let transferRange = 1...4
        #endif
        let result = ManagedPolicyReader.parse(
            dictionary: dictionary,
            catalog: Set(fullCatalog.map(\.name)),
            platformTransferRange: transferRange
        )
        managedPolicy = result.policy
        ManagedPolicyCache.publish(result.policy)
        policyIssues = result.issues + result.policy.issues(for: snapshot.document)
        policyLogger?.info(
            result.issues.isEmpty
                ? "managed policy applied"
                : "managed policy applied with \(result.issues.count) validation issues"
        )
        if let allowed = result.policy.allowedBackendTypes {
            catalog = fullCatalog.filter { allowed.contains($0.name) }
        } else {
            catalog = fullCatalog
        }
    }

    private static func requireNonFileProviderDirectory(_ url: URL) async throws {
        let domainIdentifier = await withCheckedContinuation {
            (continuation: CheckedContinuation<NSFileProviderDomainIdentifier?, Never>) in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) {
                _, domainIdentifier, _ in
                continuation.resume(returning: domainIdentifier)
            }
        }
        guard domainIdentifier == nil else {
            throw ResourceStoreError.invalidSelection(
                "A File Provider location cannot be used for local or cache storage."
            )
        }
    }

    private func applicationSupportRoot() throws -> URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.ch.benavo.mountli") {
            return group
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let root = base.appendingPathComponent("MOUNTLI", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private final class MountliNotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = MountliNotificationRouter()

    private let lock = NSLock()
    private var handler: (@Sendable (URL) -> Void)?

    func install(handler: @escaping @Sendable (URL) -> Void) {
        lock.withLock { self.handler = handler }
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let rawURL = response.notification.request.content.userInfo["mountliURL"] as? String,
            let url = URL(string: rawURL)
        else { return }
        let currentHandler = lock.withLock { handler }
        currentHandler?(url)
    }
}

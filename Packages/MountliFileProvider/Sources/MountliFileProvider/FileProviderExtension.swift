import CryptoKit
@preconcurrency import FileProvider
import Foundation
import MountliCore
import UniformTypeIdentifiers

open class MountliFileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    public let domain: NSFileProviderDomain
    let environmentTask: Task<ProviderEnvironment, any Error>

    required public init(domain: NSFileProviderDomain) {
        self.domain = domain
        let identifier = domain.identifier.rawValue
        let displayName = domain.displayName
        environmentTask = Task {
            try await ProviderEnvironment.live(domainIdentifier: identifier, displayName: displayName)
        }
        super.init()
    }

    public init(domain: NSFileProviderDomain, environmentTask: Task<ProviderEnvironment, any Error>) {
        self.domain = domain
        self.environmentTask = environmentTask
        super.init()
    }

    open func invalidate() {
        Task {
            if let environment = try? await environmentTask.value {
                await environment.invalidate()
            }
            environmentTask.cancel()
        }
    }

    open func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> any NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer {
            throw CocoaError(.featureUnsupported)
        }
        return MountliFileProviderEnumerator(
            environmentTask: environmentTask,
            containerIdentifier: containerItemIdentifier
        )
    }

    open func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, (any Error)?) -> Void
    ) -> Progress {
        let completion = UncheckedSendableBox(completionHandler)
        return perform(completion: { (result: Result<MountliFileProviderItem, any Error>) in
            switch result {
            case .success(let item): completion.value(item, nil)
            case .failure(let error): completion.value(nil, ProviderErrorMapper.map(error))
            }
        }) {
            let environment = try await self.environmentTask.value
            return try await environment.fileProviderItem(identifier: identifier)
        }
    }

    open func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        let completion = UncheckedSendableBox(completionHandler)
        Task {
            defer { completion.value() }
            guard let manager = NSFileProviderManager(for: domain) else { return }
            do {
                let identifiers = try await ProviderMaterializedObserver.collect(
                    from: manager.enumeratorForMaterializedItems()
                )
                let environment = try await environmentTask.value
                try await environment.replaceMaterializedDirectories(with: identifiers)
            } catch {
                // The system will invoke this callback again when the materialized set changes.
            }
        }
    }

    open func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, (any NSFileProviderItem)?, (any Error)?) -> Void
    ) -> Progress {
        let completion = UncheckedSendableBox(completionHandler)
        let version = UncheckedSendableBox(requestedVersion)
        let operationID = UUID()
        let progress = Progress(totalUnitCount: -1)
        let task = Task {
            do {
                let environment = try await environmentTask.value
                environment.trackProgress(progress, operationID: operationID)
                guard let stored = try await environment.storedItem(identifier: itemIdentifier), !stored.isDirectory else {
                    throw BridgeFailure(kind: .notFound, message: "File was not found", retryable: false)
                }
                let url = try await environment.download(
                    operationID: operationID,
                    item: stored,
                    requestedVersion: version.value
                )
                let item = try await environment.fileProviderItem(identifier: itemIdentifier)
                completion.value(url, item, nil)
            } catch is CancellationError {
                completion.value(nil, nil, CocoaError(.userCancelled))
            } catch {
                completion.value(nil, nil, ProviderErrorMapper.map(error))
            }
        }
        progress.cancellationHandler = {
            task.cancel()
            Task {
                if let environment = try? await self.environmentTask.value {
                    await environment.rclone.cancel(operationID: operationID)
                }
            }
        }
        return progress
    }

    open func createItem(
        basedOn itemTemplate: any NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        let completion = UncheckedSendableBox(completionHandler)
        let template = UncheckedSendableBox(itemTemplate)
        let operationID = Self.createOperationIdentifier(
            template.value.itemIdentifier,
            domainIdentifier: domain.identifier.rawValue
        )
        return perform(
            operationIDs: [operationID],
            completion: { (result: Result<CreateResult, any Error>) in
                switch result {
                case .success(let created):
                    completion.value(created.item, created.pending, false, nil)
                case .failure(let error):
                    completion.value(nil, fields, false, ProviderErrorMapper.map(error))
                }
            }
        ) {
            let environment = try await self.environmentTask.value
            let (_, mount, remote) = try await environment.configuration()
            try await environment.requireNetworkAccess(for: mount)
            let parent = try await environment.storedItem(identifier: template.value.parentItemIdentifier)
            let capabilities = try await environment.backendCapabilities()
            try Self.requireMutable(item: parent, mount: mount, capabilities: capabilities)
            let path = Self.join(parent?.remotePath ?? mount.root, template.value.filename)
            let isDirectory = template.value.contentType?.conforms(to: .folder) == true
            let priorOperation = try await environment.operation(id: operationID)

            var existingRemote: RemoteItem?
            do {
                existingRemote = try await environment.rclone.stat(remote: remote, path: path, objectID: nil)
            } catch let failure as BridgeFailure where failure.kind == .notFound {
                existingRemote = nil
            }
            if let existingRemote {
                let children = try await environment.children(parent: template.value.parentItemIdentifier)
                let collision = children.first {
                    $0.remoteID == existingRemote.objectID || $0.remotePath == existingRemote.path
                }
                let matchedReplay =
                    options.contains(.mayAlreadyExist)
                    && (priorOperation.map(Self.canReconcileCreateReplay) == true
                        || collision?.id == Self.storedIdentifier(template.value.itemIdentifier))
                guard matchedReplay, let collision else {
                    throw ProviderFilenameCollision(
                        message: "An item with this name already exists.",
                        item: collision.map {
                            MountliFileProviderItem(
                                stored: $0,
                                mount: mount,
                                backendCapabilities: capabilities
                            )
                        }
                    )
                }
                return CreateResult(
                    item: MountliFileProviderItem(
                        stored: collision,
                        mount: mount,
                        backendCapabilities: capabilities
                    ),
                    pending: fields.subtracting(
                        Self.appliedCreateFields(
                            isDirectory: isDirectory,
                            hasContents: url != nil
                        ))
                )
            }

            if priorOperation?.outcome == .succeeded {
                throw BridgeFailure(
                    kind: .conflict,
                    message: "The previously created remote item is no longer available.",
                    retryable: false
                )
            }
            if priorOperation?.outcome == .running || priorOperation?.outcome == .pending {
                throw BridgeFailure(
                    kind: .unreachable,
                    message: "The create operation is still being reconciled.",
                    retryable: true
                )
            }

            do {
                if isDirectory {
                    try await environment.performOperation(operationID: operationID, kind: .createDirectory) {
                        try await environment.rclone.makeDirectory(
                            operationID: operationID,
                            remote: remote,
                            path: path
                        )
                    }
                } else {
                    guard let url else {
                        throw BridgeFailure(
                            kind: .unsupported,
                            message: "File content is required for a new file.",
                            retryable: false
                        )
                    }
                    let totalBytes =
                        try url.resourceValues(forKeys: [.fileSizeKey])
                        .fileSize
                        .map(Int64.init) ?? 0
                    _ = try await environment.performOperation(
                        operationID: operationID,
                        kind: .upload,
                        totalBytes: totalBytes
                    ) {
                        try await environment.rclone.upload(
                            operationID: operationID,
                            remote: remote,
                            path: path,
                            source: url,
                            expectedVersion: nil
                        )
                    }
                }
            } catch let failure as BridgeFailure where failure.kind == .alreadyExists {
                let children = try await environment.children(parent: template.value.parentItemIdentifier)
                let collision = children.first(where: { $0.remotePath == path })
                throw ProviderFilenameCollision(
                    message: failure.message,
                    item: collision.map {
                        MountliFileProviderItem(
                            stored: $0,
                            mount: mount,
                            backendCapabilities: capabilities
                        )
                    }
                )
            }

            let children = try await environment.children(parent: template.value.parentItemIdentifier)
            guard let created = children.first(where: { $0.remotePath == path }) else {
                throw BridgeFailure(
                    kind: .internal,
                    message: "Created item could not be reconciled.",
                    retryable: true
                )
            }
            return CreateResult(
                item: MountliFileProviderItem(
                    stored: created,
                    mount: mount,
                    backendCapabilities: capabilities
                ),
                pending: fields.subtracting(
                    Self.appliedCreateFields(
                        isDirectory: isDirectory,
                        hasContents: url != nil
                    ))
            )
        }
    }

    open func modifyItem(
        _ item: any NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        let completion = UncheckedSendableBox(completionHandler)
        let submittedItem = UncheckedSendableBox(item)
        let baseContentVersion = version.contentVersion
        let operationScope = baseContentVersion.base64EncodedString()
        let moveID = Self.operationIdentifier(
            submittedItem.value.itemIdentifier,
            scope: "move-\(operationScope)"
        )
        let uploadID = Self.operationIdentifier(
            submittedItem.value.itemIdentifier,
            scope: "upload-\(operationScope)"
        )
        return perform(
            operationIDs: [moveID, uploadID],
            completion: { (result: Result<ModificationResult, any Error>) in
                switch result {
                case .success(let updated):
                    completion.value(updated.item, updated.pending, false, nil)
                case .failure(let error):
                    completion.value(nil, changedFields, false, ProviderErrorMapper.map(error))
                }
            }
        ) {
            let environment = try await self.environmentTask.value
            let (_, mount, remote) = try await environment.configuration()
            try await environment.requireNetworkAccess(for: mount)
            guard
                let stored = try await environment.storedItem(
                    identifier: submittedItem.value.itemIdentifier
                )
            else {
                throw BridgeFailure(kind: .notFound, message: "Item was not found.", retryable: false)
            }
            let capabilities = try await environment.backendCapabilities()
            try Self.requireMutable(item: stored, mount: mount, capabilities: capabilities)

            let moveRequested =
                changedFields.contains(.filename)
                || changedFields.contains(.parentItemIdentifier)
            let parent =
                moveRequested
                ? try await environment.storedItem(identifier: submittedItem.value.parentItemIdentifier)
                : nil
            let destination =
                moveRequested
                ? Self.join(parent?.remotePath ?? mount.root, submittedItem.value.filename)
                : stored.remotePath
            let moveOperation = moveRequested ? try await environment.operation(id: moveID) : nil
            let uploadOperation =
                changedFields.contains(.contents)
                ? try await environment.operation(id: uploadID)
                : nil

            var currentStored = stored
            var remoteItem: RemoteItem
            if baseContentVersion != stored.contentVersion,
                moveRequested,
                destination == stored.remotePath,
                moveOperation?.outcome == .succeeded
            {
                remoteItem = try await environment.rclone.stat(
                    remote: remote,
                    path: stored.remotePath,
                    objectID: stored.remoteID
                )
                guard StoredItemVersion.contentVersion(for: remoteItem) == stored.contentVersion else {
                    try await environment.recordVersionConflict(
                        item: stored,
                        mountID: mount.id,
                        operationKind: .move
                    )
                    throw BridgeFailure(
                        kind: .conflict,
                        message: "The remote version changed after the move.",
                        retryable: false
                    )
                }
            } else {
                remoteItem = try await environment.authorizeFreshVersion(
                    of: stored,
                    baseContentVersion: baseContentVersion,
                    remote: remote,
                    operationKind: moveRequested ? .move : .upload
                )
            }

            var supported: NSFileProviderItemFields = []
            if changedFields.contains(.contents),
                uploadOperation?.outcome != .succeeded,
                let newContents
            {
                let totalBytes =
                    try newContents.resourceValues(forKeys: [.fileSizeKey])
                    .fileSize
                    .map(Int64.init) ?? 0
                try await environment.prepareOperation(
                    id: uploadID,
                    kind: .upload,
                    item: stored,
                    totalBytes: totalBytes
                )
            }

            if moveRequested {
                if destination != currentStored.remotePath {
                    let sourceItem = remoteItem
                    remoteItem = try await environment.performOperation(
                        operationID: moveID,
                        kind: .move,
                        itemID: stored.id
                    ) {
                        try await environment.rclone.move(
                            operationID: moveID,
                            remote: remote,
                            source: sourceItem,
                            destinationPath: destination,
                            expectedDestinationVersion: nil
                        )
                    }
                    currentStored = try await environment.updateStoredItem(
                        currentStored,
                        parentID: parent?.id,
                        remoteItem: remoteItem
                    )
                }
                supported.formUnion([.filename, .parentItemIdentifier])
            }

            if changedFields.contains(.contents), let newContents {
                if uploadOperation?.outcome == .succeeded {
                    supported.insert(.contents)
                } else {
                    let sourceItem = remoteItem
                    remoteItem = try await environment.performOperation(
                        operationID: uploadID,
                        kind: .upload,
                        itemID: stored.id
                    ) {
                        try await environment.rclone.upload(
                            operationID: uploadID,
                            remote: remote,
                            path: sourceItem.path,
                            source: newContents,
                            expectedVersion: sourceItem.fingerprint
                        )
                    }
                    currentStored = try await environment.updateStoredItem(
                        currentStored,
                        parentID: currentStored.parentID,
                        remoteItem: remoteItem
                    )
                    supported.insert(.contents)
                }
            }

            #if os(iOS)
                if changedFields.contains(.favoriteRank) {
                    try await environment.setPinned(
                        submittedItem.value.favoriteRank != nil,
                        item: currentStored
                    )
                    supported.insert(.favoriteRank)
                }
            #endif

            if moveRequested || changedFields.contains(.contents) {
                try await environment.resolveVersionConflicts(for: stored.id)
            }
            let reconciled = try await environment.fileProviderItem(
                identifier: submittedItem.value.itemIdentifier
            )
            return ModificationResult(
                item: reconciled,
                pending: changedFields.subtracting(supported)
            )
        }
    }

    open func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any Error)?) -> Void
    ) -> Progress {
        let completion = UncheckedSendableBox(completionHandler)
        let baseContentVersion = version.contentVersion
        let progress = Progress(totalUnitCount: -1)
        let operationID = Self.operationIdentifier(
            identifier,
            scope: "delete-\(baseContentVersion.base64EncodedString())"
        )
        let task = Task {
            do {
                let environment = try await environmentTask.value
                environment.trackProgress(progress, operationID: operationID)
                let (_, mount, remote) = try await environment.configuration()
                try await environment.requireNetworkAccess(for: mount)
                guard let stored = try await environment.storedItem(identifier: identifier) else {
                    throw BridgeFailure(kind: .notFound, message: "Item was not found.", retryable: false)
                }
                let capabilities = try await environment.backendCapabilities()
                try Self.requireMutable(item: stored, mount: mount, capabilities: capabilities)
                guard !stored.isDirectory || options.contains(.recursive) else {
                    throw BridgeFailure(
                        kind: .unsupported,
                        message: "Directory deletion requires the recursive option.",
                        retryable: false
                    )
                }
                let parentIdentifier =
                    stored.parentID.map {
                        NSFileProviderItemIdentifier("item.\($0.uuidString.lowercased())")
                    } ?? .rootContainer
                let priorOperation = try await environment.operation(id: operationID)
                let remoteItem: RemoteItem
                do {
                    remoteItem = try await environment.authorizeFreshVersion(
                        of: stored,
                        baseContentVersion: baseContentVersion,
                        remote: remote,
                        operationKind: .delete
                    )
                } catch let failure as BridgeFailure where failure.kind == .notFound && priorOperation != nil {
                    _ = try await environment.deleteStoredItem(stored)
                    try await environment.resolveVersionConflicts(for: stored.id)
                    await environment.signalEnumerators(parentIdentifier: parentIdentifier)
                    completion.value(nil)
                    return
                }
                try await environment.performOperation(
                    operationID: operationID,
                    kind: .delete,
                    itemID: stored.id
                ) {
                    try await environment.rclone.delete(
                        operationID: operationID,
                        remote: remote,
                        item: remoteItem
                    )
                }
                _ = try await environment.deleteStoredItem(stored)
                try await environment.resolveVersionConflicts(for: stored.id)
                await environment.signalEnumerators(parentIdentifier: parentIdentifier)
                completion.value(nil)
            } catch is CancellationError {
                completion.value(CocoaError(.userCancelled))
            } catch {
                completion.value(ProviderErrorMapper.map(error))
            }
        }
        progress.cancellationHandler = {
            task.cancel()
            Task {
                if let environment = try? await self.environmentTask.value {
                    await environment.rclone.cancel(operationID: operationID)
                }
            }
        }
        return progress
    }

    private func perform<Value: Sendable>(
        operationIDs: [UUID] = [],
        completion: @escaping @Sendable (Result<Value, any Error>) -> Void,
        operation: @escaping @Sendable () async throws -> Value
    ) -> Progress {
        let progress = Progress(totalUnitCount: -1)
        let task = Task {
            if !operationIDs.isEmpty, let environment = try? await self.environmentTask.value {
                for operationID in operationIDs {
                    environment.trackProgress(progress, operationID: operationID)
                }
            }
            do { completion(.success(try await operation())) } catch is CancellationError { completion(.failure(CocoaError(.userCancelled))) } catch {
                completion(.failure(error))
            }
        }
        progress.cancellationHandler = {
            task.cancel()
            guard !operationIDs.isEmpty else { return }
            Task {
                if let environment = try? await self.environmentTask.value {
                    for operationID in operationIDs {
                        await environment.rclone.cancel(operationID: operationID)
                    }
                }
            }
        }
        return progress
    }

    static func createOperationIdentifier(
        _ identifier: NSFileProviderItemIdentifier,
        domainIdentifier: String = ""
    ) -> UUID {
        operationIdentifier(identifier, scope: "create-\(domainIdentifier)")
    }

    static func operationIdentifier(
        _ identifier: NSFileProviderItemIdentifier,
        scope: String
    ) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(scope)\u{0}\(identifier.rawValue)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    private static func canReconcileCreateReplay(_ operation: OperationRecord) -> Bool {
        switch operation.outcome {
        case .pending, .running, .retryableFailure, .succeeded:
            true
        case .cancelled, .failed:
            false
        }
    }

    private static func storedIdentifier(_ identifier: NSFileProviderItemIdentifier) -> UUID? {
        guard identifier.rawValue.hasPrefix("item.") else { return nil }
        return UUID(uuidString: String(identifier.rawValue.dropFirst("item.".count)))
    }

    static func appliedCreateFields(
        isDirectory: Bool,
        hasContents: Bool
    ) -> NSFileProviderItemFields {
        var fields: NSFileProviderItemFields = [.filename, .parentItemIdentifier]
        if !isDirectory, hasContents {
            fields.insert(.contents)
        }
        return fields
    }

    private static func requireMutable(
        item: StoredItem?,
        mount: MountDefinition,
        capabilities: BackendCapabilities
    ) throws {
        guard !mount.readOnly,
            !capabilities.readOnly,
            item.map(ProviderDuplicateProjection.isReadOnlyAlias) != true
        else {
            throw BridgeFailure(
                kind: .permissionDenied,
                message: "This item is read-only.",
                retryable: false
            )
        }
    }

    private static func join(_ parent: String, _ name: String) -> String {
        [parent.trimmingCharacters(in: CharacterSet(charactersIn: "/")), name]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }
}

private struct CreateResult: Sendable {
    var item: MountliFileProviderItem
    var pending: NSFileProviderItemFields
}

private struct ModificationResult: Sendable {
    var item: MountliFileProviderItem
    var pending: NSFileProviderItemFields
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

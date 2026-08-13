import CryptoKit
@preconcurrency import FileProvider
import Foundation
import MountliCore

public final class MountliFileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let environmentTask: Task<ProviderEnvironment, any Error>
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let taskLock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(
        environmentTask: Task<ProviderEnvironment, any Error>,
        containerIdentifier: NSFileProviderItemIdentifier
    ) {
        self.environmentTask = environmentTask
        self.containerIdentifier = containerIdentifier
    }

    public func invalidate() {
        taskLock.withLock {
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }

    public func enumerateItems(
        for observer: any NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        track {
            do {
                let environment = try await self.environmentTask.value
                let stored: [StoredItem]
                if self.containerIdentifier == .workingSet {
                    stored = try await environment.workingSet()
                } else {
                    stored = try await environment.children(parent: self.containerIdentifier)
                }
                let generation = Self.generation(for: stored)
                let cursor = try Self.cursor(from: page, generation: generation)
                guard cursor.offset >= 0, cursor.offset <= stored.count else {
                    throw ProviderErrorMapper.pageExpired()
                }
                let end = min(cursor.offset + 500, stored.count)
                let (_, mount, _) = try await environment.configuration()
                let capabilities = try? await environment.backendCapabilities()
                let items = stored[cursor.offset..<end].map {
                    MountliFileProviderItem(stored: $0, mount: mount, backendCapabilities: capabilities)
                }
                observer.didEnumerate(items)
                let nextPage =
                    end < stored.count
                    ? Self.page(offset: end, generation: generation)
                    : nil
                observer.finishEnumerating(upTo: nextPage)
            } catch {
                observer.finishEnumeratingWithError(ProviderErrorMapper.map(error))
            }
        }
    }

    public func enumerateChanges(
        for observer: any NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    ) {
        track {
            do {
                let environment = try await self.environmentTask.value
                let anchor = Self.anchorValue(syncAnchor)
                let (_, mount, _) = try await environment.configuration()
                let batch: JournalPage
                if self.containerIdentifier == .workingSet {
                    batch = try await environment.repository.workingSetChanges(
                        mountID: mount.id,
                        after: anchor,
                        limit: 500
                    )
                } else {
                    let containerID = try await environment
                        .storedItem(identifier: self.containerIdentifier)?
                        .id
                    batch = try await environment.repository.changes(
                        mountID: mount.id,
                        containerID: containerID,
                        after: anchor,
                        limit: 500
                    )
                }
                let capabilities = try? await environment.backendCapabilities()
                var updated: [any NSFileProviderItem] = []
                var deleted: [NSFileProviderItemIdentifier] = []
                for change in batch.changes {
                    let identifier = NSFileProviderItemIdentifier(
                        "item.\(change.itemID.uuidString.lowercased())"
                    )
                    if change.kind == .delete {
                        deleted.append(identifier)
                    } else if let item = try await environment.repository.item(
                        id: change.itemID,
                        mountID: mount.id
                    ) {
                        updated.append(
                            MountliFileProviderItem(
                                stored: item,
                                mount: mount,
                                backendCapabilities: capabilities
                            ))
                    }
                }
                observer.didUpdate(updated)
                observer.didDeleteItems(withIdentifiers: deleted)
                observer.finishEnumeratingChanges(
                    upTo: Self.anchor(batch.nextAnchor),
                    moreComing: batch.changes.count == 500
                )
            } catch ItemRepositoryError.syncAnchorExpired(_) {
                observer.finishEnumeratingWithError(ProviderErrorMapper.syncAnchorExpired())
            } catch {
                observer.finishEnumeratingWithError(ProviderErrorMapper.map(error))
            }
        }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let completion = EnumeratorSendableBox(completionHandler)
        track {
            guard
                let environment = try? await self.environmentTask.value,
                let (_, mount, _) = try? await environment.configuration(),
                let value = try? await environment.repository.currentSyncAnchor(mountID: mount.id)
            else {
                completion.value(nil)
                return
            }
            completion.value(Self.anchor(value))
        }
    }

    private func track(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        taskLock.withLock {
            tasks[id] = Task { [weak self] in
                await operation()
                guard let self else { return }
                _ = self.taskLock.withLock { self.tasks.removeValue(forKey: id) }
            }
        }
    }

    private struct PageCursor: Codable {
        var schemaVersion: Int
        var generation: String
        var offset: Int
    }

    private static func generation(for items: [StoredItem]) -> String {
        var data = Data()
        for item in items {
            data.append(Data(item.id.uuidString.utf8))
            data.append(item.contentVersion)
            data.append(item.metadataVersion)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func cursor(from page: NSFileProviderPage, generation: String) throws -> PageCursor {
        if page.rawValue as NSData == NSFileProviderPage.initialPageSortedByName
            || page.rawValue as NSData == NSFileProviderPage.initialPageSortedByDate
        {
            return PageCursor(schemaVersion: 1, generation: generation, offset: 0)
        }
        let cursor = try JSONDecoder().decode(PageCursor.self, from: page.rawValue)
        guard cursor.schemaVersion == 1, cursor.generation == generation else {
            throw ProviderErrorMapper.pageExpired()
        }
        return cursor
    }

    private static func page(offset: Int, generation: String) -> NSFileProviderPage {
        let data = try! JSONEncoder().encode(PageCursor(schemaVersion: 1, generation: generation, offset: offset))
        return NSFileProviderPage(rawValue: data)
    }

    private static func anchorValue(_ anchor: NSFileProviderSyncAnchor) -> Int64 {
        guard anchor.rawValue.count == MemoryLayout<Int64>.size else { return 0 }
        return anchor.rawValue.withUnsafeBytes { $0.load(as: Int64.self).bigEndian }
    }

    private static func anchor(_ value: Int64) -> NSFileProviderSyncAnchor {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { NSFileProviderSyncAnchor(rawValue: Data($0)) }
    }
}

private final class EnumeratorSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

@preconcurrency import FileProvider
import Foundation
import MountliCore
import UniformTypeIdentifiers

public final class MountliFileProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating, @unchecked Sendable {
    public static let syncingDecoration = NSFileProviderItemDecorationIdentifier("ch.benavo.mountli.syncing")
    public static let errorDecoration = NSFileProviderItemDecorationIdentifier("ch.benavo.mountli.error")
    public static let offlineDecoration = NSFileProviderItemDecorationIdentifier("ch.benavo.mountli.offline-available")

    public let stored: StoredItem?
    public let mount: MountDefinition
    public let status: MountStatus
    public let backendCapabilities: BackendCapabilities?

    public init(
        stored: StoredItem?,
        mount: MountDefinition,
        status: MountStatus = .online,
        backendCapabilities: BackendCapabilities? = nil
    ) {
        self.stored = stored
        self.mount = mount
        self.status = status
        self.backendCapabilities = backendCapabilities
        super.init()
    }

    public var itemIdentifier: NSFileProviderItemIdentifier {
        stored.map { NSFileProviderItemIdentifier("item.\($0.id.uuidString.lowercased())") } ?? .rootContainer
    }

    public var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard let stored else { return .rootContainer }
        return stored.parentID.map { NSFileProviderItemIdentifier("item.\($0.uuidString.lowercased())") } ?? .rootContainer
    }

    public var filename: String { stored?.displayName ?? mount.displayName }

    public var contentType: UTType {
        guard let stored else { return .folder }
        if stored.isDirectory { return .folder }
        return UTType(filenameExtension: URL(fileURLWithPath: stored.displayName).pathExtension) ?? .data
    }

    public var documentSize: NSNumber? { stored?.isDirectory == false ? NSNumber(value: stored?.size ?? 0) : nil }
    public var contentModificationDate: Date? { stored?.modificationDate }
    #if os(iOS)
        public var favoriteRank: NSNumber? {
            stored?.pinned == true ? NSNumber(value: 0) : nil
        }
    #endif

    public var itemVersion: NSFileProviderItemVersion {
        guard let stored else {
            let root = Data("mountli-root-\(mount.id.uuidString)".utf8)
            return NSFileProviderItemVersion(contentVersion: root, metadataVersion: root)
        }
        return NSFileProviderItemVersion(contentVersion: stored.contentVersion, metadataVersion: stored.metadataVersion)
    }

    public var capabilities: NSFileProviderItemCapabilities {
        let readOnly =
            mount.readOnly
            || (backendCapabilities?.readOnly ?? true)
            || stored.map(ProviderDuplicateProjection.isReadOnlyAlias) == true
        guard let stored else {
            var root: NSFileProviderItemCapabilities = [.allowsReading, .allowsContentEnumerating]
            if !readOnly {
                root.insert(.allowsAddingSubItems)
            }
            return root
        }

        var result: NSFileProviderItemCapabilities = [.allowsReading]
        if stored.isDirectory {
            result.insert(.allowsContentEnumerating)
        }
        guard !readOnly else { return result }

        result.formUnion([.allowsDeleting, .allowsRenaming, .allowsReparenting])
        if stored.isDirectory {
            result.insert(.allowsAddingSubItems)
        } else {
            result.insert(.allowsWriting)
        }
        return result
    }

    public var decorations: [NSFileProviderItemDecorationIdentifier]? {
        switch status {
        case .transferring: [Self.syncingDecoration]
        case .degraded, .error, .authenticationRequired: [Self.errorDecoration]
        case .offline where stored?.materialized == true: [Self.offlineDecoration]
        default: nil
        }
    }
}

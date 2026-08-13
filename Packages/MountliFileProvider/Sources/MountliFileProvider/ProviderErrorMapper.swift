@preconcurrency import FileProvider
import Foundation
import MountliCore

struct ProviderFilenameCollision: Error, @unchecked Sendable {
    let message: String
    let item: MountliFileProviderItem?
}

public enum ProviderErrorMapper {
    public static func map(_ error: any Error, collidingItem: (any NSFileProviderItem)? = nil) -> any Error {
        if let collision = error as? ProviderFilenameCollision {
            return map(
                BridgeFailure(
                    kind: .alreadyExists,
                    message: collision.message,
                    retryable: false
                ),
                collidingItem: collision.item
            )
        }
        if let repository = error as? ItemRepositoryError {
            switch repository {
            case .itemNotFound:
                return fileProviderError(.noSuchItem, message: "The item no longer exists.")
            case .syncAnchorExpired:
                return syncAnchorExpired()
            case .removalInProgress, .enumerationLeaseLost:
                return fileProviderError(
                    .serverUnreachable,
                    message: "The mount is temporarily unavailable; retrying is safe."
                )
            }
        }
        guard let bridge = error as? BridgeFailure else { return error }
        switch bridge.kind {
        case .notAuthenticated:
            return fileProviderError(.notAuthenticated, message: bridge.message)
        case .unreachable:
            return fileProviderError(.serverUnreachable, message: bridge.message)
        case .quotaExceeded:
            return fileProviderError(.insufficientQuota, message: bridge.message)
        case .notFound:
            return fileProviderError(.noSuchItem, message: bridge.message)
        case .alreadyExists:
            var userInfo: [String: Any] = [NSLocalizedDescriptionKey: bridge.message]
            if let collidingItem { userInfo[NSFileProviderErrorItemKey] = collidingItem }
            return NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.Code.filenameCollision.rawValue,
                userInfo: userInfo
            )
        case .permissionDenied:
            return POSIXError(.EACCES)
        case .conflict:
            #if os(macOS)
                return fileProviderError(.versionNoLongerAvailable, message: bridge.message)
            #else
                return fileProviderError(.cannotSynchronize, message: bridge.message)
            #endif
        case .unsupported:
            return fileProviderError(.cannotSynchronize, message: bridge.message)
        case .cancelled:
            return CocoaError(.userCancelled)
        case .internal:
            return fileProviderError(.cannotSynchronize, message: bridge.message)
        }
    }

    public static func pageExpired() -> any Error { fileProviderError(.pageExpired, message: "Directory page expired") }
    public static func syncAnchorExpired() -> any Error { fileProviderError(.syncAnchorExpired, message: "Sync anchor expired") }

    private static func fileProviderError(_ code: NSFileProviderError.Code, message: String) -> NSError {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

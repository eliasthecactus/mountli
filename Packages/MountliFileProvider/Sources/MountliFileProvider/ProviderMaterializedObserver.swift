@preconcurrency import FileProvider
import Foundation

final class ProviderMaterializedObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let enumerator: any NSFileProviderEnumerator
    private let lock = NSLock()
    private var identifiers: [NSFileProviderItemIdentifier] = []
    private var continuation: CheckedContinuation<[NSFileProviderItemIdentifier], any Error>?

    private init(
        enumerator: any NSFileProviderEnumerator,
        continuation: CheckedContinuation<[NSFileProviderItemIdentifier], any Error>
    ) {
        self.enumerator = enumerator
        self.continuation = continuation
    }

    static func collect(
        from enumerator: any NSFileProviderEnumerator
    ) async throws -> [NSFileProviderItemIdentifier] {
        try await withCheckedThrowingContinuation { continuation in
            let observer = ProviderMaterializedObserver(
                enumerator: enumerator,
                continuation: continuation
            )
            observer.enumerate(startingAt: NSFileProviderPage(rawValue: NSFileProviderPage.initialPageSortedByName as Data))
        }
    }

    func didEnumerate(_ updatedItems: [any NSFileProviderItem]) {
        lock.withLock {
            identifiers.append(contentsOf: updatedItems.map(\.itemIdentifier))
        }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        if let nextPage {
            enumerate(startingAt: nextPage)
            return
        }
        let result = lock.withLock {
            () -> (
                CheckedContinuation<[NSFileProviderItemIdentifier], any Error>?,
                [NSFileProviderItemIdentifier]
            ) in
            let continuation = self.continuation
            self.continuation = nil
            return (continuation, identifiers)
        }
        enumerator.invalidate()
        result.0?.resume(returning: result.1)
    }

    func finishEnumeratingWithError(_ error: any Error) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        enumerator.invalidate()
        continuation?.resume(throwing: error)
    }

    private func enumerate(startingAt page: NSFileProviderPage) {
        enumerator.enumerateItems(for: self, startingAt: page)
    }
}

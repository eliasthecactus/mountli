#if os(macOS)
    @preconcurrency import FileProvider
    import Foundation
    import MountliCore

    extension MountliFileProviderExtension: NSFileProviderPartialContentFetching {
        public func fetchPartialContents(
            for itemIdentifier: NSFileProviderItemIdentifier,
            version requestedVersion: NSFileProviderItemVersion,
            request: NSFileProviderRequest,
            minimalRange requestedRange: NSRange,
            aligningTo alignment: Int,
            options: NSFileProviderFetchContentsOptions,
            completionHandler:
                @escaping (
                    URL?, (any NSFileProviderItem)?, NSRange,
                    NSFileProviderMaterializationFlags, (any Error)?
                ) -> Void
        ) -> Progress {
            let completion = PartialSendableBox(completionHandler)
            let version = PartialSendableBox(requestedVersion)
            let operationID = UUID()
            let progress = Progress(totalUnitCount: Int64(requestedRange.length))
            let task = Task {
                do {
                    let environment = try await environmentTask.value
                    environment.trackProgress(progress, operationID: operationID)
                    guard let stored = try await environment.storedItem(identifier: itemIdentifier), !stored.isDirectory else {
                        throw BridgeFailure(kind: .notFound, message: "File was not found", retryable: false)
                    }
                    let requestedStart = Int64(requestedRange.location)
                    let requestedLength = Int64(requestedRange.length)
                    let blockSize = Int64(max(alignment, 1))
                    let requestedEnd = requestedStart.addingReportingOverflow(requestedLength)
                    guard !requestedEnd.overflow, requestedStart >= 0, requestedLength > 0 else {
                        throw BridgeFailure(kind: .unsupported, message: "Invalid byte range", retryable: false)
                    }
                    let alignedStart = (requestedStart / blockSize) * blockSize
                    let remainder = requestedEnd.partialValue % blockSize
                    let roundedEnd = requestedEnd.partialValue.addingReportingOverflow(
                        remainder == 0 ? 0 : blockSize - remainder
                    )
                    let alignedEnd = min(roundedEnd.overflow ? Int64.max : roundedEnd.partialValue, stored.size)
                    guard alignedStart < alignedEnd else {
                        throw BridgeFailure(kind: .notFound, message: "Byte range is outside the file", retryable: false)
                    }
                    let range = alignedStart..<alignedEnd
                    let url = try await environment.download(
                        operationID: operationID,
                        item: stored,
                        requestedVersion: version.value,
                        range: range
                    )
                    let item = try await environment.fileProviderItem(identifier: itemIdentifier)
                    let retrieved = NSRange(location: Int(alignedStart), length: Int(alignedEnd - alignedStart))
                    progress.completedUnitCount = Int64(retrieved.length)
                    completion.value(url, item, retrieved, [], nil)
                } catch is CancellationError {
                    completion.value(nil, nil, requestedRange, [], CocoaError(.userCancelled))
                } catch {
                    completion.value(nil, nil, requestedRange, [], ProviderErrorMapper.map(error))
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
    }

    private final class PartialSendableBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }
#endif

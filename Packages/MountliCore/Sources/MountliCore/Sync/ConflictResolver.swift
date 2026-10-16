import Foundation

public enum ConflictDecision: Equatable, Sendable {
    case proceed
    case preserveLocalAs(String)
    case keepRemoteAndRequireDeleteDecision
}

public enum ConflictResolver {
    public static func decide(
        kind: OperationKind,
        displayName: String,
        expectedVersion: Data?,
        currentRemoteVersion: Data?,
        localChanged: Bool,
        operationID: UUID,
        now: Date
    ) -> ConflictDecision {
        guard localChanged, expectedVersion != currentRemoteVersion else { return .proceed }
        if kind == .delete { return .keepRemoteAndRequireDeleteDecision }
        return .preserveLocalAs(
            conflictName(
                displayName: displayName,
                operationID: operationID,
                now: now,
                isDirectory: kind == .createDirectory
            ))
    }

    public static func conflictName(
        displayName: String,
        operationID: UUID,
        now: Date,
        isDirectory: Bool
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let operationSuffix = operationID.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(6)
        let suffix = " (conflict from Mountli \(formatter.string(from: now)) \(operationSuffix))"
        guard !isDirectory else { return displayName + suffix }
        let url = URL(fileURLWithPath: displayName)
        let fileExtension = url.pathExtension
        if fileExtension.isEmpty { return displayName + suffix }
        return url.deletingPathExtension().lastPathComponent + suffix + "." + fileExtension
    }
}

public struct DuplicateProjection: Sendable {
    public var canonical: RemoteItem
    public var duplicates: [(item: RemoteItem, virtualName: String)]
}

public enum DuplicateResolver {
    public static func project(_ items: [RemoteItem], caseInsensitive: Bool) -> [DuplicateProjection] {
        let groups = Dictionary(grouping: items) { item in
            caseInsensitive ? item.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) : item.name
        }
        return groups.values.map { group in
            let sorted = group.sorted {
                let left = $0.objectID ?? $0.path
                let right = $1.objectID ?? $1.path
                return left < right
            }
            let canonical = sorted[0]
            let duplicates = sorted.dropFirst().map { item in
                let identity = item.objectID ?? item.path
                let digest = identity.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
                let suffix = String(format: "%06x", digest & 0xFFFFFF)
                return (item, "\(item.name) (duplicate \(suffix))")
            }
            return DuplicateProjection(canonical: canonical, duplicates: duplicates)
        }.sorted { $0.canonical.name.localizedStandardCompare($1.canonical.name) == .orderedAscending }
    }
}

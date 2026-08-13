import Foundation
import MountliCore

enum ProviderDuplicateProjection {
    static func project(
        _ items: [RemoteItem],
        capabilities: BackendCapabilities
    ) -> [RemoteItem] {
        let grouped = Dictionary(grouping: items) {
            normalizedName($0.name, caseInsensitive: capabilities.caseInsensitive)
        }
        let sortedGroups = grouped.keys.sorted().compactMap { key -> [RemoteItem]? in
            grouped[key]?.sorted { identity($0) < identity($1) }
        }
        var projected = sortedGroups.compactMap(\.first)
        var occupied = Set(
            projected.map {
                normalizedName($0.name, caseInsensitive: capabilities.caseInsensitive)
            })

        for group in sortedGroups {
            for duplicate in group.dropFirst() {
                var item = duplicate
                let suffix = duplicateSuffix(identity(duplicate))
                let baseName = "\(duplicate.name) (duplicate \(suffix))"
                var candidate = baseName
                var discriminator = 2
                while occupied.contains(normalizedName(candidate, caseInsensitive: capabilities.caseInsensitive)) {
                    candidate = "\(baseName)-\(discriminator)"
                    discriminator += 1
                }
                item.name = candidate
                occupied.insert(normalizedName(candidate, caseInsensitive: capabilities.caseInsensitive))
                projected.append(item)
            }
        }
        return projected.sorted {
            let left = normalizedName($0.name, caseInsensitive: capabilities.caseInsensitive)
            let right = normalizedName($1.name, caseInsensitive: capabilities.caseInsensitive)
            return left == right ? identity($0) < identity($1) : left < right
        }
    }

    static func isReadOnlyAlias(_ item: StoredItem) -> Bool {
        let originalName =
            item.remotePath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? item.remotePath
        guard item.displayName != originalName else { return false }
        return item.displayName.hasPrefix(originalName + " (duplicate ")
    }

    private static func identity(_ item: RemoteItem) -> String {
        item.objectID ?? item.path
    }

    private static func duplicateSuffix(_ identity: String) -> String {
        let digest = identity.utf8.reduce(UInt64(1_469_598_103_934_665_603)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return String(format: "%06x", digest & 0xFF_FFFF)
    }

    private static func normalizedName(_ name: String, caseInsensitive: Bool) -> String {
        guard caseInsensitive else { return name }
        return name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

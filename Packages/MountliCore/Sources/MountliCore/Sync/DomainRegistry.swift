@preconcurrency import FileProvider
import Foundation

public enum DomainRegistryError: Error, Sendable {
    case unavailable(String)
    case dirtyOperations(Int)
    case orphanDomain(String)
}

extension DomainRegistryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            detail.hasPrefix("mountli.")
                ? "This location is not registered with Finder or Files. Restore it from Issues, or remove and add the mount again."
                : detail
        case .dirtyOperations(let count):
            "\(count) change\(count == 1 ? " is" : "s are") still waiting to upload. Wait for them to finish, then try again."
        case .orphanDomain:
            "Finder or Files still shows a location that MOUNTLI no longer manages."
        }
    }
}

public actor DomainRegistry {
    public init() {}

    public func add(_ mount: MountDefinition) async throws {
        let domain = makeDomain(mount)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSFileProviderManager.add(domain) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    public func installedDomains() async throws -> [NSFileProviderDomain] {
        let box: DomainListBox = try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: DomainListBox(domains)) }
            }
        }
        return box.value
    }

    public func reconcile(
        mounts: [MountDefinition],
        confirmMissing: @Sendable (MountDefinition) async -> Bool
    ) async throws -> [String] {
        let installed = try await installedDomains()
        let installedIDs = Set(installed.map { $0.identifier.rawValue })
        let definitions = Dictionary(uniqueKeysWithValues: mounts.map { ($0.domainIdentifier, $0) })
        var issues: [String] = []
        for mount in mounts where mount.isEnabled && !installedIDs.contains(mount.domainIdentifier) {
            if await confirmMissing(mount) {
                try await add(mount)
            } else {
                issues.append("missing:\(mount.domainIdentifier)")
            }
        }
        for domain in installed where definitions[domain.identifier.rawValue] == nil {
            issues.append("orphan:\(domain.identifier.rawValue)")
        }
        return issues
    }

    public func remove(
        _ mount: MountDefinition,
        repository: any ItemRepository,
        preserveDirtyUserData: Bool
    ) async throws -> URL? {
        let owner = "domain-removal-\(UUID().uuidString.lowercased())"
        guard
            let pending = try await repository.acquireRemovalAdmission(
                mountID: mount.id,
                owner: owner,
                ttl: 300
            )
        else {
            throw DomainRegistryError.unavailable("This mount is already being removed.")
        }
        guard pending == 0 else {
            try await repository.releaseRemovalAdmission(mountID: mount.id, owner: owner)
            throw DomainRegistryError.dirtyOperations(pending)
        }
        let renewal = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                do {
                    guard
                        try await repository.renewRemovalAdmission(
                            mountID: mount.id,
                            owner: owner,
                            ttl: 300
                        )
                    else { return }
                } catch {
                    continue
                }
            }
        }
        do {
            let result = try await removeDomain(
                makeDomain(mount),
                preserveDirtyUserData: preserveDirtyUserData
            )
            renewal.cancel()
            try await repository.releaseRemovalAdmission(mountID: mount.id, owner: owner)
            return result
        } catch {
            renewal.cancel()
            try? await repository.releaseRemovalAdmission(mountID: mount.id, owner: owner)
            throw error
        }
    }

    public func removeMountliDomainsAfterExplicitVaultReset() async throws {
        let installed = try await installedDomains()
        let domains = installed.filter { $0.identifier.rawValue.hasPrefix("mountli.") }
        for domain in domains {
            _ = try await removeDomain(domain, preserveDirtyUserData: false)
        }
    }

    /// Removes a MOUNTLI-owned domain that no longer has a matching mount definition.
    public func removeOrphan(identifier: String) async throws {
        guard identifier.hasPrefix("mountli."),
            let domain = try await installedDomains().first(where: { $0.identifier.rawValue == identifier })
        else { return }
        _ = try await removeDomain(domain, preserveDirtyUserData: true)
    }

    public func userVisibleRoot(for mount: MountDefinition) async throws -> URL {
        let domain = makeDomain(mount)
        guard let manager = NSFileProviderManager(for: domain) else {
            throw DomainRegistryError.unavailable(mount.domainIdentifier)
        }
        return try await withCheckedThrowingContinuation { continuation in
            manager.getUserVisibleURL(for: .rootContainer) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: DomainRegistryError.unavailable(mount.domainIdentifier))
                }
            }
        }
    }

    public func signalWorkingSet(for mount: MountDefinition) async throws {
        let domain = makeDomain(mount)
        guard let manager = NSFileProviderManager(for: domain) else {
            throw DomainRegistryError.unavailable(mount.domainIdentifier)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            manager.signalEnumerator(for: .workingSet) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func makeDomain(_ mount: MountDefinition) -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(mount.domainIdentifier),
            displayName: mount.displayName
        )
        domain.supportsSyncingTrash = false
        #if os(macOS)
            if #available(macOS 26.0, *) { domain.supportsStringSearchRequest = false }
        #endif
        return domain
    }

    private func removeDomain(
        _ domain: NSFileProviderDomain,
        preserveDirtyUserData: Bool
    ) async throws -> URL? {
        #if os(macOS)
            let mode: NSFileProviderManager.DomainRemovalMode =
                preserveDirtyUserData ? .preserveDirtyUserData : .removeAll
            return try await withCheckedThrowingContinuation { continuation in
                NSFileProviderManager.remove(domain, mode: mode) { location, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: location) }
                }
            }
        #else
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                NSFileProviderManager.remove(domain) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            return nil
        #endif
    }
}

private final class DomainListBox: @unchecked Sendable {
    let value: [NSFileProviderDomain]
    init(_ value: [NSFileProviderDomain]) { self.value = value }
}

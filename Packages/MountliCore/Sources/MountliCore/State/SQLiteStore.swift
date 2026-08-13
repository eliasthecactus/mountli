import CSQLite
import CryptoKit
import Foundation

public struct SQLiteStoreError: Error, Equatable, Sendable {
    public let code: Int32
    public let message: String
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor SQLiteStore: ItemRepository, IssueRepository, OperationCancellationRepository {
    private let databaseURL: URL
    nonisolated(unsafe) private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(databaseURL: URL) async throws {
        self.databaseURL = databaseURL
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK else {
            let error = Self.error(from: handle)
            if let handle { sqlite3_close(handle) }
            throw error
        }
        database = handle
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA busy_timeout=5000")
        try execute("PRAGMA foreign_keys=ON")
        try migrate()
        try protectDatabaseFiles()
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func state(mountID: UUID) async throws -> MountOperationalState? {
        let statement = try prepare("SELECT state_json FROM mount_state WHERE mount_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decoder.decode(MountOperationalState.self, from: columnData(statement, index: 0))
    }

    public func setState(_ state: MountOperationalState) async throws {
        let data = try encoder.encode(state)
        let statement = try prepare(
            """
            INSERT INTO mount_state(mount_id, state_json, updated_at) VALUES(?, ?, ?)
            ON CONFLICT(mount_id) DO UPDATE SET state_json=excluded.state_json, updated_at=excluded.updated_at
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(state.mountID.uuidString.lowercased(), at: 1, in: statement)
        try bind(data, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, Date.now.timeIntervalSince1970)
        try stepDone(statement)
    }

    public func recordDiagnosticLog(
        category: MountliLogCategory,
        level: String,
        message: String,
        createdAt: Date = .now
    ) throws {
        try transaction {
            let statement = try prepare(
                "INSERT INTO diagnostic_logs(created_at,category,level,message) VALUES(?,?,?,?)"
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, createdAt.timeIntervalSince1970)
            try bind(category.rawValue, at: 2, in: statement)
            try bind(level, at: 3, in: statement)
            try bind(message, at: 4, in: statement)
            try stepDone(statement)
            try execute(
                "DELETE FROM diagnostic_logs WHERE id NOT IN (SELECT id FROM diagnostic_logs ORDER BY id DESC LIMIT 2000)"
            )
        }
    }

    public func recentDiagnosticLogs(limit: Int = 500) throws -> [String] {
        let statement = try prepare(
            """
            SELECT created_at,category,level,message
            FROM diagnostic_logs
            ORDER BY id DESC
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(0, min(limit, 2_000))))
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let category = columnString(statement, index: 1)
            let level = columnString(statement, index: 2)
            let message = columnString(statement, index: 3)
            result.append("\(createdAt.ISO8601Format()) [\(category)] \(level) \(message)")
        }
        return result.reversed()
    }

    public func recordOperation(_ operation: OperationRecord) throws {
        try transaction {
            if try hasActiveRemovalGate(mountID: operation.mountID) {
                throw ItemRepositoryError.removalInProgress(operation.mountID)
            }
            let statement = try prepare(
                """
                INSERT INTO operations(
                    id,mount_id,item_id,kind,outcome,completed_bytes,total_bytes,started_at,completed_at,diagnostic_code
                ) VALUES(?,?,?,?,?,?,?,?,?,?)
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(operation.id.uuidString.lowercased(), at: 1, in: statement)
            try bind(operation.mountID.uuidString.lowercased(), at: 2, in: statement)
            try bind(operation.itemID?.uuidString.lowercased(), at: 3, in: statement)
            try bind(operation.kind.rawValue, at: 4, in: statement)
            try bind(operation.outcome.rawValue, at: 5, in: statement)
            sqlite3_bind_int64(statement, 6, operation.completedBytes)
            sqlite3_bind_int64(statement, 7, operation.totalBytes)
            sqlite3_bind_double(statement, 8, operation.startedAt.timeIntervalSince1970)
            if let completedAt = operation.completedAt {
                sqlite3_bind_double(statement, 9, completedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 9)
            }
            try bind(operation.diagnosticCode, at: 10, in: statement)
            try stepDone(statement)
        }
    }

    public func finishOperation(
        id: UUID,
        outcome: OperationOutcome,
        completedBytes: Int64 = 0,
        diagnosticCode: String? = nil
    ) throws {
        try transaction {
            let statement = try prepare(
                """
                UPDATE operations SET
                    outcome=?,
                    completed_bytes=CASE WHEN ?='succeeded' THEN total_bytes ELSE MAX(completed_bytes, ?) END,
                    completed_at=?,
                    diagnostic_code=?
                WHERE id=?
                """
            )
            try bind(outcome.rawValue, at: 1, in: statement)
            try bind(outcome.rawValue, at: 2, in: statement)
            sqlite3_bind_int64(statement, 3, completedBytes)
            sqlite3_bind_double(statement, 4, Date.now.timeIntervalSince1970)
            try bind(diagnosticCode, at: 5, in: statement)
            try bind(id.uuidString.lowercased(), at: 6, in: statement)
            try stepDone(statement)
            sqlite3_finalize(statement)

            if outcome != .pending, outcome != .running {
                let clear = try prepare(
                    "DELETE FROM operation_cancellation_requests WHERE operation_id=?"
                )
                defer { sqlite3_finalize(clear) }
                try bind(id.uuidString.lowercased(), at: 1, in: clear)
                try stepDone(clear)
            }
        }
    }

    public func updateOperationProgress(id: UUID, completedBytes: Int64, totalBytes: Int64) throws {
        let statement = try prepare(
            "UPDATE operations SET completed_bytes=?, total_bytes=? WHERE id=? AND outcome='running'"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, completedBytes)
        sqlite3_bind_int64(statement, 2, totalBytes)
        try bind(id.uuidString.lowercased(), at: 3, in: statement)
        try stepDone(statement)
    }

    public func pendingOperationCount(mountID: UUID) async throws -> Int {
        let statement = try prepare(
            "SELECT COUNT(*) FROM operations WHERE mount_id=? AND outcome IN ('pending','running','retryableFailure')"
        )
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    @discardableResult
    public func recoverInterruptedOperations(now: Date = .now) throws -> Int {
        try transaction {
            let delete = try prepare("DELETE FROM operation_leases WHERE expires_at <= ?")
            sqlite3_bind_double(delete, 1, now.timeIntervalSince1970)
            try stepDone(delete)
            sqlite3_finalize(delete)

            let statement = try prepare(
                """
                UPDATE operations
                SET outcome='retryableFailure', completed_at=?, diagnostic_code='interrupted'
                WHERE outcome IN ('pending','running')
                  AND NOT EXISTS (
                    SELECT 1 FROM operation_leases
                    WHERE operation_leases.operation_id = operations.id
                      AND operation_leases.expires_at > ?
                  )
                """
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
            try stepDone(statement)
            return Int(sqlite3_changes(database))
        }
    }

    public func recentOperations(limit: Int = 100) throws -> [OperationRecord] {
        let statement = try prepare(
            """
            SELECT id,mount_id,item_id,kind,outcome,completed_bytes,total_bytes,started_at,completed_at,diagnostic_code
            FROM operations ORDER BY started_at DESC LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 1_000))))
        var result: [OperationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = UUID(uuidString: columnString(statement, index: 0)),
                let mountID = UUID(uuidString: columnString(statement, index: 1)),
                let kind = OperationKind(rawValue: columnString(statement, index: 3)),
                let outcome = OperationOutcome(rawValue: columnString(statement, index: 4))
            else { throw SQLiteStoreError(code: SQLITE_CORRUPT, message: "Invalid operation record") }
            result.append(
                OperationRecord(
                    id: id,
                    mountID: mountID,
                    itemID: columnOptionalString(statement, index: 2).flatMap(UUID.init(uuidString:)),
                    kind: kind,
                    outcome: outcome,
                    completedBytes: sqlite3_column_int64(statement, 5),
                    totalBytes: sqlite3_column_int64(statement, 6),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                    completedAt: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                    diagnosticCode: columnOptionalString(statement, index: 9)
                ))
        }
        return result
    }

    @discardableResult
    public func clearCompletedOperationHistory() throws -> Int {
        let statement = try prepare(
            "DELETE FROM operations WHERE outcome IN ('succeeded','failed','cancelled')"
        )
        defer { sqlite3_finalize(statement) }
        try stepDone(statement)
        return Int(sqlite3_changes(database))
    }

    public func operation(id: UUID) throws -> OperationRecord? {
        let statement = try prepare(
            """
            SELECT id,mount_id,item_id,kind,outcome,completed_bytes,total_bytes,started_at,completed_at,diagnostic_code
            FROM operations WHERE id=?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString.lowercased(), at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try readOperation(statement)
    }

    public func activeOperationIDs(mountID: UUID? = nil) throws -> Set<UUID> {
        let predicate = mountID == nil ? "" : " AND mount_id=?"
        let statement = try prepare(
            "SELECT id FROM operations WHERE outcome IN ('pending','running','retryableFailure')\(predicate)"
        )
        defer { sqlite3_finalize(statement) }
        if let mountID { try bind(mountID.uuidString.lowercased(), at: 1, in: statement) }
        var result: Set<UUID> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: columnString(statement, index: 0)) else {
                throw SQLiteStoreError(code: SQLITE_CORRUPT, message: "Invalid operation UUID")
            }
            result.insert(id)
        }
        return result
    }

    public func recordIssue(_ issue: IssueRecord) async throws -> IssueRecord {
        try transaction {
            let existingStatement = try prepare(
                """
                SELECT \(issueColumns) FROM issues
                WHERE resolved_at IS NULL
                  AND diagnostic_code=?
                  AND mount_id IS ?
                  AND item_id IS ?
                  AND remote_object_id IS ?
                  AND remote_path IS ?
                ORDER BY created_at LIMIT 1
                """
            )
            let existing: IssueRecord?
            do {
                try bind(issue.diagnosticCode, at: 1, in: existingStatement)
                try bind(issue.mountID?.uuidString.lowercased(), at: 2, in: existingStatement)
                try bind(issue.itemID?.uuidString.lowercased(), at: 3, in: existingStatement)
                try bind(issue.remoteObjectID, at: 4, in: existingStatement)
                try bind(issue.remotePath, at: 5, in: existingStatement)
                let step = sqlite3_step(existingStatement)
                if step == SQLITE_ROW {
                    existing = try readIssue(existingStatement)
                } else if step == SQLITE_DONE {
                    existing = nil
                } else {
                    throw currentError()
                }
                sqlite3_finalize(existingStatement)
            } catch {
                sqlite3_finalize(existingStatement)
                throw error
            }

            let actions = try encoder.encode(issue.suggestedActions)
            if let existing {
                let statement = try prepare(
                    """
                    UPDATE issues SET
                        kind=?,impact=?,retryable=?,redacted_path_token=?,
                        remote_object_id=?,remote_path=?,default_rename=?,suggested_actions_json=?
                    WHERE id=?
                    """
                )
                defer { sqlite3_finalize(statement) }
                try bind(issue.kind.rawValue, at: 1, in: statement)
                try bind(issue.message, at: 2, in: statement)
                sqlite3_bind_int(statement, 3, issue.retryable ? 1 : 0)
                try bind(issue.redactedPathToken, at: 4, in: statement)
                try bind(issue.remoteObjectID, at: 5, in: statement)
                try bind(issue.remotePath, at: 6, in: statement)
                try bind(issue.defaultRename, at: 7, in: statement)
                try bind(actions, at: 8, in: statement)
                try bind(existing.id.uuidString.lowercased(), at: 9, in: statement)
                try stepDone(statement)
                var updated = issue
                updated.id = existing.id
                updated.createdAt = existing.createdAt
                updated.resolvedAt = nil
                return updated
            }

            let statement = try prepare(
                """
                INSERT INTO issues(
                    id,mount_id,item_id,kind,diagnostic_code,impact,created_at,resolved_at,
                    redacted_path_token,retryable,remote_object_id,remote_path,default_rename,
                    suggested_actions_json
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(issue.id.uuidString.lowercased(), at: 1, in: statement)
            try bind(issue.mountID?.uuidString.lowercased(), at: 2, in: statement)
            try bind(issue.itemID?.uuidString.lowercased(), at: 3, in: statement)
            try bind(issue.kind.rawValue, at: 4, in: statement)
            try bind(issue.diagnosticCode, at: 5, in: statement)
            try bind(issue.message, at: 6, in: statement)
            sqlite3_bind_double(statement, 7, issue.createdAt.timeIntervalSince1970)
            if let resolvedAt = issue.resolvedAt {
                sqlite3_bind_double(statement, 8, resolvedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 8)
            }
            try bind(issue.redactedPathToken, at: 9, in: statement)
            sqlite3_bind_int(statement, 10, issue.retryable ? 1 : 0)
            try bind(issue.remoteObjectID, at: 11, in: statement)
            try bind(issue.remotePath, at: 12, in: statement)
            try bind(issue.defaultRename, at: 13, in: statement)
            try bind(actions, at: 14, in: statement)
            try stepDone(statement)
            guard let inserted = try readIssue(id: issue.id) else {
                throw SQLiteStoreError(code: SQLITE_CORRUPT, message: "Inserted issue was not readable")
            }
            return inserted
        }
    }

    public func issue(id: UUID) async throws -> IssueRecord? {
        try readIssue(id: id)
    }

    public func openIssues(mountID: UUID? = nil, limit: Int = 500) async throws -> [IssueRecord] {
        let predicate = mountID == nil ? "" : " AND mount_id=?"
        let statement = try prepare(
            """
            SELECT \(issueColumns) FROM issues
            WHERE resolved_at IS NULL\(predicate)
            ORDER BY created_at DESC,id LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let mountID {
            try bind(mountID.uuidString.lowercased(), at: index, in: statement)
            index += 1
        }
        sqlite3_bind_int(statement, index, Int32(max(1, min(limit, 1_000))))
        var result: [IssueRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(try readIssue(statement)) }
        return result
    }

    public func resolveIssue(id: UUID, at date: Date = .now) async throws -> Bool {
        try transaction {
            let statement = try prepare(
                "UPDATE issues SET resolved_at=? WHERE id=? AND resolved_at IS NULL"
            )
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            try bind(id.uuidString.lowercased(), at: 2, in: statement)
            try stepDone(statement)
            sqlite3_finalize(statement)
            let resolved = sqlite3_changes(database) == 1
            if resolved {
                let clear = try prepare("DELETE FROM issue_resolution_requests WHERE issue_id=?")
                defer { sqlite3_finalize(clear) }
                try bind(id.uuidString.lowercased(), at: 1, in: clear)
                try stepDone(clear)
            }
            return resolved
        }
    }

    public func requestIssueResolution(
        issueID: UUID,
        action: IssueResolutionAction,
        renameTo: String?,
        at date: Date = .now
    ) async throws -> Bool {
        try transaction {
            guard let issue = try readIssue(id: issueID), issue.resolvedAt == nil,
                issue.suggestedActions.contains(action)
            else { return false }
            if action == .renameDuplicate {
                guard let renameTo, !renameTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return false }
            }
            let effectiveRename = action == .renameDuplicate ? renameTo : nil
            let statement = try prepare(
                """
                INSERT INTO issue_resolution_requests(issue_id,action,rename_to,requested_at)
                VALUES(?,?,?,?)
                ON CONFLICT(issue_id) DO UPDATE SET
                    action=excluded.action,rename_to=excluded.rename_to,requested_at=excluded.requested_at
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(issueID.uuidString.lowercased(), at: 1, in: statement)
            try bind(action.rawValue, at: 2, in: statement)
            try bind(effectiveRename, at: 3, in: statement)
            sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
            try stepDone(statement)
            return true
        }
    }

    public func pendingIssueResolutionRequests(
        mountID: UUID? = nil,
        limit: Int = 100
    ) async throws -> [IssueResolutionRequest] {
        let predicate = mountID == nil ? "" : " AND issues.mount_id=?"
        let statement = try prepare(
            """
            SELECT requests.issue_id,issues.mount_id,requests.action,requests.rename_to,requests.requested_at
            FROM issue_resolution_requests AS requests
            JOIN issues ON issues.id=requests.issue_id
            WHERE issues.resolved_at IS NULL\(predicate)
            ORDER BY requests.requested_at LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let mountID {
            try bind(mountID.uuidString.lowercased(), at: index, in: statement)
            index += 1
        }
        sqlite3_bind_int(statement, index, Int32(max(1, min(limit, 500))))
        var result: [IssueResolutionRequest] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let issueID = UUID(uuidString: columnString(statement, index: 0)),
                let action = IssueResolutionAction(rawValue: columnString(statement, index: 2))
            else { throw SQLiteStoreError(code: SQLITE_CORRUPT, message: "Invalid issue resolution request") }
            result.append(
                IssueResolutionRequest(
                    issueID: issueID,
                    mountID: columnOptionalString(statement, index: 1).flatMap(UUID.init(uuidString:)),
                    action: action,
                    renameTo: columnOptionalString(statement, index: 3),
                    requestedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                ))
        }
        return result
    }

    public func clearIssueResolutionRequest(issueID: UUID) async throws {
        let statement = try prepare("DELETE FROM issue_resolution_requests WHERE issue_id=?")
        defer { sqlite3_finalize(statement) }
        try bind(issueID.uuidString.lowercased(), at: 1, in: statement)
        try stepDone(statement)
    }

    public func requestOperationCancellation(id: UUID, at date: Date = .now) async throws -> Bool {
        let statement = try prepare(
            """
            INSERT INTO operation_cancellation_requests(operation_id,requested_at)
            SELECT id,? FROM operations
            WHERE id=? AND outcome IN ('pending','running','retryableFailure')
            ON CONFLICT(operation_id) DO UPDATE SET requested_at=excluded.requested_at
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        try bind(id.uuidString.lowercased(), at: 2, in: statement)
        try stepDone(statement)
        return sqlite3_changes(database) == 1
    }

    public func isOperationCancellationRequested(id: UUID) async throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM operation_cancellation_requests WHERE operation_id=? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString.lowercased(), at: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    public func clearOperationCancellationRequest(id: UUID) async throws {
        let statement = try prepare(
            "DELETE FROM operation_cancellation_requests WHERE operation_id=?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString.lowercased(), at: 1, in: statement)
        try stepDone(statement)
    }

    public func item(id: UUID, mountID: UUID) async throws -> StoredItem? {
        let statement = try prepare("SELECT \(itemColumns) FROM items WHERE mount_id = ? AND id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        try bind(id.uuidString.lowercased(), at: 2, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? try readItem(statement) : nil
    }

    public func item(remoteID: String, mountID: UUID) async throws -> StoredItem? {
        let statement = try prepare("SELECT \(itemColumns) FROM items WHERE mount_id = ? AND remote_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        try bind(remoteID, at: 2, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? try readItem(statement) : nil
    }

    public func item(remotePath: String, mountID: UUID) async throws -> StoredItem? {
        let statement = try prepare("SELECT \(itemColumns) FROM items WHERE mount_id = ? AND remote_path = ?")
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        try bind(remotePath, at: 2, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? try readItem(statement) : nil
    }

    public func children(parentID: UUID?, mountID: UUID) async throws -> [StoredItem] {
        try readChildren(parentID: parentID, mountID: mountID)
            .sorted {
                let order = $0.displayName.localizedStandardCompare($1.displayName)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
    }

    public func workingSet(mountID: UUID, accessedAfter: Date) async throws -> [StoredItem] {
        let statement = try prepare(
            """
            SELECT \(itemColumns)
            FROM items
            WHERE mount_id = ?
              AND (
                materialized = 1
                OR pinned = 1
                OR last_accessed_at >= ?
                OR EXISTS (
                    SELECT 1 FROM operations
                    WHERE operations.mount_id = items.mount_id
                      AND operations.item_id = items.id
                      AND operations.outcome IN ('pending','running','retryableFailure')
                )
              )
            ORDER BY COALESCE(last_accessed_at, 0) DESC, display_name, id
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        sqlite3_bind_double(statement, 2, accessedAfter.timeIntervalSince1970)
        var result: [StoredItem] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(try readItem(statement)) }
        return result
    }

    public func reconcile(
        mountID: UUID,
        parentID: UUID?,
        remoteItems: [RemoteItem],
        enumerationOwner: String?
    ) async throws -> ChangeBatch {
        try transaction {
            if let enumerationOwner {
                guard
                    try hasActiveEnumerationLease(
                        mountID: mountID,
                        containerID: parentID,
                        owner: enumerationOwner
                    ), try !hasActiveRemovalGate(mountID: mountID)
                else {
                    throw ItemRepositoryError.enumerationLeaseLost(parentID)
                }
            }
            let existing = try readChildren(parentID: parentID, mountID: mountID)
            let generation = (existing.map(\.listGeneration).max() ?? 0) + 1
            let pendingItemIDs = try pendingItemIDs(mountID: mountID)
            var existingByRemoteID: [String: StoredItem] = [:]
            var existingByPath: [String: StoredItem] = [:]
            for item in existing.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                if let remoteID = item.remoteID, existingByRemoteID[remoteID] == nil {
                    existingByRemoteID[remoteID] = item
                }
                if existingByPath[item.remotePath] == nil {
                    existingByPath[item.remotePath] = item
                }
            }
            let globalByRemoteID = try readItems(
                remoteIDs: Set(remoteItems.compactMap(\.objectID)),
                mountID: mountID
            )
            var unmatched = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            var created: [StoredItem] = []
            var updated: [StoredItem] = []

            for remote in remoteItems {
                let prior =
                    remote.objectID.flatMap { existingByRemoteID[$0] ?? globalByRemoteID[$0] }
                    ?? existingByPath[remote.path]
                let item = makeStoredItem(
                    remote,
                    prior: prior,
                    parentID: parentID,
                    mountID: mountID,
                    generation: generation
                )
                unmatched.removeValue(forKey: item.id)
                try upsert(item)
                if prior == nil {
                    created.append(item)
                    try appendJournal(
                        mountID: mountID,
                        item: item,
                        kind: .create,
                        generation: generation,
                        workingSet: isInWorkingSet(item, pendingItemIDs: pendingItemIDs, now: .now)
                    )
                } else if !observablyEqual(prior!, item) {
                    updated.append(item)
                    try appendJournal(
                        mountID: mountID,
                        item: item,
                        kind: .update,
                        generation: generation,
                        workingSet: isInWorkingSet(item, pendingItemIDs: pendingItemIDs, now: .now)
                    )
                }
            }

            var deleted: [StoredItem] = []
            var deletedIDs: Set<UUID> = []
            for missing in unmatched.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                guard !deletedIDs.contains(missing.id) else { continue }
                let subtree = try readSubtree(itemID: missing.id, mountID: mountID)
                for item in subtree where deletedIDs.insert(item.id).inserted {
                    deleted.append(item)
                    try appendJournal(
                        mountID: mountID,
                        item: item,
                        kind: .delete,
                        generation: generation,
                        workingSet: isInWorkingSet(item, pendingItemIDs: pendingItemIDs, now: .now)
                    )
                }
                try deleteSubtree(itemID: missing.id, mountID: mountID)
            }
            return ChangeBatch(generation: generation, created: created, updated: updated, deleted: deleted)
        }
    }

    public func update(
        itemID: UUID,
        mountID: UUID,
        parentID: UUID?,
        remoteItem: RemoteItem
    ) async throws -> StoredItem {
        try transaction {
            guard let prior = try readItem(id: itemID, mountID: mountID) else {
                throw ItemRepositoryError.itemNotFound(itemID)
            }
            let item = makeStoredItem(
                remoteItem,
                prior: prior,
                parentID: parentID,
                mountID: mountID,
                generation: prior.listGeneration + 1
            )
            try upsert(item)
            if !observablyEqual(prior, item) {
                try appendJournal(
                    mountID: mountID,
                    item: item,
                    kind: .update,
                    generation: item.listGeneration,
                    workingSet: try isInWorkingSet(item, now: .now)
                )
            }
            return item
        }
    }

    @discardableResult
    public func deleteItem(itemID: UUID, mountID: UUID) async throws -> [StoredItem] {
        try transaction {
            let subtree = try readSubtree(itemID: itemID, mountID: mountID)
            guard !subtree.isEmpty else { return [] }
            let generation = (subtree.map(\.listGeneration).max() ?? 0) + 1
            for item in subtree {
                try appendJournal(
                    mountID: mountID,
                    item: item,
                    kind: .delete,
                    generation: generation,
                    workingSet: try isInWorkingSet(item, now: .now)
                )
            }
            try deleteSubtree(itemID: itemID, mountID: mountID)
            return subtree
        }
    }

    public func markAccessed(itemID: UUID, mountID: UUID, at date: Date = .now) async throws {
        try mutateUsage(itemID: itemID, mountID: mountID, materialized: nil, pinned: nil, accessedAt: date)
    }

    public func setMaterialized(_ materialized: Bool, itemID: UUID, mountID: UUID) async throws {
        try mutateUsage(itemID: itemID, mountID: mountID, materialized: materialized, pinned: nil, accessedAt: nil)
    }

    public func setPinned(_ pinned: Bool, itemID: UUID, mountID: UUID) async throws {
        try mutateUsage(itemID: itemID, mountID: mountID, materialized: nil, pinned: pinned, accessedAt: nil)
    }

    public func changes(
        mountID: UUID,
        containerID: UUID?,
        after anchor: Int64,
        limit: Int = 500
    ) async throws -> JournalPage {
        let page = try journalPage(
            mountID: mountID,
            scope: "container:\(containerKey(containerID))",
            predicate: "container_visible = 1 AND container_id = ?",
            predicateValue: containerKey(containerID),
            after: anchor,
            limit: limit
        )
        _ = try? compactJournal(retainingAfter: .now.addingTimeInterval(-30 * 24 * 60 * 60))
        return page
    }

    public func workingSetChanges(
        mountID: UUID,
        after anchor: Int64,
        limit: Int = 500
    ) async throws -> JournalPage {
        let page = try journalPage(
            mountID: mountID,
            scope: "working-set",
            predicate: "working_set = 1",
            predicateValue: nil,
            after: anchor,
            limit: limit
        )
        _ = try? compactJournal(retainingAfter: .now.addingTimeInterval(-30 * 24 * 60 * 60))
        return page
    }

    public func currentSyncAnchor(mountID: UUID) async throws -> Int64 {
        try maximumJournalSequence(mountID: mountID)
    }

    public func acquireEnumerationLease(
        mountID: UUID,
        containerID: UUID?,
        owner: String,
        ttl: TimeInterval = 30
    ) async throws -> Bool {
        try transaction {
            guard try !hasActiveRemovalGate(mountID: mountID) else { return false }
            let now = Date.now.timeIntervalSince1970
            let key = containerKey(containerID)
            let statement = try prepare(
                """
                INSERT INTO enumeration_leases(mount_id,container_id,owner,expires_at)
                VALUES(?,?,?,?)
                ON CONFLICT(mount_id,container_id) DO UPDATE SET
                    owner=excluded.owner, expires_at=excluded.expires_at
                WHERE enumeration_leases.owner=excluded.owner OR enumeration_leases.expires_at <= ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
            try bind(key, at: 2, in: statement)
            try bind(owner, at: 3, in: statement)
            sqlite3_bind_double(statement, 4, now + max(1, ttl))
            sqlite3_bind_double(statement, 5, now)
            try stepDone(statement)
            return sqlite3_changes(database) == 1
        }
    }

    public func renewEnumerationLease(
        mountID: UUID,
        containerID: UUID?,
        owner: String,
        ttl: TimeInterval = 30
    ) async throws -> Bool {
        let statement = try prepare(
            "UPDATE enumeration_leases SET expires_at=? WHERE mount_id=? AND container_id=? AND owner=? AND expires_at>?"
        )
        defer { sqlite3_finalize(statement) }
        let now = Date.now.timeIntervalSince1970
        sqlite3_bind_double(statement, 1, now + max(1, ttl))
        try bind(mountID.uuidString.lowercased(), at: 2, in: statement)
        try bind(containerKey(containerID), at: 3, in: statement)
        try bind(owner, at: 4, in: statement)
        sqlite3_bind_double(statement, 5, now)
        try stepDone(statement)
        return sqlite3_changes(database) == 1
    }

    public func releaseEnumerationLease(
        mountID: UUID,
        containerID: UUID?,
        owner: String
    ) async throws {
        let statement = try prepare(
            "DELETE FROM enumeration_leases WHERE mount_id=? AND container_id=? AND owner=?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        try bind(containerKey(containerID), at: 2, in: statement)
        try bind(owner, at: 3, in: statement)
        try stepDone(statement)
    }

    public func acquireOperationLease(
        operationID: UUID,
        mountID: UUID,
        owner: String,
        ttl: TimeInterval = 30
    ) async throws -> Bool {
        try transaction {
            guard try !hasActiveRemovalGate(mountID: mountID) else { return false }
            let now = Date.now.timeIntervalSince1970
            let statement = try prepare(
                """
                INSERT INTO operation_leases(operation_id,mount_id,owner,expires_at)
                VALUES(?,?,?,?)
                ON CONFLICT(operation_id) DO UPDATE SET
                    mount_id=excluded.mount_id,owner=excluded.owner,expires_at=excluded.expires_at
                WHERE operation_leases.owner=excluded.owner OR operation_leases.expires_at<=?
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(operationID.uuidString.lowercased(), at: 1, in: statement)
            try bind(mountID.uuidString.lowercased(), at: 2, in: statement)
            try bind(owner, at: 3, in: statement)
            sqlite3_bind_double(statement, 4, now + max(1, ttl))
            sqlite3_bind_double(statement, 5, now)
            try stepDone(statement)
            return sqlite3_changes(database) == 1
        }
    }

    public func renewOperationLease(
        operationID: UUID,
        owner: String,
        ttl: TimeInterval = 30
    ) async throws -> Bool {
        let statement = try prepare(
            "UPDATE operation_leases SET expires_at=? WHERE operation_id=? AND owner=? AND expires_at>?"
        )
        defer { sqlite3_finalize(statement) }
        let now = Date.now.timeIntervalSince1970
        sqlite3_bind_double(statement, 1, now + max(1, ttl))
        try bind(operationID.uuidString.lowercased(), at: 2, in: statement)
        try bind(owner, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, now)
        try stepDone(statement)
        return sqlite3_changes(database) == 1
    }

    public func releaseOperationLease(operationID: UUID, owner: String) async throws {
        let statement = try prepare("DELETE FROM operation_leases WHERE operation_id=? AND owner=?")
        defer { sqlite3_finalize(statement) }
        try bind(operationID.uuidString.lowercased(), at: 1, in: statement)
        try bind(owner, at: 2, in: statement)
        try stepDone(statement)
    }

    public func acquireTransferLease(
        operationID: UUID,
        mountID: UUID,
        owner: String,
        limit: Int,
        ttl: TimeInterval = 30
    ) throws -> Bool {
        try transaction {
            guard try !hasActiveRemovalGate(mountID: mountID) else { return false }
            let now = Date.now.timeIntervalSince1970
            let delete = try prepare("DELETE FROM transfer_leases WHERE expires_at <= ?")
            sqlite3_bind_double(delete, 1, now)
            try stepDone(delete)
            sqlite3_finalize(delete)

            let count = try scalarInt("SELECT COUNT(*) FROM transfer_leases")
            guard count < limit else { return false }
            let insert = try prepare(
                "INSERT INTO transfer_leases(operation_id, mount_id, owner, expires_at) VALUES(?, ?, ?, ?)"
            )
            defer { sqlite3_finalize(insert) }
            try bind(operationID.uuidString.lowercased(), at: 1, in: insert)
            try bind(mountID.uuidString.lowercased(), at: 2, in: insert)
            try bind(owner, at: 3, in: insert)
            sqlite3_bind_double(insert, 4, now + ttl)
            try stepDone(insert)
            return true
        }
    }

    public func renewTransferLease(operationID: UUID, owner: String, ttl: TimeInterval = 30) throws -> Bool {
        let statement = try prepare("UPDATE transfer_leases SET expires_at = ? WHERE operation_id = ? AND owner = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date.now.timeIntervalSince1970 + ttl)
        try bind(operationID.uuidString.lowercased(), at: 2, in: statement)
        try bind(owner, at: 3, in: statement)
        try stepDone(statement)
        return sqlite3_changes(database) == 1
    }

    public func releaseTransferLease(operationID: UUID, owner: String) throws {
        let statement = try prepare("DELETE FROM transfer_leases WHERE operation_id = ? AND owner = ?")
        defer { sqlite3_finalize(statement) }
        try bind(operationID.uuidString.lowercased(), at: 1, in: statement)
        try bind(owner, at: 2, in: statement)
        try stepDone(statement)
    }

    public func acquireRemovalAdmission(
        mountID: UUID,
        owner: String,
        ttl: TimeInterval = 120
    ) async throws -> Int? {
        try transaction {
            let now = Date.now.timeIntervalSince1970
            let cleanup = try prepare("DELETE FROM removal_gates WHERE expires_at <= ?")
            sqlite3_bind_double(cleanup, 1, now)
            try stepDone(cleanup)
            sqlite3_finalize(cleanup)

            let leaseCleanup = try prepare("DELETE FROM enumeration_leases WHERE expires_at <= ?")
            sqlite3_bind_double(leaseCleanup, 1, now)
            try stepDone(leaseCleanup)
            sqlite3_finalize(leaseCleanup)

            let insert = try prepare(
                "INSERT OR IGNORE INTO removal_gates(mount_id,owner,expires_at) VALUES(?,?,?)"
            )
            try bind(mountID.uuidString.lowercased(), at: 1, in: insert)
            try bind(owner, at: 2, in: insert)
            sqlite3_bind_double(insert, 3, now + max(1, ttl))
            try stepDone(insert)
            sqlite3_finalize(insert)
            guard sqlite3_changes(database) == 1 else { return nil }
            if try hasActiveEnumerationLease(mountID: mountID, now: Date(timeIntervalSince1970: now)) {
                let release = try prepare("DELETE FROM removal_gates WHERE mount_id=? AND owner=?")
                try bind(mountID.uuidString.lowercased(), at: 1, in: release)
                try bind(owner, at: 2, in: release)
                try stepDone(release)
                sqlite3_finalize(release)
                return nil
            }
            return try pendingOperationCountInTransaction(mountID: mountID)
        }
    }

    public func renewRemovalAdmission(
        mountID: UUID,
        owner: String,
        ttl: TimeInterval = 120
    ) async throws -> Bool {
        let statement = try prepare(
            "UPDATE removal_gates SET expires_at=? WHERE mount_id=? AND owner=? AND expires_at>?"
        )
        defer { sqlite3_finalize(statement) }
        let now = Date.now.timeIntervalSince1970
        sqlite3_bind_double(statement, 1, now + max(1, ttl))
        try bind(mountID.uuidString.lowercased(), at: 2, in: statement)
        try bind(owner, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, now)
        try stepDone(statement)
        return sqlite3_changes(database) == 1
    }

    public func releaseRemovalAdmission(mountID: UUID, owner: String) async throws {
        let statement = try prepare("DELETE FROM removal_gates WHERE mount_id=? AND owner=?")
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        try bind(owner, at: 2, in: statement)
        try stepDone(statement)
    }

    @discardableResult
    public func compactJournal(
        retainingAfter cutoff: Date,
        maximumRows: Int = 500,
        now: Date = .now
    ) throws -> Int {
        try transaction {
            let cleanup = try prepare("DELETE FROM active_sync_anchors WHERE expires_at <= ?")
            sqlite3_bind_double(cleanup, 1, now.timeIntervalSince1970)
            try stepDone(cleanup)
            sqlite3_finalize(cleanup)

            let active =
                try scalarOptionalInt64(
                    "SELECT MIN(anchor) FROM active_sync_anchors WHERE expires_at > \(now.timeIntervalSince1970)"
                ) ?? Int64.max
            let candidate = try prepare(
                """
                SELECT MAX(sequence) FROM (
                    SELECT sequence FROM change_journal
                    WHERE created_at < ? AND sequence <= ?
                    ORDER BY sequence LIMIT ?
                )
                """
            )
            sqlite3_bind_double(candidate, 1, cutoff.timeIntervalSince1970)
            sqlite3_bind_int64(candidate, 2, active)
            sqlite3_bind_int(candidate, 3, Int32(max(1, min(maximumRows, 5_000))))
            guard sqlite3_step(candidate) == SQLITE_ROW else {
                sqlite3_finalize(candidate)
                throw currentError()
            }
            let maximum =
                sqlite3_column_type(candidate, 0) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(candidate, 0)
            sqlite3_finalize(candidate)
            guard let maximum else { return 0 }

            let retention = try prepare(
                """
                INSERT INTO journal_retention(mount_id,floor_sequence)
                SELECT mount_id, MAX(sequence) FROM change_journal
                WHERE created_at < ? AND sequence <= ?
                GROUP BY mount_id
                ON CONFLICT(mount_id) DO UPDATE SET
                    floor_sequence=MAX(journal_retention.floor_sequence, excluded.floor_sequence)
                """
            )
            sqlite3_bind_double(retention, 1, cutoff.timeIntervalSince1970)
            sqlite3_bind_int64(retention, 2, maximum)
            try stepDone(retention)
            sqlite3_finalize(retention)

            let deletion = try prepare("DELETE FROM change_journal WHERE created_at < ? AND sequence <= ?")
            sqlite3_bind_double(deletion, 1, cutoff.timeIntervalSince1970)
            sqlite3_bind_int64(deletion, 2, maximum)
            try stepDone(deletion)
            sqlite3_finalize(deletion)
            let deleted = Int(sqlite3_changes(database))
            return deleted
        }
    }

    public func integrityCheck() throws -> String {
        let statement = try prepare("PRAGMA integrity_check")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        return columnString(statement, index: 0)
    }

    public func userVersion() throws -> Int32 { Int32(try scalarInt("PRAGMA user_version")) }

    private func migrate() throws {
        let current = try scalarInt("PRAGMA user_version")
        for migration in MountliMigrations.all where migration.version > current {
            try transaction {
                for statement in migration.statements { try execute(statement) }
                try execute("PRAGMA user_version=\(migration.version)")
            }
        }
    }

    private func makeStoredItem(
        _ remote: RemoteItem,
        prior: StoredItem?,
        parentID: UUID?,
        mountID: UUID,
        generation: Int64
    ) -> StoredItem {
        let id = prior?.id ?? UUID()
        let metadataSource = Data(
            "\(id.uuidString)\u{0}\(parentID?.uuidString ?? "")\u{0}\(remote.name)\u{0}\(remote.isDirectory)\u{0}\(remote.size)\u{0}\(remote.modificationDate.timeIntervalSince1970)"
                .utf8)
        return StoredItem(
            id: id,
            mountID: mountID,
            parentID: parentID,
            remoteID: remote.objectID,
            remotePath: remote.path,
            displayName: remote.name,
            isDirectory: remote.isDirectory,
            size: remote.size,
            modificationDate: remote.modificationDate,
            contentVersion: StoredItemVersion.contentVersion(for: remote),
            metadataVersion: Data(SHA256.hash(data: metadataSource)),
            listGeneration: generation,
            materialized: prior?.materialized ?? false,
            pinned: prior?.pinned ?? false,
            lastAccessedAt: prior?.lastAccessedAt
        )
    }

    private func upsert(_ item: StoredItem) throws {
        let statement = try prepare(
            """
            INSERT INTO items(id,mount_id,parent_id,remote_id,remote_path,display_name,is_directory,size,modification_date,content_version,metadata_version,list_generation,materialized,pinned,last_accessed_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET parent_id=excluded.parent_id,remote_id=excluded.remote_id,remote_path=excluded.remote_path,display_name=excluded.display_name,is_directory=excluded.is_directory,size=excluded.size,modification_date=excluded.modification_date,content_version=excluded.content_version,metadata_version=excluded.metadata_version,list_generation=excluded.list_generation,materialized=excluded.materialized,pinned=excluded.pinned,last_accessed_at=excluded.last_accessed_at
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(item.id.uuidString.lowercased(), at: 1, in: statement)
        try bind(item.mountID.uuidString.lowercased(), at: 2, in: statement)
        try bind(item.parentID?.uuidString.lowercased(), at: 3, in: statement)
        try bind(item.remoteID, at: 4, in: statement)
        try bind(item.remotePath, at: 5, in: statement)
        try bind(item.displayName, at: 6, in: statement)
        sqlite3_bind_int(statement, 7, item.isDirectory ? 1 : 0)
        sqlite3_bind_int64(statement, 8, item.size)
        sqlite3_bind_double(statement, 9, item.modificationDate.timeIntervalSince1970)
        try bind(item.contentVersion, at: 10, in: statement)
        try bind(item.metadataVersion, at: 11, in: statement)
        sqlite3_bind_int64(statement, 12, item.listGeneration)
        sqlite3_bind_int(statement, 13, item.materialized ? 1 : 0)
        sqlite3_bind_int(statement, 14, item.pinned ? 1 : 0)
        if let date = item.lastAccessedAt { sqlite3_bind_double(statement, 15, date.timeIntervalSince1970) } else { sqlite3_bind_null(statement, 15) }
        try stepDone(statement)
    }

    private func appendJournal(
        mountID: UUID,
        item: StoredItem,
        kind: JournalChangeKind,
        generation: Int64,
        containerVisible: Bool = true,
        workingSet: Bool
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO change_journal(
                mount_id,item_id,change_kind,generation,created_at,container_id,container_visible,working_set
            ) VALUES(?,?,?,?,?,?,?,?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        try bind(item.id.uuidString.lowercased(), at: 2, in: statement)
        try bind(kind.rawValue, at: 3, in: statement)
        sqlite3_bind_int64(statement, 4, generation)
        sqlite3_bind_double(statement, 5, Date.now.timeIntervalSince1970)
        try bind(containerKey(item.parentID), at: 6, in: statement)
        sqlite3_bind_int(statement, 7, containerVisible ? 1 : 0)
        sqlite3_bind_int(statement, 8, workingSet ? 1 : 0)
        try stepDone(statement)
    }

    private func readChildren(parentID: UUID?, mountID: UUID) throws -> [StoredItem] {
        let comparison = parentID == nil ? "parent_id IS NULL" : "parent_id = ?"
        let statement = try prepare("SELECT \(itemColumns) FROM items WHERE mount_id = ? AND \(comparison)")
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        if let parentID { try bind(parentID.uuidString.lowercased(), at: 2, in: statement) }
        var items: [StoredItem] = []
        while sqlite3_step(statement) == SQLITE_ROW { items.append(try readItem(statement)) }
        return items
    }

    private func readItem(id: UUID, mountID: UUID) throws -> StoredItem? {
        let statement = try prepare("SELECT \(itemColumns) FROM items WHERE mount_id=? AND id=?")
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        try bind(id.uuidString.lowercased(), at: 2, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? try readItem(statement) : nil
    }

    private func readItems(remoteIDs: Set<String>, mountID: UUID) throws -> [String: StoredItem] {
        let remoteIDs = remoteIDs.sorted()
        guard !remoteIDs.isEmpty else { return [:] }
        var result: [String: StoredItem] = [:]
        for offset in stride(from: 0, to: remoteIDs.count, by: 400) {
            let batch = remoteIDs[offset..<min(offset + 400, remoteIDs.count)]
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let statement = try prepare(
                "SELECT \(itemColumns) FROM items WHERE mount_id=? AND remote_id IN (\(placeholders))"
            )
            do {
                try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
                for (index, remoteID) in batch.enumerated() {
                    try bind(remoteID, at: Int32(index + 2), in: statement)
                }
                var step = sqlite3_step(statement)
                while step == SQLITE_ROW {
                    let item = try readItem(statement)
                    if let remoteID = item.remoteID { result[remoteID] = item }
                    step = sqlite3_step(statement)
                }
                guard step == SQLITE_DONE else { throw currentError() }
                sqlite3_finalize(statement)
            } catch {
                sqlite3_finalize(statement)
                throw error
            }
        }
        return result
    }

    private func readSubtree(itemID: UUID, mountID: UUID) throws -> [StoredItem] {
        let statement = try prepare(
            """
            WITH RECURSIVE subtree(id, depth) AS (
                SELECT id, 0 FROM items WHERE mount_id=? AND id=?
                UNION ALL
                SELECT child.id, subtree.depth + 1
                FROM items AS child
                JOIN subtree ON child.parent_id=subtree.id
                WHERE child.mount_id=?
            )
            SELECT \(qualifiedItemColumns)
            FROM items JOIN subtree ON items.id=subtree.id
            WHERE items.mount_id=?
            ORDER BY subtree.depth DESC, items.id
            """
        )
        defer { sqlite3_finalize(statement) }
        let mount = mountID.uuidString.lowercased()
        try bind(mount, at: 1, in: statement)
        try bind(itemID.uuidString.lowercased(), at: 2, in: statement)
        try bind(mount, at: 3, in: statement)
        try bind(mount, at: 4, in: statement)
        var result: [StoredItem] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(try readItem(statement)) }
        return result
    }

    private func deleteSubtree(itemID: UUID, mountID: UUID) throws {
        let statement = try prepare(
            """
            WITH RECURSIVE subtree(id) AS (
                SELECT id FROM items WHERE mount_id=? AND id=?
                UNION ALL
                SELECT child.id FROM items AS child
                JOIN subtree ON child.parent_id=subtree.id
                WHERE child.mount_id=?
            )
            DELETE FROM items WHERE mount_id=? AND id IN (SELECT id FROM subtree)
            """
        )
        defer { sqlite3_finalize(statement) }
        let mount = mountID.uuidString.lowercased()
        try bind(mount, at: 1, in: statement)
        try bind(itemID.uuidString.lowercased(), at: 2, in: statement)
        try bind(mount, at: 3, in: statement)
        try bind(mount, at: 4, in: statement)
        try stepDone(statement)
    }

    private func observablyEqual(_ lhs: StoredItem, _ rhs: StoredItem) -> Bool {
        lhs.id == rhs.id
            && lhs.mountID == rhs.mountID
            && lhs.parentID == rhs.parentID
            && lhs.remoteID == rhs.remoteID
            && lhs.remotePath == rhs.remotePath
            && lhs.displayName == rhs.displayName
            && lhs.isDirectory == rhs.isDirectory
            && lhs.size == rhs.size
            && lhs.modificationDate == rhs.modificationDate
            && lhs.contentVersion == rhs.contentVersion
            && lhs.metadataVersion == rhs.metadataVersion
    }

    private func isInWorkingSet(
        _ item: StoredItem,
        pendingItemIDs: Set<UUID>,
        now: Date
    ) -> Bool {
        item.materialized
            || item.pinned
            || pendingItemIDs.contains(item.id)
            || (item.lastAccessedAt.map {
                $0 >= now.addingTimeInterval(-30 * 24 * 60 * 60)
            } ?? false)
    }

    private func pendingItemIDs(mountID: UUID) throws -> Set<UUID> {
        let statement = try prepare(
            """
            SELECT DISTINCT item_id FROM operations
            WHERE mount_id=? AND item_id IS NOT NULL
              AND outcome IN ('pending','running','retryableFailure')
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        var result: Set<UUID> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: columnString(statement, index: 0)) else {
                throw SQLiteStoreError(code: SQLITE_CORRUPT, message: "Invalid pending item UUID")
            }
            result.insert(id)
        }
        return result
    }

    private func isInWorkingSet(_ item: StoredItem, now: Date) throws -> Bool {
        if item.materialized || item.pinned
            || (item.lastAccessedAt.map { $0 >= now.addingTimeInterval(-30 * 24 * 60 * 60) } ?? false)
        {
            return true
        }
        let statement = try prepare(
            """
            SELECT 1 FROM operations
            WHERE mount_id=? AND item_id=? AND outcome IN ('pending','running','retryableFailure')
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(item.mountID.uuidString.lowercased(), at: 1, in: statement)
        try bind(item.id.uuidString.lowercased(), at: 2, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func mutateUsage(
        itemID: UUID,
        mountID: UUID,
        materialized: Bool?,
        pinned: Bool?,
        accessedAt: Date?
    ) throws {
        try transaction {
            guard var item = try readItem(id: itemID, mountID: mountID) else {
                throw ItemRepositoryError.itemNotFound(itemID)
            }
            let before = try isInWorkingSet(item, now: .now)
            if let materialized { item.materialized = materialized }
            if let pinned { item.pinned = pinned }
            if let accessedAt { item.lastAccessedAt = accessedAt }
            try upsert(item)
            let after = try isInWorkingSet(item, now: .now)
            if before != after {
                try appendJournal(
                    mountID: mountID,
                    item: item,
                    kind: after ? .create : .delete,
                    generation: item.listGeneration,
                    containerVisible: false,
                    workingSet: true
                )
            }
        }
    }

    private func journalPage(
        mountID: UUID,
        scope: String,
        predicate: String,
        predicateValue: String?,
        after anchor: Int64,
        limit: Int
    ) throws -> JournalPage {
        try transaction {
            let floorStatement = try prepare(
                "SELECT floor_sequence FROM journal_retention WHERE mount_id=?"
            )
            try bind(mountID.uuidString.lowercased(), at: 1, in: floorStatement)
            let floor =
                sqlite3_step(floorStatement) == SQLITE_ROW
                ? sqlite3_column_int64(floorStatement, 0)
                : 0
            sqlite3_finalize(floorStatement)
            guard anchor >= floor else {
                throw ItemRepositoryError.syncAnchorExpired(retainedFloor: floor)
            }

            let maximum = try maximumJournalSequence(mountID: mountID)
            let statement = try prepare(
                """
                SELECT sequence,item_id,container_id,change_kind
                FROM change_journal
                WHERE mount_id=? AND sequence>? AND \(predicate)
                ORDER BY sequence LIMIT ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
            sqlite3_bind_int64(statement, 2, anchor)
            var nextIndex: Int32 = 3
            if let predicateValue {
                try bind(predicateValue, at: nextIndex, in: statement)
                nextIndex += 1
            }
            let boundedLimit = min(max(limit, 1), 500)
            sqlite3_bind_int(statement, nextIndex, Int32(boundedLimit))
            var changes: [JournalChange] = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                guard
                    let itemID = UUID(uuidString: columnString(statement, index: 1)),
                    let kind = JournalChangeKind(rawValue: columnString(statement, index: 3))
                else { throw SQLiteStoreError(code: SQLITE_CORRUPT, message: "Invalid journal record") }
                let key = columnString(statement, index: 2)
                changes.append(
                    JournalChange(
                        sequence: sqlite3_column_int64(statement, 0),
                        itemID: itemID,
                        containerID: key == "__root__" ? nil : UUID(uuidString: key),
                        kind: kind
                    ))
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else { throw currentError() }
            let nextAnchor = changes.count == boundedLimit ? changes.last!.sequence : maximum
            try registerActiveAnchor(mountID: mountID, scope: scope, anchor: nextAnchor)
            return JournalPage(changes: changes, nextAnchor: nextAnchor)
        }
    }

    private func registerActiveAnchor(mountID: UUID, scope: String, anchor: Int64) throws {
        let statement = try prepare(
            """
            INSERT INTO active_sync_anchors(mount_id,scope,anchor,expires_at) VALUES(?,?,?,?)
            ON CONFLICT(mount_id,scope,anchor) DO UPDATE SET expires_at=excluded.expires_at
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        try bind(scope, at: 2, in: statement)
        sqlite3_bind_int64(statement, 3, anchor)
        sqlite3_bind_double(statement, 4, Date.now.addingTimeInterval(300).timeIntervalSince1970)
        try stepDone(statement)
    }

    private func maximumJournalSequence(mountID: UUID) throws -> Int64 {
        let mount = mountID.uuidString.lowercased()
        let statement = try prepare(
            "SELECT COALESCE(MAX(sequence),0) FROM change_journal WHERE mount_id=?"
        )
        try bind(mount, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            throw currentError()
        }
        let journalMaximum = sqlite3_column_int64(statement, 0)
        sqlite3_finalize(statement)

        let retention = try prepare(
            "SELECT floor_sequence FROM journal_retention WHERE mount_id=?"
        )
        defer { sqlite3_finalize(retention) }
        try bind(mount, at: 1, in: retention)
        let floor =
            sqlite3_step(retention) == SQLITE_ROW
            ? sqlite3_column_int64(retention, 0)
            : 0
        return max(journalMaximum, floor)
    }

    private func containerKey(_ containerID: UUID?) -> String {
        containerID?.uuidString.lowercased() ?? "__root__"
    }

    private func hasActiveRemovalGate(mountID: UUID, now: Date = .now) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM removal_gates WHERE mount_id=? AND expires_at>? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func hasActiveEnumerationLease(mountID: UUID, now: Date = .now) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM enumeration_leases WHERE mount_id=? AND expires_at>? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func hasActiveEnumerationLease(
        mountID: UUID,
        containerID: UUID?,
        owner: String,
        now: Date = .now
    ) throws -> Bool {
        let statement = try prepare(
            """
            SELECT 1 FROM enumeration_leases
            WHERE mount_id=? AND container_id=? AND owner=? AND expires_at>?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        try bind(containerKey(containerID), at: 2, in: statement)
        try bind(owner, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func pendingOperationCountInTransaction(mountID: UUID) throws -> Int {
        let statement = try prepare(
            "SELECT COUNT(*) FROM operations WHERE mount_id=? AND outcome IN ('pending','running','retryableFailure')"
        )
        defer { sqlite3_finalize(statement) }
        try bind(mountID.uuidString.lowercased(), at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private var itemColumns: String {
        "id,mount_id,parent_id,remote_id,remote_path,display_name,is_directory,size,modification_date,content_version,metadata_version,list_generation,materialized,pinned,last_accessed_at"
    }

    private var issueColumns: String {
        "id,mount_id,item_id,kind,diagnostic_code,impact,created_at,resolved_at,redacted_path_token,retryable,remote_object_id,remote_path,default_rename,suggested_actions_json"
    }

    private var qualifiedItemColumns: String {
        "items.id,items.mount_id,items.parent_id,items.remote_id,items.remote_path,items.display_name,items.is_directory,items.size,items.modification_date,items.content_version,items.metadata_version,items.list_generation,items.materialized,items.pinned,items.last_accessed_at"
    }

    private func readItem(_ statement: OpaquePointer?) throws -> StoredItem {
        guard
            let id = UUID(uuidString: columnString(statement, index: 0)),
            let mountID = UUID(uuidString: columnString(statement, index: 1))
        else { throw SQLiteStoreError(code: SQLITE_CORRUPT, message: "Invalid item UUID") }
        return StoredItem(
            id: id,
            mountID: mountID,
            parentID: columnOptionalString(statement, index: 2).flatMap(UUID.init(uuidString:)),
            remoteID: columnOptionalString(statement, index: 3),
            remotePath: columnString(statement, index: 4),
            displayName: columnString(statement, index: 5),
            isDirectory: sqlite3_column_int(statement, 6) != 0,
            size: sqlite3_column_int64(statement, 7),
            modificationDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            contentVersion: columnData(statement, index: 9),
            metadataVersion: columnData(statement, index: 10),
            listGeneration: sqlite3_column_int64(statement, 11),
            materialized: sqlite3_column_int(statement, 12) != 0,
            pinned: sqlite3_column_int(statement, 13) != 0,
            lastAccessedAt: sqlite3_column_type(statement, 14) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 14))
        )
    }

    private func readIssue(id: UUID) throws -> IssueRecord? {
        let statement = try prepare("SELECT \(issueColumns) FROM issues WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString.lowercased(), at: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? try readIssue(statement) : nil
    }

    private func readIssue(_ statement: OpaquePointer?) throws -> IssueRecord {
        guard
            let id = UUID(uuidString: columnString(statement, index: 0)),
            let kind = IssueKind(rawValue: columnString(statement, index: 3))
        else { throw SQLiteStoreError(code: SQLITE_CORRUPT, message: "Invalid issue record") }
        let actions = try decoder.decode(
            [IssueResolutionAction].self,
            from: columnData(statement, index: 13)
        )
        return IssueRecord(
            id: id,
            mountID: columnOptionalString(statement, index: 1).flatMap(UUID.init(uuidString:)),
            itemID: columnOptionalString(statement, index: 2).flatMap(UUID.init(uuidString:)),
            kind: kind,
            diagnosticCode: columnString(statement, index: 4),
            message: columnString(statement, index: 5),
            retryable: sqlite3_column_int(statement, 9) != 0,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            resolvedAt: sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            remoteObjectID: columnOptionalString(statement, index: 10),
            remotePath: columnOptionalString(statement, index: 11),
            redactedPathToken: columnOptionalString(statement, index: 8),
            defaultRename: columnOptionalString(statement, index: 12),
            suggestedActions: actions
        )
    }

    private func readOperation(_ statement: OpaquePointer?) throws -> OperationRecord {
        guard
            let id = UUID(uuidString: columnString(statement, index: 0)),
            let mountID = UUID(uuidString: columnString(statement, index: 1)),
            let kind = OperationKind(rawValue: columnString(statement, index: 3)),
            let outcome = OperationOutcome(rawValue: columnString(statement, index: 4))
        else { throw SQLiteStoreError(code: SQLITE_CORRUPT, message: "Invalid operation record") }
        return OperationRecord(
            id: id,
            mountID: mountID,
            itemID: columnOptionalString(statement, index: 2).flatMap(UUID.init(uuidString:)),
            kind: kind,
            outcome: outcome,
            completedBytes: sqlite3_column_int64(statement, 5),
            totalBytes: sqlite3_column_int64(statement, 6),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            completedAt: sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            diagnosticCode: columnOptionalString(statement, index: 9)
        )
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? currentError().message
            sqlite3_free(message)
            throw SQLiteStoreError(code: result, message: text)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw currentError() }
        return statement
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) throws {
        let result = value.map { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) } ?? sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else { throw currentError() }
    }

    private func bind(_ data: Data, at index: Int32, in statement: OpaquePointer?) throws {
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        guard result == SQLITE_OK else { throw currentError() }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func scalarOptionalInt64(_ sql: String) throws -> Int64? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
    }

    private func columnString(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func columnOptionalString(_ statement: OpaquePointer?, index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : columnString(statement, index: index)
    }

    private func columnData(_ statement: OpaquePointer?, index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func currentError() -> SQLiteStoreError { Self.error(from: database) }

    private static func error(from database: OpaquePointer?) -> SQLiteStoreError {
        SQLiteStoreError(code: sqlite3_errcode(database), message: String(cString: sqlite3_errmsg(database)))
    }

    private func protectDatabaseFiles() throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            #if os(iOS)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: path
                )
            #endif
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = databaseURL
        try mutableURL.setResourceValues(values)
    }
}

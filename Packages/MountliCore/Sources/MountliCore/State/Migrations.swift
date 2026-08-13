import Foundation

public struct SQLiteMigration: Sendable {
    public let version: Int32
    public let statements: [String]

    public init(version: Int32, statements: [String]) {
        self.version = version
        self.statements = statements
    }
}

public enum MountliMigrations {
    public static let all: [SQLiteMigration] = [
        SQLiteMigration(
            version: 1,
            statements: [
                """
                CREATE TABLE mount_state (
                    mount_id TEXT PRIMARY KEY NOT NULL,
                    state_json BLOB NOT NULL,
                    updated_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE items (
                    id TEXT PRIMARY KEY NOT NULL,
                    mount_id TEXT NOT NULL,
                    parent_id TEXT,
                    remote_id TEXT,
                    remote_path TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    is_directory INTEGER NOT NULL,
                    size INTEGER NOT NULL,
                    modification_date REAL NOT NULL,
                    content_version BLOB NOT NULL,
                    metadata_version BLOB NOT NULL,
                    list_generation INTEGER NOT NULL,
                    materialized INTEGER NOT NULL DEFAULT 0,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    last_accessed_at REAL,
                    UNIQUE(mount_id, id)
                )
                """,
                """
                CREATE TABLE change_journal (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    mount_id TEXT NOT NULL,
                    item_id TEXT NOT NULL,
                    change_kind TEXT NOT NULL CHECK(change_kind IN ('create','update','delete')),
                    generation INTEGER NOT NULL,
                    created_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE operations (
                    id TEXT PRIMARY KEY NOT NULL,
                    mount_id TEXT NOT NULL,
                    item_id TEXT,
                    kind TEXT NOT NULL,
                    outcome TEXT NOT NULL,
                    completed_bytes INTEGER NOT NULL DEFAULT 0,
                    total_bytes INTEGER NOT NULL DEFAULT 0,
                    staging_path TEXT,
                    expected_version TEXT,
                    started_at REAL NOT NULL,
                    completed_at REAL,
                    diagnostic_code TEXT
                )
                """,
                """
                CREATE TABLE issues (
                    id TEXT PRIMARY KEY NOT NULL,
                    mount_id TEXT,
                    item_id TEXT,
                    kind TEXT NOT NULL,
                    diagnostic_code TEXT NOT NULL,
                    impact TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    resolved_at REAL,
                    redacted_path_token TEXT
                )
                """,
                """
                CREATE TABLE transfer_leases (
                    operation_id TEXT PRIMARY KEY NOT NULL,
                    mount_id TEXT NOT NULL,
                    owner TEXT NOT NULL,
                    expires_at REAL NOT NULL
                )
                """,
            ]),
        SQLiteMigration(
            version: 2,
            statements: [
                "CREATE INDEX items_parent ON items(mount_id, parent_id, display_name)",
                "CREATE UNIQUE INDEX items_remote_id ON items(mount_id, remote_id) WHERE remote_id IS NOT NULL",
                "CREATE INDEX journal_mount_sequence ON change_journal(mount_id, sequence)",
                "CREATE INDEX operations_recent ON operations(mount_id, started_at DESC)",
                "CREATE INDEX issues_open ON issues(mount_id, resolved_at) WHERE resolved_at IS NULL",
                "CREATE INDEX leases_expiry ON transfer_leases(expires_at)",
            ]),
        SQLiteMigration(
            version: 3,
            statements: [
                "ALTER TABLE change_journal ADD COLUMN container_id TEXT NOT NULL DEFAULT '__root__'",
                "ALTER TABLE change_journal ADD COLUMN container_visible INTEGER NOT NULL DEFAULT 1",
                "ALTER TABLE change_journal ADD COLUMN working_set INTEGER NOT NULL DEFAULT 0",
                """
                UPDATE change_journal
                SET container_id = COALESCE(
                    (SELECT COALESCE(items.parent_id, '__root__')
                     FROM items
                     WHERE items.mount_id = change_journal.mount_id
                       AND items.id = change_journal.item_id),
                    '__root__'
                )
                """,
                """
                CREATE TABLE journal_retention (
                    mount_id TEXT PRIMARY KEY NOT NULL,
                    floor_sequence INTEGER NOT NULL DEFAULT 0
                )
                """,
                """
                CREATE TABLE active_sync_anchors (
                    mount_id TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    anchor INTEGER NOT NULL,
                    expires_at REAL NOT NULL,
                    PRIMARY KEY(mount_id, scope, anchor)
                )
                """,
                """
                CREATE TABLE enumeration_leases (
                    mount_id TEXT NOT NULL,
                    container_id TEXT NOT NULL,
                    owner TEXT NOT NULL,
                    expires_at REAL NOT NULL,
                    PRIMARY KEY(mount_id, container_id)
                )
                """,
                """
                CREATE TABLE operation_leases (
                    operation_id TEXT PRIMARY KEY NOT NULL,
                    mount_id TEXT NOT NULL,
                    owner TEXT NOT NULL,
                    expires_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE removal_gates (
                    mount_id TEXT PRIMARY KEY NOT NULL,
                    owner TEXT NOT NULL,
                    expires_at REAL NOT NULL
                )
                """,
                "CREATE INDEX journal_container_sequence ON change_journal(mount_id, container_id, sequence) WHERE container_visible = 1",
                "CREATE INDEX journal_working_set_sequence ON change_journal(mount_id, sequence) WHERE working_set = 1",
                "CREATE INDEX operations_pending_item ON operations(mount_id, item_id, outcome)",
                "CREATE INDEX items_recent_access ON items(mount_id, last_accessed_at) WHERE last_accessed_at IS NOT NULL",
                "CREATE INDEX active_sync_anchor_expiry ON active_sync_anchors(expires_at)",
                "CREATE INDEX enumeration_lease_expiry ON enumeration_leases(expires_at)",
                "CREATE INDEX operation_lease_expiry ON operation_leases(expires_at)",
                "CREATE INDEX removal_gate_expiry ON removal_gates(expires_at)",
            ]),
        SQLiteMigration(
            version: 4,
            statements: [
                "ALTER TABLE issues ADD COLUMN retryable INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE issues ADD COLUMN remote_object_id TEXT",
                "ALTER TABLE issues ADD COLUMN remote_path TEXT",
                "ALTER TABLE issues ADD COLUMN default_rename TEXT",
                "ALTER TABLE issues ADD COLUMN suggested_actions_json BLOB NOT NULL DEFAULT X'5B5D'",
                """
                CREATE TABLE issue_resolution_requests (
                    issue_id TEXT PRIMARY KEY NOT NULL,
                    action TEXT NOT NULL,
                    rename_to TEXT,
                    requested_at REAL NOT NULL,
                    FOREIGN KEY(issue_id) REFERENCES issues(id) ON DELETE CASCADE
                )
                """,
                """
                CREATE TABLE operation_cancellation_requests (
                    operation_id TEXT PRIMARY KEY NOT NULL,
                    requested_at REAL NOT NULL,
                    FOREIGN KEY(operation_id) REFERENCES operations(id) ON DELETE CASCADE
                )
                """,
                "CREATE INDEX issues_open_dedupe ON issues(mount_id, item_id, diagnostic_code, remote_object_id, remote_path, resolved_at)",
                "CREATE INDEX issue_resolution_requested_at ON issue_resolution_requests(requested_at)",
                "CREATE INDEX operation_cancellation_requested_at ON operation_cancellation_requests(requested_at)",
            ]),
        SQLiteMigration(
            version: 5,
            statements: [
                """
                CREATE TABLE diagnostic_logs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at REAL NOT NULL,
                    category TEXT NOT NULL,
                    level TEXT NOT NULL,
                    message TEXT NOT NULL
                )
                """,
                "CREATE INDEX diagnostic_logs_recent ON diagnostic_logs(created_at DESC)",
            ]),
    ]

    public static var latestVersion: Int32 { all.last?.version ?? 0 }
}

#!/usr/bin/env python3
"""Generate deterministic backend availability and representative capability snapshots."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Config" / "ProviderCatalog.snapshot.json"
CAPABILITIES = ROOT / "Config" / "BackendCapabilityClasses.snapshot.json"


def backend_names() -> list[str]:
    imports = subprocess.check_output(
        ["go", "list", "-f", '{{join .Imports "\\n"}}', "github.com/rclone/rclone/backend/all"],
        cwd=ROOT / "GoBridge",
        text=True,
    )
    prefix = "github.com/rclone/rclone/backend/"
    return sorted(
        {
            package.removeprefix(prefix).split("/")[0]
            for package in imports.splitlines()
            if package.startswith(prefix) and package != prefix + "all"
        }
    )


def encoded(document: dict) -> str:
    return json.dumps(document, indent=2, sort_keys=True) + "\n"


def documents() -> tuple[str, str]:
    names = backend_names()
    catalog = {
        "schemaVersion": 1,
        "rcloneVersion": "1.75.0",
        "sourcePackage": "github.com/rclone/rclone/backend/all",
        "backends": names,
    }
    capabilities = {
        "schemaVersion": 1,
        "rcloneVersion": "1.75.0",
        "classes": [
            {"name": "readOnly", "representative": "http", "requiredAssertions": ["read"]},
            {"name": "objectStore", "representative": "s3", "requiredAssertions": ["read", "write", "directoriesVirtual"]},
            {"name": "filesystem", "representative": "sftp", "requiredAssertions": ["read", "write", "directoriesReal"]},
            {"name": "webdav", "representative": "webdav", "requiredAssertions": ["read", "write", "serverMoveConfigurationDependent"]},
            {"name": "overlay", "representative": "crypt", "requiredAssertions": ["dependencyRequired", "capabilitiesInherited"]},
            {"name": "testOnly", "representative": "memory", "requiredAssertions": ["volatile", "releaseHidden"]},
        ],
    }
    representatives = {item["representative"] for item in capabilities["classes"]}
    absent = representatives - set(names)
    if absent:
        raise SystemExit(f"capability representatives absent from backend/all: {sorted(absent)}")
    return encoded(catalog), encoded(capabilities)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    catalog, capabilities = documents()
    if arguments.check:
        for path, expected in ((CATALOG, catalog), (CAPABILITIES, capabilities)):
            if not path.is_file() or path.read_text() != expected:
                raise SystemExit(f"generated snapshot drift: {path.relative_to(ROOT)}")
        return
    CATALOG.write_text(catalog)
    CAPABILITIES.write_text(capabilities)


if __name__ == "__main__":
    main()

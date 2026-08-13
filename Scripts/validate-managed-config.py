#!/usr/bin/env python3
"""Validate the checked-in managed schema and platform sample profiles."""

from __future__ import annotations

import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "Config" / "ManagedAppConfig.schema.json"
PROFILE_DIR = ROOT / "Config" / "ManagedProfiles"
KEYS = {
    "PolicyVersion",
    "AllowedBackendTypes",
    "AllowConfigImport",
    "AllowConfigExport",
    "AllowInsecureTLS",
    "ForceReadOnly",
    "AllowCellular",
    "MaximumConcurrentTransfers",
    "SupportURL",
}
BOOL_KEYS = {
    "AllowConfigImport",
    "AllowConfigExport",
    "AllowInsecureTLS",
    "ForceReadOnly",
    "AllowCellular",
}


def fail(message: str) -> None:
    raise SystemExit(f"managed-config: {message}")


def backend_catalog() -> set[str]:
    output = subprocess.check_output(
        [
            "go",
            "list",
            "-f",
            '{{join .Imports "\\n"}}',
            "github.com/rclone/rclone/backend/all",
        ],
        cwd=ROOT / "GoBridge",
        text=True,
    )
    prefix = "github.com/rclone/rclone/backend/"
    return {
        package.removeprefix(prefix).split("/")[0]
        for package in output.splitlines()
        if package.startswith(prefix) and package != prefix + "all"
    }


def managed_dictionary(profile: dict, platform: str) -> dict:
    payloads = profile.get("PayloadContent")
    if not isinstance(payloads, list) or len(payloads) != 1:
        fail(f"{platform} profile must contain exactly one managed payload")
    payload = payloads[0]
    if platform == "iOS":
        if payload.get("PayloadType") != "com.apple.configuration.managed":
            fail("iOS payload type must be com.apple.configuration.managed")
        return {key: payload[key] for key in KEYS if key in payload}
    if payload.get("PayloadType") != "com.apple.ManagedClient.preferences":
        fail("macOS payload type must be com.apple.ManagedClient.preferences")
    try:
        return payload["PayloadContent"]["ch.benavo.mountli"]["Forced"][0]["mcx_preference_settings"]
    except (KeyError, IndexError, TypeError) as error:
        fail(f"macOS managed preferences nesting is invalid: {error}")


def validate(values: dict, platform: str, catalog: set[str]) -> None:
    unknown = set(values) - KEYS
    if unknown:
        fail(f"{platform} profile has unknown managed keys: {sorted(unknown)}")
    if values.get("PolicyVersion") != 1 or isinstance(values.get("PolicyVersion"), bool):
        fail(f"{platform} PolicyVersion must be integer 1")
    for key in BOOL_KEYS:
        if key in values and not isinstance(values[key], bool):
            fail(f"{platform} {key} must be Boolean")
    backends = values.get("AllowedBackendTypes", [])
    if not isinstance(backends, list) or any(not isinstance(value, str) for value in backends):
        fail(f"{platform} AllowedBackendTypes must be an array of strings")
    unavailable = sorted(set(backends) - catalog)
    if unavailable:
        fail(f"{platform} profile names backends absent from rclone v1.75.0: {unavailable}")
    maximum = values.get("MaximumConcurrentTransfers")
    platform_maximum = 4 if platform == "iOS" else 8
    if maximum is not None and (
        isinstance(maximum, bool) or not isinstance(maximum, int) or not 1 <= maximum <= platform_maximum
    ):
        fail(f"{platform} MaximumConcurrentTransfers must be 1...{platform_maximum}")
    support_url = values.get("SupportURL")
    if support_url is not None:
        parsed = urlparse(support_url)
        if parsed.scheme != "https" or not parsed.netloc:
            fail(f"{platform} SupportURL must be an absolute HTTPS URL")


def main() -> None:
    schema = json.loads(SCHEMA_PATH.read_text())
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        fail("schema must use JSON Schema 2020-12")
    if schema.get("additionalProperties") is not False:
        fail("schema must reject unknown or credential-bearing keys")
    if set(schema.get("properties", {})) != KEYS:
        fail("schema keys differ from the managed policy contract")
    if schema["properties"]["PolicyVersion"].get("const") != 1:
        fail("schema PolicyVersion must be fixed at 1")
    if schema["properties"]["SupportURL"].get("pattern") != "^https://":
        fail("schema SupportURL must require HTTPS")

    catalog = backend_catalog()
    if not catalog:
        fail("rclone backend catalog is empty")
    for platform, filename in (
        ("iOS", "MOUNTLI-iOS.mobileconfig"),
        ("macOS", "MOUNTLI-macOS.mobileconfig"),
    ):
        with (PROFILE_DIR / filename).open("rb") as stream:
            profile = plistlib.load(stream)
        validate(managed_dictionary(profile, platform), platform, catalog)

    print(f"Validated managed schema and profiles against {len(catalog)} rclone backends")


if __name__ == "__main__":
    main()

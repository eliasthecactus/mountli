#!/usr/bin/env python3
import json
import os
import plistlib
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
record = json.loads((root / "Config/EncryptionExport.json").read_text())
release = (root / "Config/Release.xcconfig").read_text()
release_mode = "--release" in sys.argv

assert record["reviewStatus"] in {"pending", "approved"}
assert isinstance(record["usesNonExemptEncryption"], bool)
assert record["appleComplianceCodeRequired"] == record["usesNonExemptEncryption"]
expected = "YES" if record["usesNonExemptEncryption"] else "NO"
match = re.search(r"^ITS_APP_USES_NON_EXEMPT_ENCRYPTION\s*=\s*(YES|NO)\s*$", release, re.MULTILINE)
assert match and match.group(1) == expected, "Release.xcconfig does not match EncryptionExport.json"

for plist_path in sorted((root / "Config/Info").glob("*.plist")):
    with plist_path.open("rb") as stream:
        info = plistlib.load(stream)
    assert info.get("ITSAppUsesNonExemptEncryption") is record["usesNonExemptEncryption"], (
        f"{plist_path.name} has the wrong ITSAppUsesNonExemptEncryption value"
    )
    code = info.get("ITSEncryptionExportComplianceCode")
    if record["appleComplianceCodeRequired"]:
        assert code == "$(MOUNTLI_ENCRYPTION_EXPORT_COMPLIANCE_CODE)", (
            f"{plist_path.name} must resolve the protected Apple compliance code"
        )
    else:
        assert code is None, f"{plist_path.name} must omit ITSEncryptionExportComplianceCode"

if release_mode:
    assert record["reviewStatus"] == "approved", "export classification is not approved"
    assert record["reviewedAt"] and record["reviewedBy"], "approved classification lacks review metadata"
    code = os.environ.get(record["appleComplianceCodeSource"], "")
    if record["appleComplianceCodeRequired"]:
        assert code and "PLACEHOLDER" not in code.upper() and "$" not in code, (
            "Apple-issued export compliance code is missing or invalid"
        )

print(f"Validated {expected} encryption declaration across six product plists ({record['reviewStatus']})")

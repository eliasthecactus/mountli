#!/usr/bin/env python3
import json
import plistlib
from pathlib import Path

root = Path(__file__).resolve().parents[1]
declaration = json.loads((root / "Config/AppPrivacy.json").read_text())
with (root / "Resources/PrivacyInfo.xcprivacy").open("rb") as stream:
    manifest = plistlib.load(stream)

store = declaration["appStoreConnect"]
facts = declaration["productFacts"]
assert store["dataCollected"] is False
assert store["tracking"] is False
assert store["privacyPolicyURL"] == (root / "fastlane/metadata/en-US/privacy_url.txt").read_text().strip()
assert store["manualSubmissionRequired"] is True
assert manifest["NSPrivacyTracking"] is False
assert manifest["NSPrivacyTrackingDomains"] == []
assert manifest["NSPrivacyCollectedDataTypes"] == []
assert facts["telemetryUpload"] is False
assert facts["automaticDiagnosticsUpload"] is False
assert facts["userInitiatedDiagnosticsExport"] is True

project = (root / "project.yml").read_text()
expected_targets = project.count("- path: Resources/PrivacyInfo.xcprivacy")
assert expected_targets == 9, f"privacy manifest is present in {expected_targets} targets; expected 9"

required_reasons = {
    item["NSPrivacyAccessedAPIType"]: set(item["NSPrivacyAccessedAPITypeReasons"])
    for item in manifest["NSPrivacyAccessedAPITypes"]
}
assert required_reasons["NSPrivacyAccessedAPICategoryUserDefaults"] == {"CA92.1", "1C8F.1"}
assert required_reasons["NSPrivacyAccessedAPICategoryFileTimestamp"] == {"C617.1"}
print("Validated Data Not Collected declaration, privacy manifest, and nine target inclusions")

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TAG="${1:-${GITHUB_REF_NAME:-}}"
[[ "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo "Release ref must be an exact vMAJOR.MINOR.PATCH tag" >&2
  exit 1
}
VERSION="${TAG#v}"
[[ "${GITHUB_REF_TYPE:-tag}" == "tag" ]] || { echo "Release must run from a tag ref" >&2; exit 1; }

CANONICAL="$(sed -n 's/^MARKETING_VERSION = //p' Config/Base.xcconfig)"
PROJECT_VERSION="$(python3 - <<'PY'
import re
text = open('project.yml').read()
match = re.search(r'^\s*MARKETING_VERSION:\s*"([^"]+)"', text, re.MULTILINE)
print(match.group(1) if match else '')
PY
)"
[[ "$VERSION" == "$CANONICAL" && "$VERSION" == "$PROJECT_VERSION" ]] || {
  echo "Tag version $VERSION differs from Config/Base.xcconfig ($CANONICAL) or project.yml ($PROJECT_VERSION)" >&2
  exit 1
}


git cat-file -e "$TAG^{tag}" 2>/dev/null || { echo "Release tag must be annotated" >&2; exit 1; }
git verify-tag "$TAG"
TAG_COMMIT="$(git rev-list -n 1 "$TAG")"
[[ -z "${GITHUB_SHA:-}" || "$TAG_COMMIT" == "$GITHUB_SHA" ]] || {
  echo "Workflow SHA does not match signed tag commit" >&2
  exit 1
}
git show-ref --verify --quiet refs/remotes/origin/main || git fetch --no-tags origin main:refs/remotes/origin/main
git merge-base --is-ancestor "$TAG_COMMIT" refs/remotes/origin/main || {
  echo "Signed tag commit is not on origin/main" >&2
  exit 1
}
if [[ "${MOUNTLI_SKIP_COMPLIANCE_PREFLIGHT:-0}" != "1" ]]; then
  "$ROOT/Scripts/validate-encryption-export.py" --release
else
  "$ROOT/Scripts/validate-encryption-export.py"
fi

[[ -s fastlane/metadata/en-US/description.txt ]] || { echo "App Store metadata is incomplete" >&2; exit 1; }
[[ -s Documentation/AppReview.md ]] || { echo "App Review runbook is missing" >&2; exit 1; }
[[ -s Resources/PrivacyInfo.xcprivacy ]] || { echo "Privacy manifest is missing" >&2; exit 1; }
[[ -s Gemfile.lock ]] || { echo "Gemfile.lock is missing" >&2; exit 1; }
"$ROOT/Scripts/verify-app-store-assets.sh"

echo "Signed release preflight accepted $TAG at $TAG_COMMIT"

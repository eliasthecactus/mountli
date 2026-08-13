SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help bootstrap bridge generate verify-generated verify-bridge verify-format verify-static test test-go test-swift test-integration test-ui capture-app-store-screenshots smoke-file-provider archive archive-direct verify-release validate-managed-config validate-privacy validate-encryption-export verify-licenses generate-sboms build-macos build-ios build-direct clean

help:
	@printf '%s\n' \
	  'bootstrap                 install exact checked-in tool and Ruby dependency pins' \
	  'bridge                    build the pinned rclone XCFramework' \
	  'generate                  regenerate the tracked Xcode project' \
	  'verify-generated          reject project/notices/policy generator drift' \
	  'verify-bridge             verify all required XCFramework platform slices' \
	  'verify-format             enforce checked-in Swift formatting rules' \
	  'verify-static             run generated, bridge, policy, privacy, encryption, and legal gates' \
	  'test                      run unit, integration, UI, generated, and legal gates' \
	  'test-integration          run credential-free bridge/provider integration contracts' \
	  'test-ui                   run macOS/iOS launch tests and every executable graph' \
	  'capture-app-store-screenshots refresh deterministic iPhone, iPad, and Mac fixtures' \
	  'smoke-file-provider       exercise a signed domain with protected fixture inputs' \
	  'archive                   archive signed App Store products (VERSION/BUILD_NUMBER required)' \
	  'archive-direct            archive/notarize direct Mac (VERSION and protected keys required)' \
	  'verify-release            verify RELEASE_CHANNEL/ARTIFACT_DIR/VERSION artifacts' \
	  'validate-managed-config   validate schema and sample MDM profiles against rclone' \
	  'validate-privacy          validate Data Not Collected and privacy manifest declarations' \
	  'validate-encryption-export validate release encryption classification and plists'

bootstrap:
	@command -v mise >/dev/null || { echo 'Install mise from https://mise.jdx.dev/'; exit 1; }
	mise install
	mise run bootstrap-go-tools
	mise exec -- bundle config set path .bundle
	mise exec -- bundle config set frozen true
	mise exec -- bundle install

bridge:
	./Scripts/build-bridge.sh

generate: bridge
	mise exec -- xcodegen generate

verify-generated:
	mise exec -- ./Scripts/verify-generated.sh

verify-bridge: bridge
	./Scripts/verify-bridge.sh

test-go:
	cd GoBridge && go mod verify && go test -race ./... && go vet ./... && govulncheck ./...

test-swift: bridge
	swift test --package-path Packages/MountliCore
	swift test --package-path Packages/MountliFileProvider

test-integration: bridge
	./Scripts/test-integration.sh

test-ui: generate
	./Scripts/test-ui.sh

capture-app-store-screenshots:
	./Scripts/capture-app-store-screenshots.sh

smoke-file-provider:
	./Scripts/smoke-file-provider.sh

validate-managed-config:
	./Scripts/validate-managed-config.py

validate-privacy:
	./Scripts/validate-privacy.py

validate-encryption-export:
	./Scripts/validate-encryption-export.py

verify-format:
	swift format lint --configuration .swift-format --recursive --parallel App Packages UITests --strict

verify-static: verify-generated verify-bridge verify-format validate-managed-config validate-privacy validate-encryption-export verify-licenses

verify-licenses:
	./Scripts/generate-notices.sh --check

generate-sboms:
	./Scripts/generate-sboms.sh


test: verify-static test-go test-swift test-integration test-ui

archive: generate
	@: "$${VERSION:?Set VERSION to MAJOR.MINOR.PATCH}"
	@: "$${BUILD_NUMBER:?Set BUILD_NUMBER to a monotonic integer}"
	./Scripts/archive-app-store.sh "$${VERSION}" "$${BUILD_NUMBER}"

archive-direct: generate
	@: "$${VERSION:?Set VERSION to MAJOR.MINOR.PATCH}"
	@: "$${BUILD_NUMBER:?Set BUILD_NUMBER to a monotonic integer}"
	BUILD_NUMBER="$${BUILD_NUMBER}" ./Scripts/release-direct.sh "$${VERSION}"

verify-release:
	@: "$${RELEASE_CHANNEL:?Set RELEASE_CHANNEL to app-store or direct}"
	@: "$${ARTIFACT_DIR:?Set ARTIFACT_DIR}"
	@: "$${VERSION:?Set VERSION}"
	./Scripts/verify-release.sh "$${RELEASE_CHANNEL}" "$${ARTIFACT_DIR}" "$${VERSION}" "$${ARCHIVE_PATH:-}"

build-macos: generate
	xcodebuild -project MOUNTLI.xcodeproj -scheme MOUNTLI-macOS -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build

build-ios: generate
	xcodebuild -project MOUNTLI.xcodeproj -scheme MOUNTLI-iOS -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

build-direct: generate
	xcodebuild -project MOUNTLI.xcodeproj -scheme MOUNTLI-macOS-Direct -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build

clean:
	rm -rf .build .build-cache Packages/MountliCore/Vendor/RcloneCore.xcframework

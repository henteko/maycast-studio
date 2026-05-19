.PHONY: help build test unit e2e clean app cli release release-app release-cli

# ─── Paths ─────────────────────────────────────────────────────────────
APP_PROJECT := Apps/MaycastStudio/Maycast Studio/Maycast Studio.xcodeproj
APP_SCHEME  := Maycast Studio
APP_NAME    := Maycast Studio.app

BUILD_DIR := build
DIST_DIR  := dist
APP_OUT   := $(BUILD_DIR)/Build/Products/Release/$(APP_NAME)
CLI_OUT   := .build/release/maycast

# Release metadata.
#
# `Sources/MaycastCLI/MaycastVersion.swift` is the single source of truth for
# the release version. Bump the `static let current = "..."` value there and
# commit; everything downstream (CLI --version, .app's Info.plist, release
# filenames) reads from that file.
#
# Override per invocation if you want a one-off label (e.g. an RC build):
#   make release VERSION=0.1.0-rc1
VERSION_FILE := Sources/MaycastCLI/MaycastVersion.swift
VERSION      ?= $(shell awk -F'"' '/static let current/ { print $$2 }' $(VERSION_FILE))
ARCH         := $(shell uname -m)

# ─── Targets ───────────────────────────────────────────────────────────
help:
	@echo "Maycast Studio — make targets"
	@echo ""
	@echo "  Develop:"
	@echo "    make build         # Build all SwiftPM targets (CLI + XPC services + libs)"
	@echo "    make test          # Run all tests (unit + E2E)"
	@echo "    make unit          # Run unit tests only (MaycastCoreTests)"
	@echo "    make e2e           # Run end-to-end tests (MaycastE2ETests)"
	@echo "    make clean         # Remove .build/, build/, and dist/"
	@echo ""
	@echo "  Release (prebuilt artefacts for GitHub Releases):"
	@echo "    make release       # Build & package both: .dmg (GUI) + .tar.gz (CLI) → dist/"
	@echo "    make release-app   # Just the .dmg"
	@echo "    make release-cli   # Just the CLI tarball"
	@echo "    make app           # Build .app (Release config) without packaging"
	@echo "    make cli           # Build maycast CLI (Release config) without packaging"
	@echo ""
	@echo "  Versioning:"
	@echo "    Source of truth: $(VERSION_FILE)"
	@echo "    Current value:   $(VERSION)"
	@echo "    Bump release:    edit the file, commit, tag, then \`make release\`"
	@echo "    One-off label:   make release VERSION=0.1.0-rc1"

build:
	swift build

test:
	swift test

unit:
	swift test --filter MaycastCoreTests

e2e:
	swift build
	swift test --filter MaycastE2ETests

# ─── Release builds ────────────────────────────────────────────────────
# The CLI's `--version` reads `MaycastVersion.current` directly from
# $(VERSION_FILE), so `swift build` alone is enough — no codegen step.
# The .app gets the same value injected into Info.plist via xcodebuild build
# settings (overriding the pbxproj defaults at build time, no source edits).
app:
	@echo "→ Building $(APP_NAME) (Release, version $(VERSION))…"
	xcodebuild \
		-project "$(APP_PROJECT)" \
		-scheme "$(APP_SCHEME)" \
		-configuration Release \
		-destination "platform=macOS" \
		-derivedDataPath "$(BUILD_DIR)" \
		MARKETING_VERSION=$(VERSION) \
		CURRENT_PROJECT_VERSION=$(VERSION) \
		build
	@echo "✓ App built: $(APP_OUT)"

cli:
	@echo "→ Building maycast CLI (Release, version $(VERSION))…"
	swift build -c release --product maycast
	@echo "✓ CLI built: $(CLI_OUT)"

# ─── Distributable release artefacts ───────────────────────────────────
# Outputs land in dist/ and are intended to be uploaded to a GitHub Release.
# Note: artefacts are unsigned; users on Gatekeeper-strict Macs will need to
# right-click → Open or remove the quarantine attribute on first launch.
release: release-app release-cli

release-app: app
	@echo "→ Packaging $(APP_NAME) into .dmg…"
	@rm -rf "$(DIST_DIR)/dmg" "$(DIST_DIR)/Maycast-Studio-$(VERSION).dmg"
	@mkdir -p "$(DIST_DIR)/dmg"
	cp -R "$(APP_OUT)" "$(DIST_DIR)/dmg/"
	ln -s /Applications "$(DIST_DIR)/dmg/Applications"
	hdiutil create \
		-volname "Maycast Studio" \
		-srcfolder "$(DIST_DIR)/dmg" \
		-ov -format UDZO \
		"$(DIST_DIR)/Maycast-Studio-$(VERSION).dmg" >/dev/null
	@rm -rf "$(DIST_DIR)/dmg"
	@echo "✓ DMG: $(DIST_DIR)/Maycast-Studio-$(VERSION).dmg"

release-cli: cli
	@echo "→ Archiving maycast CLI ($(ARCH))…"
	@mkdir -p "$(DIST_DIR)"
	tar -czf "$(DIST_DIR)/maycast-$(VERSION)-macos-$(ARCH).tar.gz" \
		-C .build/release \
		maycast
	@echo "✓ Tarball: $(DIST_DIR)/maycast-$(VERSION)-macos-$(ARCH).tar.gz"

clean:
	rm -rf .build "$(BUILD_DIR)" "$(DIST_DIR)"
	@echo "✓ Cleaned."

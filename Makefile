.PHONY: help build test unit e2e clean app cli release release-app release-cli

# ─── Paths ─────────────────────────────────────────────────────────────
APP_PROJECT := Apps/MaycastStudio/Maycast Studio/Maycast Studio.xcodeproj
APP_SCHEME  := Maycast Studio
APP_NAME    := Maycast Studio.app

BUILD_DIR := build
DIST_DIR  := dist
APP_OUT   := $(BUILD_DIR)/Build/Products/Release/$(APP_NAME)
CLI_OUT   := .build/release/maycast

# Release metadata — override per invocation, e.g.
#   make release VERSION=0.1.0
VERSION ?= dev
ARCH    := $(shell uname -m)

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
	@echo "  Override the version label baked into release filenames:"
	@echo "    make release VERSION=0.1.0"

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
app:
	@echo "→ Building $(APP_NAME) (Release)…"
	xcodebuild \
		-project "$(APP_PROJECT)" \
		-scheme "$(APP_SCHEME)" \
		-configuration Release \
		-destination "platform=macOS" \
		-derivedDataPath "$(BUILD_DIR)" \
		build
	@echo "✓ App built: $(APP_OUT)"

cli:
	@echo "→ Building maycast CLI (Release)…"
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

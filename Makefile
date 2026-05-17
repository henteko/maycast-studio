.PHONY: build test e2e unit clean help

help:
	@echo "Maycast Studio — make targets"
	@echo "  make build   # Build all SwiftPM targets (CLI + XPC services + libs)"
	@echo "  make test    # Run all tests (unit + E2E)"
	@echo "  make unit    # Run unit tests only (MaycastCoreTests)"
	@echo "  make e2e     # Run end-to-end tests (MaycastE2ETests)"
	@echo "  make clean   # Remove .build/"

build:
	swift build

test:
	swift test

unit:
	swift test --filter MaycastCoreTests

e2e:
	swift build
	swift test --filter MaycastE2ETests

clean:
	rm -rf .build

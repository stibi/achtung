# Shortcuts for the macOS client's scripts in macos/scripts. The server has its own
# commands: pnpm --dir server run ... (see AGENTS.md).

.PHONY: help run run-light install check test xcode

help: ## Show the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

run: ## Build a Debug app from the working tree and start it
	macos/scripts/run.sh

run-light: ## Like run, with the app in light mode
	macos/scripts/run.sh -NSRequiresAquaSystemAppearance YES

install: ## Build a Release app into ~/Applications and start it
	macos/scripts/install.sh

check: ## Format, lint, tests, app build and dead code (must pass)
	macos/scripts/check.sh

test: ## Domain and API package tests only
	swift test --package-path macos/Packages/AchtungDomain
	swift test --package-path macos/Packages/AchtungAPI

xcode: ## Generate the Xcode project and open it
	cd macos && xcodegen generate && open Achtung.xcodeproj

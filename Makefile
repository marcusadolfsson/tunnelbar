# Tunnelbar — build and verification entry points.
#
# The package builds headlessly with `swift build` by design:
# no .xcodeproj, so every check here is readable text output.

SWIFT ?= swift

# Code signing identity.
#
# A real certificate matters beyond tidiness: Keychain ACLs and SMAppService
# both key on the code signature, so an ad-hoc signature — whose hash changes on
# every build — makes macOS treat each build as a different app. That means
# re-prompting for Keychain items and unreliable login-item registration.
#
# Picks the first usable identity, preferring Developer ID (required to share
# the app with anyone else) over Apple Development (fine locally). Falls back to
# ad-hoc so the build still works on a machine with no certificate at all.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| awk -F'"' '/Developer ID Application/ {print $$2; exit}'; \
	security find-identity -v -p codesigning 2>/dev/null \
	| awk -F'"' '/Apple Development/ {print $$2; exit}')
CODESIGN_ID := $(if $(SIGN_IDENTITY),$(SIGN_IDENTITY),-)
CONFIG ?= debug
BINDIR := .build/$(CONFIG)
APP := Tunnelbar.app
INSTALL_DIR ?= /Applications

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build all targets
	$(SWIFT) build -c $(CONFIG)

.PHONY: test
test: ## Run the test suite
	$(SWIFT) test

.PHONY: discover
discover: build ## Run read-only discovery and print JSON
	@$(BINDIR)/tunnelbar-discover

.PHONY: watch
watch: build ## Re-run discovery every 10s
	@$(BINDIR)/tunnelbar-discover --watch 10

.PHONY: check
check: test discover ## Test, then prove discovery works on this machine

.PHONY: release
release: ## Build optimised binaries
	$(SWIFT) build -c release

.PHONY: install
install: app ## Build, sign, and install into $(INSTALL_DIR)
# One shell for the whole recipe: each Make line otherwise runs in its own
# shell, and whether the app was running has to survive from the check at the
# start to the relaunch at the end.
#
# Signing happens in `app`, before the copy, and is verified again afterwards —
# a bundle that lost its signature in transit would silently break both Keychain
# access and login-item registration.
#
# A running copy is stopped and then restarted. Replacing a bundle underneath a
# running process leaves it running stale code, and leaving it stopped is worse:
# the menu bar item simply vanishes, with the supervisor no longer restarting
# anything it manages.
	@set -e; \
	EXE="$(INSTALL_DIR)/$(APP)/Contents/MacOS/Tunnelbar"; \
	WAS_RUNNING=0; \
	if pgrep -f "$$EXE" >/dev/null 2>&1; then \
		WAS_RUNNING=1; \
		echo "Stopping the running copy."; \
		pkill -f "$$EXE" || true; \
		sleep 1; \
	fi; \
	rm -rf "$(INSTALL_DIR)/$(APP)"; \
	cp -R $(APP) "$(INSTALL_DIR)/"; \
	codesign --verify --strict --verbose=1 "$(INSTALL_DIR)/$(APP)"; \
	echo "Installed $(INSTALL_DIR)/$(APP)"; \
	if [ "$$WAS_RUNNING" = "1" ]; then \
		open "$(INSTALL_DIR)/$(APP)"; \
		sleep 2; \
		if pgrep -f "$$EXE" >/dev/null 2>&1; then \
			echo "Relaunched."; \
		else \
			echo "WARNING: relaunch failed — start it from $(INSTALL_DIR) manually."; \
		fi; \
	else \
		echo "Not previously running; start it with: open $(INSTALL_DIR)/$(APP)"; \
	fi
# A login item records the exact path it was registered from, so an install to a
# new location leaves any previous registration pointing at the old one.
	@if ! "$(INSTALL_DIR)/$(APP)/Contents/MacOS/Tunnelbar" --login-item-status 2>/dev/null \
		| grep -q "status:  1"; then \
		echo "Launch at login is off. Enable with:"; \
		echo "  \"$(INSTALL_DIR)/$(APP)/Contents/MacOS/Tunnelbar\" --enable-login-item"; \
	fi

.PHONY: identities
identities: ## Show available code signing identities
	@security find-identity -v -p codesigning

.PHONY: clean
clean: ## Remove build products
	$(SWIFT) package clean
	rm -rf .build $(APP)

# --- App bundle -------------------------------------------------------------
# Assembles $(APP) from the built GUI binary plus an Info.plist with
# LSUIElement set, so no Dock icon appears. The GUI target does not exist yet —
# discovery is deliberately built and verified before any UI.

.PHONY: app
app: ## Assemble Tunnelbar.app (requires the GUI target, not yet written)
	@if [ ! -d Sources/Tunnelbar ]; then \
		echo "No Sources/Tunnelbar yet — the MenuBarExtra target lands after"; \
		echo "discovery is verified. Run 'make discover' meanwhile."; \
		exit 1; \
	fi
	$(SWIFT) build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/Tunnelbar $(APP)/Contents/MacOS/Tunnelbar
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	@echo "Signing with: $(CODESIGN_ID)"
# --options runtime enables the hardened runtime, which notarisation requires
# and which costs nothing here.
	codesign --force --options runtime --sign "$(CODESIGN_ID)" \
		--identifier com.adolfsson.tunnelbar $(APP)
	@codesign --verify --strict --verbose=1 $(APP)
	@codesign -dv $(APP) 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" | head -4
	@echo "Built $(APP)"

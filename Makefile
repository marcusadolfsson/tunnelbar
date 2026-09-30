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
# The two lookups are chained with ||, not ';': separated by a semicolon both
# would run, and on a machine holding both certificates make would join the two
# names into one nonsense string that codesign rejects with "no identity found".
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| awk -F'"' '/Developer ID Application/ {print $$2; exit}' | grep . \
	|| security find-identity -v -p codesigning 2>/dev/null \
	| awk -F'"' '/Apple Development/ {print $$2; exit}')
CODESIGN_ID := $(if $(SIGN_IDENTITY),$(SIGN_IDENTITY),-)
CONFIG ?= debug
BINDIR := .build/$(CONFIG)
APP := Tunnelbar.app
EXE_NAME := Tunnelbar
INSTALL_DIR ?= /Applications

# Universal: Apple Silicon and Intel. A multi-arch build lands under
# .build/apple/Products/Release rather than .build/release.
ARCHS := --arch arm64 --arch x86_64
RELEASE_BIN := .build/apple/Products/Release/$(EXE_NAME)

# Ad-hoc signing cannot carry a secure timestamp, and asking for one fails the
# build. A real identity always should: notarisation requires it.
TIMESTAMP := $(if $(SIGN_IDENTITY),--timestamp,--timestamp=none)

# Notarisation. Create the profile once, locally:
#   xcrun notarytool store-credentials tunnelbar \
#     --apple-id <APPLE_ID> --team-id ZP8TR4ZYDR --password <app-specific password>
# No secret is stored in this file. CI passes credentials instead (see
# .github/workflows/release.yml).
NOTARY_PROFILE ?= tunnelbar
NOTARY_AUTH ?= --keychain-profile "$(NOTARY_PROFILE)"
DIST_ZIP := dist/Tunnelbar.zip
DMG := dist/Tunnelbar.dmg

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

.PHONY: dmg
dmg: ## Package the built app as a drag-to-Applications disk image in dist/
	@test -d "$(APP)" || { echo "Build the app first (make app)"; exit 1; }
	rm -rf dist/dmg-root "$(DMG)"
	mkdir -p dist/dmg-root
	cp -R "$(APP)" dist/dmg-root/
	ln -s /Applications dist/dmg-root/Applications
	hdiutil create -volname "Tunnelbar" -srcfolder dist/dmg-root -fs HFS+ -format UDZO -ov "$(DMG)"
	rm -rf dist/dmg-root
	codesign --force $(TIMESTAMP) --sign "$(CODESIGN_ID)" "$(DMG)"
	@echo "Built $(DMG)"

.PHONY: notarize
notarize: app ## Notarize and staple the app and its DMG (needs Developer ID)
# Refuse early rather than submitting something Apple will reject: only a
# Developer ID Application certificate can be notarised.
	@case "$(CODESIGN_ID)" in "Developer ID Application"*) ;; \
		*) echo "Notarisation needs a Developer ID Application certificate; signing identity is: $(CODESIGN_ID)"; exit 1;; esac
	@xcrun notarytool history $(NOTARY_AUTH) >/dev/null 2>&1 || { \
		echo "Notarisation credentials not usable. Create the profile once with:"; \
		echo "  xcrun notarytool store-credentials $(NOTARY_PROFILE) --apple-id <APPLE_ID> --team-id ZP8TR4ZYDR --password <app-specific password>"; exit 1; }
# 1. The app first, so its ticket is already stapled inside the DMG.
	mkdir -p dist
	rm -f "$(DIST_ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(DIST_ZIP)"
	xcrun notarytool submit "$(DIST_ZIP)" $(NOTARY_AUTH) --wait
	xcrun stapler staple "$(APP)"
	rm -f "$(DIST_ZIP)"
# 2. The DMG around the stapled app, so it installs cleanly offline too.
	$(MAKE) --no-print-directory dmg
	xcrun notarytool submit "$(DMG)" $(NOTARY_AUTH) --wait
	xcrun stapler staple "$(DMG)"
	xcrun stapler validate "$(DMG)"
	spctl --assess --type open --context context:primary-signature --verbose=2 "$(DMG)"
	spctl --assess --type execute --verbose=2 "$(APP)"
	@echo "Notarised: $(DMG)"

.PHONY: identities
identities: ## Show available code signing identities
	@security find-identity -v -p codesigning

.PHONY: clean
clean: ## Remove build products
	$(SWIFT) package clean
	rm -rf .build $(APP) dist

# --- App bundle -------------------------------------------------------------
# Assembles $(APP) from the built GUI binary plus an Info.plist with
# LSUIElement set, so no Dock icon appears. The GUI target does not exist yet —
# discovery is deliberately built and verified before any UI.

.PHONY: app
app: ## Build a universal Tunnelbar.app and sign it
	$(SWIFT) build -c release $(ARCHS)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(RELEASE_BIN) $(APP)/Contents/MacOS/$(EXE_NAME)
	@lipo -info $(APP)/Contents/MacOS/$(EXE_NAME)
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	@echo "Signing with: $(CODESIGN_ID)"
# The hardened runtime is required for notarisation. Nothing executable is
# bundled inside the app — cloudflared is launched from its own install
# location — so there is no nested code to sign first.
	codesign --force --options runtime $(TIMESTAMP) --sign "$(CODESIGN_ID)" \
		--identifier com.adolfsson.tunnelbar $(APP)
	@codesign --verify --strict --verbose=1 $(APP)
	@codesign -dv $(APP) 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" | head -4
	@echo "Built $(APP)"

.PHONY: build app debug-bundle prod-bundle ci clean run notarize release publish test

# Two flavors are built from the same executable and can run side by side:
#   production  NanoWhisper.app        com.moonji.nanowhisper        (ci, release, notarize, publish)
#   debug       NanoWhisper Debug.app  com.moonji.nanowhisper.debug  (app, run)
# The app picks its flavor at runtime from its bundle identifier (see BuildFlavor.swift).

PRODUCT = NanoWhisper
BUILD_DIR = .build/release
SIGN_IDENTITY ?= Moonji Dev
ENTITLEMENTS = Resources/NanoWhisper.entitlements
FLAVOR_DIR = .build/flavors
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

# Copied into Contents/Resources of both flavors (AppIcon.icns is chosen per flavor).
BUNDLE_RESOURCES = \
	Resources/menubar_icon.png \
	Resources/menubar_icon@2x.png \
	Resources/start.m4a \
	Resources/stop.m4a \
	Resources/noResult.m4a

# Production flavor: exactly what the release workflow ships.
PROD_APP = NanoWhisper.app
PROD_EXECUTABLE = NanoWhisper
PROD_PLIST = Resources/Info.plist
PROD_ICNS = Resources/AppIcon.icns
RELEASE_ZIP = NanoWhisper-v$(VERSION).zip

# Debug flavor: Info.plist and icon are derived from the production ones at build time.
# The executable has its own name so `pkill -x` can never match the production process
# (keep it <= 16 characters, the kernel's process name limit).
DEBUG_NAME = NanoWhisper Debug
DEBUG_APP = NanoWhisper Debug.app
DEBUG_EXECUTABLE = NanoWhisperDebug
DEBUG_BUNDLE_ID = com.moonji.nanowhisper.debug
DEBUG_PLIST = $(FLAVOR_DIR)/debug/Info.plist
DEBUG_ICNS = $(FLAVOR_DIR)/debug/AppIcon.icns
GIT_COMMIT := $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)$(shell git diff --quiet HEAD -- 2>/dev/null; [ $$? -eq 1 ] && echo -dirty)

# $(call bundle_and_sign,<app bundle>,<executable name>,<Info.plist>,<AppIcon.icns>)
define bundle_and_sign
	@echo "Creating $(1)..."
	@rm -rf "$(1)"
	@mkdir -p "$(1)/Contents/MacOS" "$(1)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(PRODUCT)" "$(1)/Contents/MacOS/$(2)"
	@cp "$(3)" "$(1)/Contents/Info.plist"
	@cp "$(4)" "$(1)/Contents/Resources/AppIcon.icns"
	@cp $(BUNDLE_RESOURCES) "$(1)/Contents/Resources/"
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		IDENTITY="$(SIGN_IDENTITY)"; \
	else \
		echo "Warning: No signing identity set. Using ad-hoc signing."; \
		IDENTITY=-; \
	fi; \
	codesign --force --deep --options runtime \
		--entitlements $(ENTITLEMENTS) \
		--sign "$$IDENTITY" "$(1)"
endef

# Build the Swift executable (release mode)
build:
	swift build -c release

# Production bundle (NanoWhisper.app). Never launches or kills anything.
prod-bundle: build
	$(call bundle_and_sign,$(PROD_APP),$(PROD_EXECUTABLE),$(PROD_PLIST),$(PROD_ICNS))

# Debug bundle (NanoWhisper Debug.app)
debug-bundle: build $(DEBUG_ICNS)
	@mkdir -p "$(FLAVOR_DIR)/debug"
	@cp Resources/Info.plist "$(DEBUG_PLIST)"
	@plutil -replace CFBundleIdentifier -string "$(DEBUG_BUNDLE_ID)" "$(DEBUG_PLIST)"
	@plutil -replace CFBundleName -string "$(DEBUG_NAME)" "$(DEBUG_PLIST)"
	@plutil -replace CFBundleDisplayName -string "$(DEBUG_NAME)" "$(DEBUG_PLIST)"
	@plutil -replace CFBundleExecutable -string "$(DEBUG_EXECUTABLE)" "$(DEBUG_PLIST)"
	@plutil -replace NWGitCommit -string "$(GIT_COMMIT)" "$(DEBUG_PLIST)"
	@for key in $$(plutil -convert json -o - Resources/Info.plist | grep -o '"NS[A-Za-z]*UsageDescription"' | tr -d '"'); do \
		value=$$(plutil -extract "$$key" raw Resources/Info.plist | sed 's/NanoWhisper/$(DEBUG_NAME)/g'); \
		plutil -replace "$$key" -string "$$value" "$(DEBUG_PLIST)"; \
	done
	$(call bundle_and_sign,$(DEBUG_APP),$(DEBUG_EXECUTABLE),$(DEBUG_PLIST),$(DEBUG_ICNS))

# Debug icon: production icon + "DEBUG" banner. Regenerated only when its inputs change.
$(DEBUG_ICNS): Resources/AppIcon.png scripts/make-debug-icon.swift
	@echo "Generating debug app icon..."
	@swift scripts/make-debug-icon.swift Resources/AppIcon.png "$(FLAVOR_DIR)/debug"

# Build NanoWhisper Debug.app and (re)launch it. Only processes named $(DEBUG_EXECUTABLE)
# are stopped; the production app (process "NanoWhisper") is never touched.
app: debug-bundle
	@pkill -x $(DEBUG_EXECUTABLE) 2>/dev/null; \
	for i in $$(seq 50); do pgrep -x $(DEBUG_EXECUTABLE) >/dev/null || break; sleep 0.1; done
	@open "$(DEBUG_APP)"
	@echo "Done! $(DEBUG_APP) ($(GIT_COMMIT)) launched."

# CI build: production bundle, no launch (GitHub Actions)
ci: prod-bundle
	@echo "Done! $(PROD_APP) created."

# Notarize the production app for distribution (requires Developer ID certificate)
notarize: prod-bundle
	@echo "Creating zip for notarization..."
	@ditto -c -k --keepParent $(PROD_APP) $(PRODUCT).zip
	@echo "Submitting to Apple notary service..."
	xcrun notarytool submit $(PRODUCT).zip \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait
	@echo "Stapling notarization ticket..."
	xcrun stapler staple $(PROD_APP)
	@rm -f $(PRODUCT).zip
	@echo "Notarization complete!"

# Run in development without a bundle (behaves as the debug flavor)
run: build
	$(BUILD_DIR)/$(PRODUCT)

# Production release zip, named like the release workflow's asset (AutoUpdater downloads it)
release: prod-bundle
	@echo "Creating $(RELEASE_ZIP)..."
	@rm -f "$(RELEASE_ZIP)"
	@ditto -c -k --keepParent $(PROD_APP) "$(RELEASE_ZIP)"
	@echo "Done! $(RELEASE_ZIP) created."

# Local fallback for the release workflow (e.g. hosted macOS runner unavailable):
# builds the production zip and creates the GitHub release for tag v$(VERSION).
# The tag must already exist on GitHub and point at the checked-out commit.
publish:
	@git diff --quiet HEAD -- || { echo "Error: uncommitted changes; publish from a clean checkout."; exit 1; }
	@[ "$$(git rev-parse -q --verify 'refs/tags/v$(VERSION)^{commit}')" = "$$(git rev-parse HEAD)" ] || \
		{ echo "Error: tag v$(VERSION) must exist locally and point at HEAD."; exit 1; }
	@$(MAKE) release
	gh release create "v$(VERSION)" "$(RELEASE_ZIP)" \
		--verify-tag \
		--title "v$(VERSION)" \
		--generate-notes

# Run unit tests
test:
	swift test

# Clean build artifacts
clean:
	swift package clean
	rm -rf "$(PROD_APP)" "$(DEBUG_APP)" "$(FLAVOR_DIR)"

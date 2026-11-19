.PHONY: build adapter app ci clean run notarize release test

APP_NAME = NanoWhisper
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
SIGN_IDENTITY ?= Moonji Dev
ENTITLEMENTS = Resources/NanoWhisper.entitlements

# Now Playing helper (Vendor/mediaremote-adapter): framework loaded by /usr/bin/perl
ADAPTER_DIR = Vendor/mediaremote-adapter
ADAPTER_BUILD_DIR = .build/mediaremote-adapter
ADAPTER_FRAMEWORK = $(ADAPTER_BUILD_DIR)/MediaRemoteAdapter.framework
ADAPTER_BINARY = $(ADAPTER_FRAMEWORK)/Versions/A/MediaRemoteAdapter
ADAPTER_SOURCES = $(shell find $(ADAPTER_DIR)/src $(ADAPTER_DIR)/include -type f)

# Shared bundle creation and signing steps
define BUNDLE_AND_SIGN
	@echo "Creating $(APP_BUNDLE)..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	@cp Resources/menubar_icon.png $(APP_BUNDLE)/Contents/Resources/
	@cp Resources/menubar_icon@2x.png $(APP_BUNDLE)/Contents/Resources/
	@cp Resources/start.m4a $(APP_BUNDLE)/Contents/Resources/
	@cp Resources/stop.m4a $(APP_BUNDLE)/Contents/Resources/
	@cp Resources/noResult.m4a $(APP_BUNDLE)/Contents/Resources/
	@mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	@ditto $(ADAPTER_FRAMEWORK) $(APP_BUNDLE)/Contents/Frameworks/MediaRemoteAdapter.framework
	@cp $(ADAPTER_DIR)/bin/mediaremote-adapter.pl $(APP_BUNDLE)/Contents/Resources/
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		codesign --force --deep --options runtime \
			--entitlements $(ENTITLEMENTS) \
			--sign "$(SIGN_IDENTITY)" $(APP_BUNDLE); \
	else \
		echo "Warning: No signing identity set. Using ad-hoc signing."; \
		codesign --force --deep --options runtime \
			--entitlements $(ENTITLEMENTS) \
			--sign - $(APP_BUNDLE); \
	fi
endef

# Build the Swift executable (release mode)
build:
	swift build -c release

# Build the Now Playing helper framework (rebuilt only when its sources change)
adapter: $(ADAPTER_BINARY)

$(ADAPTER_BINARY): $(ADAPTER_SOURCES) $(ADAPTER_DIR)/build-framework.sh $(ADAPTER_DIR)/LICENSE
	@echo "Building MediaRemoteAdapter.framework..."
	@$(ADAPTER_DIR)/build-framework.sh $(ADAPTER_BUILD_DIR)

# Create the .app bundle and launch it
app: build adapter
	$(BUNDLE_AND_SIGN)
	@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.3; open $(APP_BUNDLE)
	@echo "Done! $(APP_BUNDLE) launched."

# CI build: same as `app` but without launching (for GitHub Actions)
ci: build adapter
	$(BUNDLE_AND_SIGN)
	@echo "Done! $(APP_BUNDLE) created."

# Notarize the app for distribution (requires Developer ID certificate)
notarize: app
	@echo "Creating zip for notarization..."
	@ditto -c -k --keepParent $(APP_BUNDLE) $(APP_NAME).zip
	@echo "Submitting to Apple notary service..."
	xcrun notarytool submit $(APP_NAME).zip \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait
	@echo "Stapling notarization ticket..."
	xcrun stapler staple $(APP_BUNDLE)
	@rm -f $(APP_NAME).zip
	@echo "Notarization complete!"

# Run in development (without .app bundle)
run: build
	$(BUILD_DIR)/$(APP_NAME)

# Create a release zip for GitHub (run after `make app` or `make notarize`)
release: app
	@VERSION=$$(defaults read "$$(pwd)/$(APP_BUNDLE)/Contents/Info" CFBundleShortVersionString) && \
	echo "Creating release zip for v$$VERSION..." && \
	ditto -c -k --keepParent $(APP_BUNDLE) "$(APP_NAME)-v$$VERSION.zip" && \
	echo "Done! Upload $(APP_NAME)-v$$VERSION.zip to GitHub Releases with tag v$$VERSION"

# Run unit tests
test:
	swift test

# Clean build artifacts
clean:
	swift package clean
	rm -rf $(APP_BUNDLE) $(ADAPTER_BUILD_DIR)

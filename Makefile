.PHONY: build app ci clean run notarize release

APP_NAME = NanoWhisper
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
SIGN_IDENTITY ?= Moonji Dev
ENTITLEMENTS = Resources/NanoWhisper.entitlements

# Build the Swift executable (release mode)
build:
	swift build -c release

# Create the .app bundle
app: build
	@echo "Creating $(APP_BUNDLE)..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@# Copy executable
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	@# Copy Info.plist
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	@# Copy icon
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	@# Copy menubar icon
	@cp Resources/menubar_icon.png $(APP_BUNDLE)/Contents/Resources/
	@cp Resources/menubar_icon@2x.png $(APP_BUNDLE)/Contents/Resources/
	@# Copy sounds
	@cp Resources/start.m4a $(APP_BUNDLE)/Contents/Resources/
	@cp Resources/stop.m4a $(APP_BUNDLE)/Contents/Resources/
	@cp Resources/noResult.m4a $(APP_BUNDLE)/Contents/Resources/
	@# Sign with entitlements and hardened runtime
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		codesign --force --deep --options runtime \
			--entitlements $(ENTITLEMENTS) \
			--sign "$(SIGN_IDENTITY)" $(APP_BUNDLE); \
	else \
		echo "Warning: No signing identity set. Using ad-hoc signing (not suitable for distribution)."; \
		echo "Set NANOWHISPER_SIGN_IDENTITY env var for proper signing."; \
		codesign --force --deep --options runtime \
			--entitlements $(ENTITLEMENTS) \
			--sign - $(APP_BUNDLE); \
	fi
	@# Restart app if it was running
	@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.3; open $(APP_BUNDLE)
	@echo "Done! $(APP_BUNDLE) launched."

# CI build: same as `app` but without launching (for GitHub Actions)
ci: build
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
	@codesign --force --deep --options runtime \
		--entitlements $(ENTITLEMENTS) \
		--sign "$(SIGN_IDENTITY)" $(APP_BUNDLE)
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

# Clean build artifacts
clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

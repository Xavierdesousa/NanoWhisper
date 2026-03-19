.PHONY: build app clean run setup

APP_NAME = NanoWhisper
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
SIGN_IDENTITY = Moonji Dev

# Build the Swift executable (release mode)
build:
	swift build -c release

# Create the .app bundle
app: build
	@echo "Creating $(APP_BUNDLE)..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources/scripts
	@# Copy executable
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	@# Copy Info.plist
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	@# Copy icon
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	@# Copy sounds
	@cp Resources/start.m4a $(APP_BUNDLE)/Contents/Resources/
	@cp Resources/stop.m4a $(APP_BUNDLE)/Contents/Resources/
	@cp Resources/noResult.m4a $(APP_BUNDLE)/Contents/Resources/
	@# Copy scripts
	@cp scripts/transcribe.py $(APP_BUNDLE)/Contents/Resources/scripts/
	@cp scripts/setup.sh $(APP_BUNDLE)/Contents/Resources/scripts/
	@chmod +x $(APP_BUNDLE)/Contents/Resources/scripts/setup.sh
	@# Sign with local certificate (permissions persist across rebuilds)
	@codesign --force --deep --sign "$(SIGN_IDENTITY)" $(APP_BUNDLE) 2>/dev/null || \
		(echo "Signing with '$(SIGN_IDENTITY)' failed, falling back to ad-hoc"; codesign --force --deep --sign - $(APP_BUNDLE))
	@# Restart app if it was running
	@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.3; open $(APP_BUNDLE)
	@echo "Done! $(APP_BUNDLE) launched."

# Run in development (without .app bundle)
run: build
	$(BUILD_DIR)/$(APP_NAME)

# Install Python dependencies + download model (manual, optional)
setup:
	./scripts/setup.sh

# Clean build artifacts
clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

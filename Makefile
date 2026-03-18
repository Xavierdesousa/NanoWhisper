.PHONY: build app clean run setup

APP_NAME = NanoWhisper
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app

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
	@# Copy scripts
	@cp scripts/transcribe.py $(APP_BUNDLE)/Contents/Resources/scripts/
	@cp scripts/setup.sh $(APP_BUNDLE)/Contents/Resources/scripts/
	@chmod +x $(APP_BUNDLE)/Contents/Resources/scripts/setup.sh
	@# Ad-hoc sign (no Apple Developer account needed)
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "Done! $(APP_BUNDLE) is ready."
	@echo "Run: open $(APP_BUNDLE)"

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

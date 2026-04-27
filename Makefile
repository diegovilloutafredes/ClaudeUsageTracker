PROJECT  = ClaudeUsageTracker.xcodeproj
SCHEME   = ClaudeUsageTracker
APP      = ClaudeUsageTracker.app
ZIP      = release/ClaudeUsageTracker.zip

BUILD_DIR = release/build
DIST_DIR  = release/dist

.PHONY: release build clean

release: build
	@echo "==> Packaging..."
	@rm -rf $(DIST_DIR)
	@mkdir -p $(DIST_DIR)
	@cp -R $(BUILD_DIR)/$(APP) $(DIST_DIR)/$(APP)
	@cp install.command $(DIST_DIR)/install.command
	@chmod +x $(DIST_DIR)/install.command
	@rm -f $(ZIP)
	@cd $(DIST_DIR) && zip -rq "$(CURDIR)/$(ZIP)" .
	@echo ""
	@echo "  -> $(ZIP)"
	@echo "  Share this. Recipient unzips and double-clicks install.command."

build:
	@echo "==> Building..."
	@pkill -9 -f "$(APP)" 2>/dev/null || true
	@rm -rf ~/Library/Developer/Xcode/DerivedData/ClaudeUsageTracker-*
	@mkdir -p $(BUILD_DIR)
	xcodebuild -project $(PROJECT) \
	           -scheme $(SCHEME) \
	           -configuration Release \
	           -quiet \
	           clean build \
	           CONFIGURATION_BUILD_DIR="$(CURDIR)/$(BUILD_DIR)"

clean:
	@echo "==> Cleaning..."
	@pkill -9 -f "$(APP)" 2>/dev/null || true
	@rm -rf release
	@rm -rf ~/Library/Developer/Xcode/DerivedData/ClaudeUsageTracker-*

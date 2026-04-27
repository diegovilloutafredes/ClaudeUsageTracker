PROJECT  = ClaudeUsageTracker.xcodeproj
SCHEME   = ClaudeUsageTracker
APP      = ClaudeUsageTracker.app
ZIP      = release/ClaudeUsageTracker.zip

BUILD_DIR = release/build
DIST_DIR  = release/dist

# Override on CI: make build SIGNING_FLAGS="CODE_SIGNING_ALLOWED=NO"
SIGNING_FLAGS ?= CODE_SIGN_IDENTITY="-"

.PHONY: release build clean tag

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
	           CONFIGURATION_BUILD_DIR="$(CURDIR)/$(BUILD_DIR)" \
	           $(SIGNING_FLAGS)

tag:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make tag VERSION=1.0.0"; exit 1; fi
	@if [ -n "$$(git status --porcelain)" ]; then echo "Working directory is not clean — commit changes first"; exit 1; fi
	@sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $(VERSION)/g" $(PROJECT)/project.pbxproj
	git add $(PROJECT)/project.pbxproj
	git commit -m "Bump version to $(VERSION)"
	git tag -a "v$(VERSION)" -m "v$(VERSION)"
	git push origin main
	git push origin "v$(VERSION)"

clean:
	@echo "==> Cleaning..."
	@pkill -9 -f "$(APP)" 2>/dev/null || true
	@rm -rf release
	@rm -rf ~/Library/Developer/Xcode/DerivedData/ClaudeUsageTracker-*

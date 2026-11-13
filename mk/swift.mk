# Swift package (macos/) — app shell, platform layer, fixture, e2e harness.
SWIFT_PKG    := macos
DEV_DIR      := $(shell xcode-select -p)
APP_NAME     := hyprMac
BUNDLE_ID    := dev.codesmith28.hyprmac
APP_BUNDLE   := $(BUILD)/$(APP_NAME).app
SWIFT_CONF   ?= release
LIB_DIR_ABS  := $(abspath $(BUILD)/release)

# The core is always linked from the release build of libhyprcore.a.
SWIFT_LINK   := -Xlinker -L$(LIB_DIR_ABS)

# Command Line Tools (no Xcode) need explicit Swift Testing plugin/framework paths.
ifneq (,$(findstring CommandLineTools,$(DEV_DIR)))
  TESTING_FW   := $(DEV_DIR)/Library/Developer/Frameworks
  SWIFT_TESTING_FLAGS := -Xswiftc -plugin-path -Xswiftc $(DEV_DIR)/usr/lib/swift/host/plugins/testing \
                         -Xswiftc -F -Xswiftc $(TESTING_FW) -Xlinker -rpath -Xlinker $(TESTING_FW)
endif

.PHONY: swift-build swift-test app run test-e2e
ifneq ($(strip $(MODE)),release)
$(BUILD)/release/libhyprcore.a: FORCE
	$(MAKE) MODE=release core
.PHONY: FORCE
FORCE:
endif

swift-build: $(BUILD)/release/libhyprcore.a    ## build all Swift products
	swift build --package-path $(SWIFT_PKG) -c $(SWIFT_CONF) $(SWIFT_LINK)

swift-test: $(BUILD)/release/libhyprcore.a     ## run Swift Testing suites (FakeAX, coordinator)
	swift test --package-path $(SWIFT_PKG) $(SWIFT_LINK) $(SWIFT_TESTING_FLAGS) $(SWIFT_TEST_ARGS)

app: swift-build                               ## assemble + sign build/hyprMac.app (ad-hoc, or the local identity from make sign-identity)
	@BIN=$$(swift build --package-path $(SWIFT_PKG) -c $(SWIFT_CONF) $(SWIFT_LINK) --show-bin-path); \
	rm -rf $(APP_BUNDLE); \
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources/scripts/lib; \
	cp $$BIN/hyprMac $(APP_BUNDLE)/Contents/MacOS/hyprMac; \
	cp $$BIN/hyprmacctl $(APP_BUNDLE)/Contents/MacOS/hyprmacctl; \
	cp macos/Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist; \
	cp config/init.lua.example $(APP_BUNDLE)/Contents/Resources/; \
	if [ -f macos/Resources/AppIcon.icns ]; then cp macos/Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/; fi; \
	cp scripts/*.sh $(APP_BUNDLE)/Contents/Resources/scripts/ 2>/dev/null || true; \
	cp scripts/lib/*.sh $(APP_BUNDLE)/Contents/Resources/scripts/lib/ 2>/dev/null || true; \
	codesign --force --sign - --options runtime --identifier $(BUNDLE_ID).ctl $(APP_BUNDLE)/Contents/MacOS/hyprmacctl; \
	scripts/sign_identity.sh sign $(APP_BUNDLE); \
	echo "built $(APP_BUNDLE)"

run: app                                       ## run the app from build/ (foreground, logs to terminal)
	$(APP_BUNDLE)/Contents/MacOS/hyprMac

test-e2e: app                                  ## real-macOS end-to-end tests (needs Accessibility)
	@BIN=$$(swift build --package-path $(SWIFT_PKG) -c $(SWIFT_CONF) $(SWIFT_LINK) --show-bin-path); \
	$$BIN/hyprmac-e2e --app $(abspath $(APP_BUNDLE)) --fixture $$BIN/hyprmac-fixture $(E2E_ARGS)

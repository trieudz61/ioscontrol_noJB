ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = IOSControlApp

IOSControlApp_FILES = main.m AppDelegate.m \
	ICDaemonLauncher.m \
	ICScriptsViewController.m \
	ICConsoleViewController.m \
	ICDeviceViewController.m \
	ICSettingsViewController.m
IOSControlApp_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
IOSControlApp_FRAMEWORKS = UIKit CoreGraphics Foundation SafariServices UserNotifications
IOSControlApp_CODESIGN_FLAGS = -SEntitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

# ── Lua 5.4 source files (embedded, no interpreter/compiler) ──
LUA_SRCS = lua/lapi.c lua/lauxlib.c lua/lbaselib.c lua/lcode.c lua/lcorolib.c \
           lua/lctype.c lua/ldblib.c lua/ldebug.c lua/ldo.c lua/ldump.c \
           lua/lfunc.c lua/lgc.c lua/linit.c lua/liolib.c lua/llex.c \
           lua/lmathlib.c lua/lmem.c lua/loadlib.c lua/lobject.c lua/lopcodes.c \
           lua/loslib.c lua/lparser.c lua/lstate.c lua/lstring.c lua/lstrlib.c \
           lua/ltable.c lua/ltablib.c lua/ltm.c lua/lundump.c lua/lutf8lib.c \
           lua/lvm.c lua/lzio.c

# ── Build daemon binary separately ──
after-stage::
	@echo "📦 Compiling IOSControlDaemon..."
	$(TARGET_CC) -arch arm64 \
		-isysroot $(THEOS)/sdks/iPhoneOS16.5.sdk \
		-fobjc-arc -framework Foundation -framework IOKit \
		-framework CoreGraphics -framework ImageIO -framework IOSurface \
		-framework UIKit -framework QuartzCore -framework Vision \
		-framework UserNotifications \
		-Wno-deprecated-declarations -Wno-arc-performSelector-leaks \
		-Ilua -DLUA_USE_IOS \
		IOSControlDaemon.m ICHTTPServer.m ICScreenCapture.m ICLuaEngine.m ICVision.m \
		ICScriptManager.m ICAppControl.m ICKeyInput.m ICLuaStdlib.m \
		$(LUA_SRCS) \
		-o $(THEOS_STAGING_DIR)/Applications/IOSControlApp.app/IOSControlDaemon \
		2>/dev/null || \
	xcrun -sdk iphoneos clang -arch arm64 \
		-fobjc-arc -framework Foundation -framework IOKit \
		-framework CoreGraphics -framework ImageIO -framework IOSurface \
		-framework UIKit -framework QuartzCore -framework Vision -framework UserNotifications \
		-Wno-deprecated-declarations \
		-Ilua -DLUA_USE_IOS \
		IOSControlDaemon.m ICHTTPServer.m ICScreenCapture.m ICLuaEngine.m ICVision.m \
		ICScriptManager.m ICAppControl.m ICKeyInput.m ICLuaStdlib.m \
		$(LUA_SRCS) \
		-o $(THEOS_STAGING_DIR)/Applications/IOSControlApp.app/IOSControlDaemon
	@echo "🔏 Signing daemon with entitlements..."
	ldid -SEntitlements.plist $(THEOS_STAGING_DIR)/Applications/IOSControlApp.app/IOSControlDaemon
	@echo "📦 Compiling ICToastService.app..."
	$(eval TOAST_APP := $(THEOS_STAGING_DIR)/Applications/IOSControlApp.app/ICToastService.app)
	@rm -rf $(TOAST_APP)
	@mkdir -p $(TOAST_APP)
	xcrun -sdk iphoneos clang -arch arm64 \
		-fobjc-arc -framework Foundation -framework UIKit -framework CoreFoundation -framework CoreGraphics \
		-Wno-deprecated-declarations \
		ICToastService.m \
		-o $(TOAST_APP)/ICToastService
	@echo "🔏 Signing ICToastService with display entitlements..."
	ldid -SICToastService-Entitlements.plist $(TOAST_APP)/ICToastService
	@cp ICToastService-Info.plist $(TOAST_APP)/Info.plist

	@echo "📁 Copying static web files..."
	cp -r static/ $(THEOS_STAGING_DIR)/Applications/IOSControlApp.app/static/
	@echo "📦 Building TrollStore .tipa..."
	rm -rf Payload
	mkdir -p Payload
	cp -r $(THEOS_STAGING_DIR)/Applications/IOSControlApp.app Payload/
	zip -r9 IOSControlApp.tipa Payload/
	rm -rf Payload
	@echo "✅ Tipa built: IOSControlApp.tipa"
	@echo "   App launches daemon via posix_spawn()"
	@echo "   Web IDE: http://<IP>:46952/"
	@echo "   Lua API: sys/touch/screen + screen.ocr/find_color/find_multi_color"
	@echo "   Phase 7: app.launch/kill/list + key.press/input_text + clipboard.read/write + script files"
	@echo ""
	@echo "🌐 Starting download server on port 8080..."
	@lsof -ti:8080 | xargs kill -9 2>/dev/null || true
	@MAC_IP=$$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "localhost"); \
	 echo "📲 Download tipa at: http://$$MAC_IP:8080/IOSControlApp.tipa"; \
	 python3 -m http.server 8080 &

# Reachy Control Max Edition — Makefile
# Builds a native macOS .app bundle with embedded CPython

APP_NAME    = ReachyControl
BUNDLE      = $(APP_NAME).app
BINARY      = $(BUNDLE)/Contents/MacOS/$(APP_NAME)
DESKTOP_APP = $(HOME)/Desktop/$(BUNDLE)

# Python 3.12 (uv-managed)
PY_PREFIX   = /Users/maxl/.local/share/uv/python/cpython-3.12.12-macos-aarch64-none
PY_INCLUDES = -I$(PY_PREFIX)/include/python3.12
PY_LDFLAGS  = -L$(PY_PREFIX)/lib -lpython3.12 -ldl -framework CoreFoundation
PY_RPATH    = -Wl,-rpath,$(PY_PREFIX)/lib

# venv site-packages (populated by setup_env.sh)
VENV_DIR    = python/.venv

# Compiler
CC          = clang
CFLAGS      = -Wall -Wno-deprecated-declarations -fobjc-arc \
              $(PY_INCLUDES) -DREACHY_VENV=\"$(abspath $(VENV_DIR))\" \
              -DREACHY_BRIDGE_PY=\"$(abspath python/bridge.py)\"
LDFLAGS     = $(PY_LDFLAGS) $(PY_RPATH) \
              -framework AppKit -framework Foundation -framework CoreGraphics \
              -framework QuartzCore -framework Speech -framework AVFoundation \
              -framework WebKit

SRCS = src/main.m \
       src/AppDelegate.m \
       src/PythonBridge.m \
       src/HTTPClient.m \
       src/panels/CameraPanel.m \
       src/panels/AntennaPanel.m \
       src/panels/MotorPanel.m \
       src/panels/BehaviorsPanel.m \
       src/panels/TerminalPanel.m \
       src/panels/DashboardPanel.m \
       src/panels/RubikCoachPanel.m \
       src/panels/ChatPanel.m \
       src/widgets/JoystickView.m

OBJS = $(SRCS:.m=.o)

.PHONY: all clean install env desktop

all: env $(BUNDLE)

env:
	@bash python/setup_env.sh

%.o: %.m
	$(CC) $(CFLAGS) -c $< -o $@

$(BUNDLE): $(OBJS) resources/ReachyControl.icns
	@mkdir -p $(BUNDLE)/Contents/{MacOS,Resources}
	$(CC) $(OBJS) $(LDFLAGS) -o $(BINARY)
	@cp python/bridge.py $(BUNDLE)/Contents/Resources/bridge.py
	@cp python/live_chat.py $(BUNDLE)/Contents/Resources/live_chat.py
	@cp resources/reachy-mini-sleeping.svg $(BUNDLE)/Contents/Resources/reachy-mini-sleeping.svg
	@cp resources/reachy-mini-awake.svg $(BUNDLE)/Contents/Resources/reachy-mini-awake.svg
	@cp resources/reachy-mini-ko.svg $(BUNDLE)/Contents/Resources/reachy-mini-ko.svg
	@cp resources/ReachyControl.icns $(BUNDLE)/Contents/Resources/ReachyControl.icns
	@if [ -f .env ]; then cp .env $(BUNDLE)/Contents/Resources/.env; fi
	@if [ -d python/dashboard-v2 ]; then rm -rf $(BUNDLE)/Contents/Resources/dashboard-v2; cp -R python/dashboard-v2 $(BUNDLE)/Contents/Resources/dashboard-v2; fi
	@if [ -d apps/reachy_mini_rubik_coach_app ]; then mkdir -p $(BUNDLE)/Contents/Resources/apps; rm -rf $(BUNDLE)/Contents/Resources/apps/reachy_mini_rubik_coach_app; cp -R apps/reachy_mini_rubik_coach_app $(BUNDLE)/Contents/Resources/apps/; fi
	@cp -r $(VENV_DIR) $(BUNDLE)/Contents/Resources/venv
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(BUNDLE)/Contents/Info.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(BUNDLE)/Contents/Info.plist
	@echo '<plist version="1.0"><dict>' >> $(BUNDLE)/Contents/Info.plist
	@echo '  <key>CFBundleName</key><string>$(APP_NAME)</string>' >> $(BUNDLE)/Contents/Info.plist
	@echo '  <key>CFBundleIdentifier</key><string>com.reachymini.control</string>' >> $(BUNDLE)/Contents/Info.plist
	@echo '  <key>CFBundleVersion</key><string>1.0</string>' >> $(BUNDLE)/Contents/Info.plist
	@echo '  <key>CFBundleExecutable</key><string>$(APP_NAME)</string>' >> $(BUNDLE)/Contents/Info.plist
	@echo '  <key>CFBundleIconFile</key><string>ReachyControl</string>' >> $(BUNDLE)/Contents/Info.plist
	@echo '  <key>NSPrincipalClass</key><string>NSApplication</string>' >> $(BUNDLE)/Contents/Info.plist
	@echo '  <key>NSHighResolutionCapable</key><true/>' >> $(BUNDLE)/Contents/Info.plist
	@echo '  <key>LSMinimumSystemVersion</key><string>13.0</string>' >> $(BUNDLE)/Contents/Info.plist
	@echo '  <key>NSCameraUsageDescription</key><string>Camera feed from the Reachy robot</string>' >> $(BUNDLE)/Contents/Info.plist
	@echo '  <key>NSMicrophoneUsageDescription</key><string>Voice input for chatting with the robot</string>' >> $(BUNDLE)/Contents/Info.plist
	@echo '  <key>NSSpeechRecognitionUsageDescription</key><string>Transcribe voice input for robot chat</string>' >> $(BUNDLE)/Contents/Info.plist
	@echo '  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>' >> $(BUNDLE)/Contents/Info.plist
	@echo '</dict></plist>' >> $(BUNDLE)/Contents/Info.plist
	@echo "Built: $(BUNDLE)"

resources/ReachyControl.icns:
	$(VENV_DIR)/bin/python resources/make_icon.py

install: all
	cp -r $(BUNDLE) /Applications/$(BUNDLE)
	@echo "Installed to /Applications/$(BUNDLE)"

desktop: all
	rm -rf "$(DESKTOP_APP)"
	ln -s "$(abspath $(BUNDLE))" "$(DESKTOP_APP)"
	@echo "Linked on Desktop: $(DESKTOP_APP)"

clean:
	rm -f $(OBJS)
	rm -rf $(BUNDLE)

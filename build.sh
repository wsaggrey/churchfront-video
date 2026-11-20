#!/bin/zsh
# Builds "Churchfront Video.app" (release) next to this script.
# The executable inside, the bundle ID and the MCP binary keep their CueVideo names on purpose.
set -e
cd "$(dirname "$0")"
MODE=${1:-release}
swift build -c $MODE
BIN="$(swift build -c $MODE --show-bin-path)/CueVideo"
APP="Churchfront Video.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CueVideo"
cp "$(dirname "$BIN")/cuevideo-mcp" "$APP/Contents/MacOS/cuevideo-mcp"
cp Resources/Figtree-VariableFont_wght.ttf "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Churchfront Video</string>
  <key>CFBundleDisplayName</key><string>Churchfront Video</string>
  <key>CFBundleIdentifier</key><string>com.churchfront.cuevideo</string>
  <key>CFBundleExecutable</key><string>CueVideo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Churchfront Video controls your ATEM switcher and PTZ cameras and shows NDI video from your network.</string>
  <key>NSCameraUsageDescription</key><string>Churchfront Video shows the ATEM switcher's USB video output, so cameras with no network picture (HDMI only) can be seen in the monitors. It never uses this Mac's own camera.</string>
  <key>NSBonjourServices</key><array><string>_ndi._tcp</string><string>_blackmagic._tcp</string><string>_http._tcp</string></array>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
# Tell Finder and the Dock the bundle changed, so they drop the icon they remembered.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
echo "Built $(pwd)/$APP"

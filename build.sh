#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/dist/常亮.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$PWD/.build/module-cache"
xcrun swiftc -module-cache-path "$PWD/.build/module-cache" Sources/main.swift Sources/ScreenSaver.swift -o "$APP/Contents/MacOS/StayVisible" -framework AppKit -framework IOKit -target arm64-apple-macosx13.0
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.j.stayvisible</string>
<key>CFBundleName</key><string>常亮</string>
<key>CFBundleDisplayName</key><string>常亮</string>
<key>CFBundleExecutable</key><string>StayVisible</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
"$APP/Contents/MacOS/StayVisible" --self-test
codesign --verify --strict "$APP"
echo "Built: $APP"

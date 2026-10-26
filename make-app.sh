#!/bin/zsh
# release 빌드 후 build/Widgent.app 번들 생성
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Widgent.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Widgent "$APP/Contents/MacOS/Widgent"
mkdir -p "$APP/Contents/Resources"
cp -R Resources/logos "$APP/Contents/Resources/logos"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Widgent</string>
    <key>CFBundleIdentifier</key><string>com.widgent.app</string>
    <key>CFBundleExecutable</key><string>Widgent</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "완료: $APP"

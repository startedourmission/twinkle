#!/bin/zsh
# release 빌드 후 build/Twinkle.app 번들 생성
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Twinkle.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Twinkle "$APP/Contents/MacOS/Twinkle"
mkdir -p "$APP/Contents/Resources"
cp -R Resources/logos "$APP/Contents/Resources/logos"
cp Resources/AppIcon.icns Resources/StatusIcon.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Twinkle</string>
    <key>CFBundleIdentifier</key><string>com.twinkle.app</string>
    <key>CFBundleExecutable</key><string>Twinkle</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <!-- 위젯에서 할 일을 누르면 twinkle://todo?… 로 앱이 열림 -->
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>com.twinkle.app</string>
        <key>CFBundleURLSchemes</key><array><string>twinkle</string></array>
    </dict></array>
</dict>
</plist>
PLIST

# 위젯 확장: Contents/PlugIns/TwinkleWidgets.appex
EXT="$APP/Contents/PlugIns/TwinkleWidgets.appex"
mkdir -p "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
cp .build/release/TwinkleWidgets "$EXT/Contents/MacOS/TwinkleWidgets"
cp -R Resources/logos "$EXT/Contents/Resources/logos"
cat > "$EXT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TwinkleWidgets</string>
    <key>CFBundleDisplayName</key><string>Twinkle</string>
    <key>CFBundleIdentifier</key><string>com.twinkle.app.widgets</string>
    <key>CFBundleExecutable</key><string>TwinkleWidgets</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSExtension</key>
    <dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict>
</plist>
PLIST
# 임시 서명(ad-hoc). 인증서로 서명하지 않음: 폐기된 인증서로 서명하면 macOS가 악성코드로 보고 앱을 지움.
# 대신 "식별자가 com.twinkle.app이면 같은 앱"이라는 기준을 넣어, 다시 빌드해도 macOS 권한을 알아보게 함
# 위젯 먼저 (샌드박스 권한 포함), 그다음 앱
codesign --force --sign - --entitlements Resources/TwinkleWidgets.entitlements -r='designated => identifier "com.twinkle.app.widgets"' "$EXT"
codesign --force --sign - -r='designated => identifier "com.twinkle.app"' "$APP"
echo "완료: $APP"

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
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Twinkle</string>
    <key>CFBundleIdentifier</key><string>com.twinkle.app</string>
    <key>CFBundleExecutable</key><string>Twinkle</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# 고정된 서명(Apple Development)이 있으면 그걸로 서명: 그래야 손쉬운 사용·화면 녹음 같은 권한이
# 다시 빌드해도 유지됨 (임시 서명은 빌드마다 코드 해시가 바뀌어 권한이 풀림)
IDENTITY="${TWINKLE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "완료: $APP"

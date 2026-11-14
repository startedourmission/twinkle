#!/bin/zsh
# 판매용 배포 파일 만들기: make-app.sh로 빌드 → Developer ID로 다시 서명 → DMG → Apple 공증 → 확인
#
# 처음 한 번 (Apple 개발자 프로그램 가입 후):
#   1) Xcode > Settings > Accounts > Manage Certificates > + > "Developer ID Application"
#   2) 공증용 암호를 키체인에 저장 (앱 암호는 account.apple.com > 로그인 및 보안 > 앱 암호에서)
#      xcrun notarytool store-credentials twinkle-notary --apple-id <Apple ID> --team-id <팀 ID> --password <앱 암호>
#
# 실행:
#   TWINKLE_SIGN_ID="Developer ID Application: 이름 (팀 ID)" ./release.sh
#
# 결과: build/Twinkle-<버전>.dmg (Gumroad 상품 파일로 올림)
# 평소 개발용 빌드는 그대로 make-app.sh (ad-hoc 서명)
set -e
cd "$(dirname "$0")"

SIGN_ID=${TWINKLE_SIGN_ID:?"TWINKLE_SIGN_ID에 Developer ID Application 인증서 이름을 넣어 주세요 (security find-identity -v -p codesigning)"}
PROFILE=${TWINKLE_NOTARY_PROFILE:-twinkle-notary}

case "$SIGN_ID" in
    "Developer ID Application:"*) ;;
    *) echo "Developer ID Application 인증서만 씁니다 (Apple Development 인증서는 배포용이 아니고, 폐기된 걸로 서명하면 macOS가 앱을 지움)" >&2; exit 1 ;;
esac

./make-app.sh
APP=build/Twinkle.app
EXT="$APP/Contents/PlugIns/TwinkleWidgets.appex"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

# 공증에는 Hardened Runtime(--options runtime)과 보안 타임스탬프가 필요. 위젯 먼저, 그다음 앱
codesign --force --options runtime --timestamp --entitlements Resources/TwinkleWidgets.entitlements --sign "$SIGN_ID" "$EXT"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# DMG: 앱 + 응용 프로그램 폴더 바로 가기 (끌어다 놓아 설치)
DMG="build/Twinkle-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Twinkle.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Twinkle" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

# 공증 (몇 분 걸림). 인증서가 폐기됐거나 문제가 있으면 여기서 거절됨
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# 산 사람 Mac에서처럼 Gatekeeper가 받아 주는지 확인. "source=Notarized Developer ID"가 나와야 함
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "완료: $DMG"

#!/bin/bash
# Builds the DMG for distribution: Developer ID signature, notarization, stapling and checks.
# Publishing to GitHub Releases is left to a person.
#   scripts/release.sh                → build/HanaLima-<version>.dmg, notarized by Apple
#   scripts/release.sh --no-notarize  → stop after the signed DMG (nothing is sent to Apple)
#
# Needs, in the login keychain:
#   - the Developer ID Application certificate and its private key
#   - notarytool credentials (saved with `xcrun notarytool store-credentials`)
# Pass SIGN_IDENTITY / NOTARY_PROFILE to use others.
set -euo pipefail

APP_NAME="HanaLima"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Yukimitsu Izawa (FJYY683YHH)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-developer-id-notary}"

NOTARIZE=1
case "${1:-}" in
    "") ;;
    --no-notarize) NOTARIZE=0 ;;
    *) echo "使い方: $0 [--no-notarize]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# The build number is the commit count, so local changes would give a different DMG the same number.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "✗ コミットしていない変更があります。コミットしてから実行してください。" >&2
    exit 1
fi

# The driver's provisioning profile (docs/19): without it the release couldn't pass USB
# accessories to VMs. It lives outside the repository.
DRIVER_PROFILE="${HANALIMA_DRIVER_PROFILE:-$HOME/Library/Developer/HanaLima/HanaLima_Driver_Developer_ID.provisionprofile}"
PROFILE_PLIST="$(mktemp)"
trap 'rm -f "$PROFILE_PLIST"' EXIT
security cms -D -i "$DRIVER_PROFILE" > "$PROFILE_PLIST" 2>/dev/null \
    || { echo "✗ ドライバーのプロビジョニングプロファイルが読めません: $DRIVER_PROFILE（docs/13）" >&2; exit 1; }
[[ "$(plutil -extract Entitlements.com\\.apple\\.application-identifier raw -o - "$PROFILE_PLIST")" == "FJYY683YHH.org.izawa.HanaLima.driver" ]] \
    || { echo "✗ プロファイルの App ID が org.izawa.HanaLima.driver ではありません: $DRIVER_PROFILE" >&2; exit 1; }
[[ "$(plutil -extract Entitlements.com\\.apple\\.developer\\.accessory-access\\.usb raw -o - "$PROFILE_PLIST" 2>/dev/null)" == "true" ]] \
    || { echo "✗ プロファイルが USB の entitlement（Claim USB Accessory）を許していません: $DRIVER_PROFILE" >&2; exit 1; }
EXPIRES="$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST")"
[[ "$EXPIRES" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] \
    || { echo "✗ プロファイルの期限が切れています（$EXPIRES）: $DRIVER_PROFILE" >&2; exit 1; }

SIGN_IDENTITY="$SIGN_IDENTITY" HANALIMA_DRIVER_PROFILE="$DRIVER_PROFILE" scripts/make-app.sh

APP="$ROOT/build/$APP_NAME.app"
echo "▶ 署名を確認"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign -d --entitlements - "$APP/Contents/Helpers/HanaLimaDriver.app" 2>/dev/null \
    | grep -q "com.apple.developer.accessory-access.usb" \
    || { echo "✗ ドライバーに USB の entitlement がありません" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"

echo "▶ $DMG を作成"
scripts/make_dmg.sh "$APP" "$DMG" "$APP_NAME $VERSION"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"

if [[ $NOTARIZE == 0 ]]; then
    echo "✓ 署名した DMG を作りました（公証はしていません）: $DMG"
    exit 0
fi

echo "▶ 公証を申請（数分かかる）"
# Don't stop here when notarytool fails, so that the log with the reason is still printed.
RESULT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$RESULT"
if ! grep -q "status: Accepted" <<<"$RESULT"; then
    ID="$(awk '/^ *id:/ { print $2; exit }' <<<"$RESULT")"
    echo "✗ 公証が通りませんでした。理由は次のログを見てください。" >&2
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
fi

echo "▶ 公証の結果を DMG に付ける"
xcrun stapler staple "$DMG"

echo "▶ 確かめ"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
shasum -a 256 "$DMG"
echo "✓ 配布できる DMG ができました: $DMG"

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

SIGN_IDENTITY="$SIGN_IDENTITY" scripts/make-app.sh

APP="$ROOT/build/$APP_NAME.app"
echo "▶ 署名を確認"
codesign --verify --strict --deep --verbose=2 "$APP"
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

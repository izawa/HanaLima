#!/bin/bash
# Builds a release HanaLima.app and optionally installs it into /Applications.
#   scripts/make-app.sh                    → build/HanaLima.app (release)
#   scripts/make-app.sh --install          → also copy it to /Applications
#   scripts/make-app.sh --install --open   → and launch the installed copy
#
# Assembly and signing are done by scripts/build-app.sh: the network helper must be signed with
# its own entitlements (com.apple.security.virtualization), which `codesign --deep` would strip.
# Info.plist (bundle ID, icon, copyright) comes from Resources/Info.plist; this script only stamps
# the build number. The signature is ad hoc, for this Mac only.
set -euo pipefail

APP_NAME="HanaLima"
BUNDLE_ID="org.izawa.HanaLima"
DEST="/Applications/$APP_NAME.app"

INSTALL=false
OPEN=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --open) OPEN=true ;;
        *) echo "使い方: $0 [--install [--open]]" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/$APP_NAME.app"

echo "▶ リリースビルドと組み立て"
scripts/build-app.sh release

# Build number = number of commits, so each install is distinguishable in the About panel.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
printf "APPL????" > "$APP/Contents/PkgInfo"
# Info.plist changed, so sign the app again (not --deep: the helper keeps its own signature).
codesign --force --sign - --entitlements "$ROOT/Resources/HanaLima.entitlements" "$APP" >/dev/null

echo "▶ 署名を確認"
codesign --verify --strict "$APP"
codesign -d --entitlements - "$APP/Contents/Helpers/hanalima-netd" 2>/dev/null \
    | grep -q "com.apple.security.virtualization" \
    || { echo "✗ ヘルパーに com.apple.security.virtualization がありません" >&2; exit 1; }
codesign -d --entitlements - "$APP" 2>/dev/null \
    | grep -q "com.apple.security.virtualization" \
    || { echo "✗ アプリに com.apple.security.virtualization がありません" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
echo "  ${APP_NAME} ${VERSION} (${BUILD_NUMBER})"

if ! $INSTALL; then
    echo "✓ 作成しました: ${APP}"
    echo "  /Applications に入れるには: scripts/make-app.sh --install"
    exit 0
fi

echo "▶ ${DEST} にインストール"
# HanaLima stays in the menu bar after its window closes, so ask it to quit and wait for it.
if pgrep -xq "$APP_NAME"; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -xq "$APP_NAME" || break; sleep 0.1; done
    if pgrep -xq "$APP_NAME"; then
        echo "✗ ${APP_NAME} が終了しませんでした。メニューバーのアイコンから終了してから、もう一度実行してください。" >&2
        exit 1
    fi
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
# Refresh Launch Services so Finder, Dock and Spotlight pick up the new icon and version.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
echo "✓ インストールしました: ${DEST}（Launchpad や Spotlight から起動できます）"

if $OPEN; then
    open "$DEST"
fi

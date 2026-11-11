#!/bin/bash
# Builds the styled DMG (unsigned; scripts/release.sh signs it next).
#   scripts/make_dmg.sh <app> <output.dmg> <volume name>
#
# Uses the images in Resources/DMG (drawn by scripts/make_dmg_art.py):
#   - the opened window: 540x380, an arrow in the background, the app on the left and Applications on the right
#   - the mounted disk's icon: VolumeIcon.icns
# Finder sets the window up through AppleScript and keeps it in the DMG's .DS_Store, so this
# runs on a Mac with a screen, and asks once for permission to control Finder.
set -euo pipefail

APP="$1"; OUT="$2"; VOLNAME="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ART="$ROOT/Resources/DMG"
APP_NAME="$(basename "$APP")"
MOUNT="/Volumes/$VOLNAME"

if [[ -e "$MOUNT" ]]; then
    echo "✗ $MOUNT が使われています。取り出してから実行してください。" >&2
    exit 1
fi

WORK="$(mktemp -d)"
cleanup() {
    [[ -d "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force || true
    rm -rf "$WORK"
}
trap cleanup EXIT

STAGING="$WORK/staging"
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Applications"
cp "$ART/background.tiff" "$STAGING/.background/background.tiff"

# A writable image with room for .DS_Store, set up by Finder, then compressed.
SIZE_MB=$(( $(du -sm "$STAGING" | cut -f1) + 20 ))
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$WORK/rw.dmg" >/dev/null
hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen -quiet

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- The window frame: the title bar is added so that the content is 540x380.
        set the bounds of container window to {200, 120, 740, 528}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "$APP_NAME" of container window to {140, 180}
        set position of item "Applications" of container window to {400, 180}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

for _ in $(seq 1 20); do [[ -f "$MOUNT/.DS_Store" ]] && break; sleep 0.5; done
[[ -f "$MOUNT/.DS_Store" ]] || { echo "✗ Finder が .DS_Store を書きませんでした" >&2; exit 1; }
# The icon goes in after mounting and after Finder's setup: put in -srcfolder it did not reach
# the DMG, and Finder cleared the custom icon flag when it was set before the setup (2026-11-11).
cp "$ART/VolumeIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -c icnC "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"
[[ "$(GetFileInfo -a "$MOUNT")" == *C* ]] || { echo "✗ ボリュームにカスタムアイコンの印が付いていません" >&2; exit 1; }
sync
hdiutil detach "$MOUNT" -quiet

rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "✓ $OUT"

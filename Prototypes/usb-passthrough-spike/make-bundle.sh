#!/bin/sh
# Builds the product layout of docs/19 for the spike: the driver as the main executable of a
# nested app bundle, build/usb-spike/HanaLima.app/Contents/Helpers/HanaLimaDriver.app, with bundle
# ID org.izawa.HanaLima.driver, its Developer ID provisioning profile and the USB entitlement.
# The outer app is only a container here. See README.md for how to run it.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
profile=${HANALIMA_DRIVER_PROFILE:-$HOME/Library/Developer/HanaLima/HanaLima_Driver_Developer_ID.provisionprofile}
identity=${SIGN_IDENTITY:-Developer ID Application: Yukimitsu Izawa (FJYY683YHH)}
outer="$root/build/usb-spike/HanaLima.app"
app="$outer/Contents/Helpers/HanaLimaDriver.app"

(cd "$root/Driver" && swift build -c debug)
bin=$(cd "$root/Driver" && swift build -c debug --show-bin-path)/lima-driver-hanalima

rm -rf "$root/build/usb-spike"
mkdir -p "$app/Contents/MacOS" "$outer/Contents/MacOS"
/bin/cp -f "$bin" "$app/Contents/MacOS/lima-driver-hanalima"
/bin/cp -f "$profile" "$app/Contents/embedded.provisionprofile"
plist() { # bundle-id name executable
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>$1</string>
	<key>CFBundleName</key><string>$2</string>
	<key>CFBundleExecutable</key><string>$3</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>27.0</string>
</dict>
</plist>
PLIST
}
plist org.izawa.HanaLima.driver "HanaLima Driver" lima-driver-hanalima > "$app/Contents/Info.plist"
plist org.izawa.HanaLima.usbspike "HanaLima USB Spike" placeholder > "$outer/Contents/Info.plist"
printf '#!/bin/sh\nexit 0\n' > "$outer/Contents/MacOS/placeholder"; chmod +x "$outer/Contents/MacOS/placeholder"
# Inside out: the nested app first, the container last.
codesign --force --options runtime --timestamp=none --sign "$identity" --entitlements "$here/entitlements.plist" "$app"
codesign --force --options runtime --timestamp=none --sign "$identity" "$outer"
codesign --verify --strict --deep --verbose=1 "$outer"
codesign -d --entitlements - "$app" 2>/dev/null | grep -A2 application-identifier
echo "$app/Contents/MacOS"

#!/bin/zsh
# Export the Godot project to Xcode, build + sign for a connected iPhone,
# install it and (optionally) launch with the console attached.
#
# usage: tools/run_ios.sh [--launch]
# env:   IOS_DEVICE (UDID, default: first paired physical iPhone)
#        IOS_TEAM   (Apple team ID, default: ASATW3RAPQ = Personal Team "linh le")
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM="${IOS_TEAM:-ASATW3RAPQ}"
BUNDLE_ID="$(sed -n 's/^application\/bundle_identifier="\(.*\)"$/\1/p' export_presets.cfg)"
DEVICE="${IOS_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | grep -E '(connected|available).*iPhone.*physical' | head -1 | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}')}"
[[ -n "$DEVICE" ]] || { echo "No paired iPhone found"; exit 1; }

rm -rf build/ios && mkdir -p build/ios
godot --headless --path . --export-debug iOS build/ios/VibeGameOne.ipa > build/export_ios.log 2>&1 \
	|| { grep -E "ERROR" -A1 build/export_ios.log; exit 1; }

xcodebuild -project build/ios/VibeGameOne.xcodeproj -scheme VibeGameOne -configuration Debug \
	-destination "id=$DEVICE" -derivedDataPath build/ios/dd -allowProvisioningUpdates \
	DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
	PROVISIONING_PROFILE_SPECIFIER= build > build/xcodebuild.log 2>&1 \
	|| { grep -E "error:" build/xcodebuild.log | sort -u; exit 1; }

xcrun devicectl device install app --device "$DEVICE" build/ios/dd/Build/Products/Debug-iphoneos/VibeGameOne.app > /dev/null
echo "Installed on $DEVICE"

if [[ "${1:-}" == "--launch" ]]; then
	xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --console "$BUNDLE_ID"
fi

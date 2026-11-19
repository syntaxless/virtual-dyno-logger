#!/bin/bash
# App Store screenshots from the iOS Simulator, in screenshot mode (see App/Model/Demo.swift).
#
#   tools/screenshots.sh                          # iPhone 16 Pro Max: 1320x2868, the 6.9" size App Store Connect asks for
#   DEVICE="iPhone 16 Plus" tools/screenshots.sh  # 1290x2796, the 6.7" size, if you want it as well
#
# Builds the app, boots the simulator, sets a clean status bar (9:41, full battery), launches each screen with made-up
# devices and data, and writes PNGs to screenshots/<device>/. Run from the repository root on a Mac with Xcode and xcodegen.
set -euo pipefail
DEVICE="${DEVICE:-iPhone 16 Pro Max}"
BUNDLE=com.itschefff.virtualdynologger
OUT="screenshots/${DEVICE// /_}"
mkdir -p "$OUT"

[ -d DynoLogger.xcodeproj ] || xcodegen
xcodebuild -quiet -project DynoLogger.xcodeproj -scheme DynoLogger -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
APP=build/Build/Products/Debug-iphonesimulator/DynoLogger.app

# The simulator called $DEVICE, or a new one of that model on the newest installed iOS runtime.
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
d = json.load(sys.stdin)['devices']
print(next((x['udid'] for k, r in d.items() if 'iOS' in k for x in r if x['name'] == sys.argv[1]), ''))" "$DEVICE")
if [ -z "$UDID" ]; then
  RUNTIME=$(xcrun simctl list runtimes available -j | python3 -c "
import json, sys
r = [x for x in json.load(sys.stdin)['runtimes'] if x['platform'] == 'iOS']
print(max(r, key=lambda x: [int(p) for p in x['version'].split('.')])['identifier'] if r else '')")
  [ -n "$RUNTIME" ] || { echo "No iOS Simulator runtime installed (Xcode > Settings > Components)"; exit 1; }
  UDID=$(xcrun simctl create "$DEVICE" "com.apple.CoreSimulator.SimDeviceType.${DEVICE// /-}" "$RUNTIME")
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance dark
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

shot() {   # shot <file name> <seconds to wait> <launch arguments...>
  local name=$1 wait=$2; shift 2
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE" -demo "$@" >/dev/null
  sleep "$wait"
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null
  echo "$OUT/$name.png"
}

shot 1_record_live    8.5 -demoTab record -demoRecording   # mid-pull (about 6,000 RPM), recording, timer running
shot 2_runs           3   -demoTab runs
shot 3_devices        3   -demoTab devices
shot 4_record_idle    2   -demoTab record                  # cruising before a pull, not recording
shot 5_about          3   -demoTab about
xcrun simctl status_bar "$UDID" clear

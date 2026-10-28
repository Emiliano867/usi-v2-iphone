#!/bin/bash
# Native Auto Layout smoke checks and screenshots; macOS + Xcode only.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
output_dir=${1:?Supply an artifact directory}
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
probe_tmp=$(mktemp -d)
probe_device=
cleanup() {
    if [[ -n "$probe_device" ]]; then
        xcrun simctl shutdown "$probe_device" >/dev/null 2>&1 || true
        xcrun simctl delete "$probe_device" >/dev/null 2>&1 || true
    fi
    rm -rf "$probe_tmp"
}
trap cleanup EXIT
runtime=$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and x["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]; assert r,"No available iOS simulator runtime"; print(max(r,key=lambda x:tuple(map(int,x["version"].split("."))))["identifier"])')
sim_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
probe_app="$probe_tmp/USILayoutProbe.app"
mkdir -p "$probe_app"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -parse-as-library \
    -sdk "$sim_sdk" -target "$(uname -m)-apple-ios18.0-simulator" \
    "$repo_root/ios_app/iPhUMI/USIStream/USIPreviewMailbox.swift" \
    "$repo_root/ios_app/iPhUMI/USIStream/USIInterface.swift" \
    "$repo_root/tests/ios-layout/ProbeApp.swift" -o "$probe_app/USILayoutProbe"
cat > "$probe_app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.emiliano867.usi-layout-probe</string>
<key>CFBundleExecutable</key><string>USILayoutProbe</string>
<key>CFBundleName</key><string>USILayoutProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>18.0</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>UIStatusBarHidden</key><true/>
<key>UIRequiresFullScreen</key><true/>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationLandscapeRight</string></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$probe_app"
for device_type in iPhone-15-Pro iPhone-SE-3rd-generation; do
    probe_device=$(xcrun simctl create "USI-layout-$device_type" "com.apple.CoreSimulator.SimDeviceType.$device_type" "$runtime")
    xcrun simctl boot "$probe_device"
    xcrun simctl bootstatus "$probe_device" -b
    xcrun simctl install "$probe_device" "$probe_app"
    xcrun simctl launch "$probe_device" com.emiliano867.usi-layout-probe
    app_data=$(xcrun simctl get_app_container "$probe_device" com.emiliano867.usi-layout-probe data)
    for attempt in {1..60}; do
        [[ ! -f "$app_data/Documents/layout-result.json" ]] || break
        sleep 1
    done
    mkdir -p "$output_dir/$device_type"
    cp "$app_data/Documents/"* "$output_dir/$device_type/"
    python3 - "$output_dir/$device_type/layout-result.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
print(json.dumps(result, indent=2))
assert result["passed"], "Native layout check failed; inspect report/screenshots"
PY
    xcrun simctl shutdown "$probe_device"
    xcrun simctl delete "$probe_device"
    probe_device=
done

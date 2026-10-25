#!/bin/sh
# Prints an xcodebuild -destination for the first available iPhone simulator,
# so local runs and CI don't depend on a specific device name or iOS version.
set -eu

xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    if "iOS" not in runtime:
        continue
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print("platform=iOS Simulator,id=" + device["udid"])
            sys.exit(0)
sys.exit("No available iPhone simulator found")
'

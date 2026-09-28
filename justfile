set shell := ["bash", "-euo", "pipefail", "-c"]

bundle_id := "me.4vr.alai"

# List the recipes
default:
    @just --list

# Regenerate Alai.xcodeproj from project.yml
generate:
    mise exec -- xcodegen generate

# Build, install and launch on a connected iPhone (the first paired one unless a UDID is given)
device udid="": generate
    #!/usr/bin/env bash
    set -euo pipefail
    udid="{{ udid }}"
    if [ -z "$udid" ]; then
        json=$(mktemp)
        xcrun devicectl list devices --json-output "$json" >/dev/null
        udid=$(python3 -c 'import json,sys
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
    phones = [d for d in devices if d["hardwareProperties"].get("reality") == "physical"
              and d["hardwareProperties"].get("platform") == "iOS"
              and d["connectionProperties"].get("pairingState") == "paired"]
    print(phones[0]["hardwareProperties"]["udid"] if phones else "")' "$json")
        rm -f "$json"
    fi
    if [ -z "$udid" ]; then
        echo "No paired iPhone found. Connect one, or pass a UDID: just device <udid>" >&2
        exit 1
    fi
    echo "Building for $udid"
    xcodebuild -project Alai.xcodeproj -scheme Alai -configuration Debug \
        -destination "id=$udid" -derivedDataPath build/device \
        -allowProvisioningUpdates -quiet build
    xcrun devicectl device install app --device "$udid" build/device/Build/Products/Debug-iphoneos/Alai.app
    xcrun devicectl device process launch --device "$udid" --terminate-existing {{ bundle_id }}

# Archive a Release build and upload it to App Store Connect for TestFlight
testflight: generate
    #!/usr/bin/env bash
    set -euo pipefail
    # Every upload needs a new build number; a UTC timestamp always increases
    build=$(date -u +%Y%m%d%H%M)
    /bin/rm -rf build/Alai.xcarchive build/export
    echo "Archiving build $build"
    xcodebuild archive -project Alai.xcodeproj -scheme Alai -configuration Release \
        -destination 'generic/platform=iOS' -archivePath build/Alai.xcarchive \
        -allowProvisioningUpdates -quiet CURRENT_PROJECT_VERSION="$build"
    echo "Uploading build $build"
    xcodebuild -exportArchive -archivePath build/Alai.xcarchive -exportOptionsPlist ExportOptions.plist \
        -exportPath build/export -allowProvisioningUpdates
    echo "Uploaded build $build. It shows in TestFlight once App Store Connect finishes processing."

# Build for the iOS simulator
build: generate
    xcodebuild -project Alai.xcodeproj -scheme Alai -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath build/sim -quiet build

# Run the NtfyKit package tests
test:
    cd Packages/NtfyKit && swift test

# Connected devices and simulators
devices:
    xcrun devicectl list devices

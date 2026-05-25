#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODE="${DEVELOPER_DIR:-/Volumes/Forrest/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"

echo "== AirDesk shared protocol =="
swift build --package-path Shared/AirDeskProtocol

echo "== Regenerate Xcode projects =="
(cd AirDesk-Mac && xcodegen generate)
(cd AirDesk-iOS && xcodegen generate)

echo "== Mac SwiftPM release build =="
swift build -c release --package-path AirDesk-Mac

echo "== Mac Xcode release build =="
DEVELOPER_DIR="$XCODE" xcodebuild \
  -project AirDesk-Mac/AirDesk-Mac.xcodeproj \
  -scheme AirDesk \
  -configuration Release \
  -derivedDataPath build/AirDesk-Mac \
  build

echo "== iOS generic Debug build =="
DEVELOPER_DIR="$XCODE" xcodebuild \
  -project AirDesk-iOS/AirDesk.xcodeproj \
  -scheme AirDesk \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ -n "${IOS_DEVICE_ID:-}" ]]; then
  echo "== iOS physical device install =="
  DEVELOPER_DIR="$XCODE" xcodebuild \
    -project AirDesk-iOS/AirDesk.xcodeproj \
    -scheme AirDesk \
    -configuration Debug \
    -destination "id=$IOS_DEVICE_ID" \
    -derivedDataPath build/AirDesk-iOS-device \
    -allowProvisioningUpdates \
    build

  DEVELOPER_DIR="$XCODE" xcrun devicectl device install app \
    --device "$IOS_DEVICE_ID" \
    "$ROOT/build/AirDesk-iOS-device/Build/Products/Debug-iphoneos/AirDesk.app"
else
  echo "== iOS physical device install skipped: set IOS_DEVICE_ID to enable =="
fi

echo "== Done =="

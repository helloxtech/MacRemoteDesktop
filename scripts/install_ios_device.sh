#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODE="${DEVELOPER_DIR:-$(xcode-select -p)}"
DEVICE_ID="${IOS_DEVICE_ID:-${1:-}}"

if [[ -z "$DEVICE_ID" ]]; then
  echo "Usage: IOS_DEVICE_ID=<device-udid> scripts/install_ios_device.sh"
  echo "   or: scripts/install_ios_device.sh <device-udid>"
  exit 2
fi

cd "$ROOT"

if [[ ! -d "$XCODE" ]]; then
  echo "Xcode developer directory not found: $XCODE" >&2
  exit 3
fi

if command -v xcodegen >/dev/null 2>&1; then
  echo "== Regenerate iOS project =="
  (cd AirDesk-iOS && xcodegen generate)
else
  echo "== xcodegen not found; using existing AirDesk-iOS/AirDesk.xcodeproj =="
fi

echo "== Build signed iOS app for $DEVICE_ID =="
DEVELOPER_DIR="$XCODE" xcodebuild \
  -project AirDesk-iOS/AirDesk.xcodeproj \
  -scheme AirDesk \
  -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath build/AirDesk-iOS-device \
  -allowProvisioningUpdates \
  build

APP_PATH="$ROOT/build/AirDesk-iOS-device/Build/Products/Debug-iphoneos/AirDesk.app"

echo "== Install iOS app =="
DEVELOPER_DIR="$XCODE" xcrun devicectl device install app \
  --device "$DEVICE_ID" \
  "$APP_PATH"

echo "Installed $APP_PATH"

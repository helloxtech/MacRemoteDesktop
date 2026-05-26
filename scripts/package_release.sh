#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODE="${DEVELOPER_DIR:-$(xcode-select -p)}"
APP_NAME="AirDesk"
APP_PATH="$ROOT/dist/$APP_NAME.app"
DMG_PATH="$ROOT/dist/$APP_NAME.dmg"
ZIP_PATH="$ROOT/dist/$APP_NAME.zip"
NOTARY_ZIP_PATH="$ROOT/dist/$APP_NAME-notary.zip"
STAGING="$ROOT/dist/dmg-staging"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_ARGS=()

if [[ -n "${APPLE_ID:-}" && -n "${APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
elif [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  NOTARY_ARGS=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
fi

cd "$ROOT"
mkdir -p dist build

echo "== Regenerate Mac project =="
if command -v xcodegen >/dev/null 2>&1; then
  (cd AirDesk-Mac && xcodegen generate)
else
  echo "== xcodegen not found; using existing AirDesk-Mac/AirDesk-Mac.xcodeproj =="
fi

echo "== Build Mac Release =="
DEVELOPER_DIR="$XCODE" xcodebuild \
  -project AirDesk-Mac/AirDesk-Mac.xcodeproj \
  -scheme AirDesk \
  -configuration Release \
  -derivedDataPath build/AirDesk-Mac \
  build

rm -rf "$APP_PATH" "$STAGING" "$ZIP_PATH" "$DMG_PATH" "$NOTARY_ZIP_PATH"
ditto "$ROOT/build/AirDesk-Mac/Build/Products/Release/$APP_NAME.app" "$APP_PATH"

if [[ -n "$IDENTITY" ]]; then
  echo "== Sign with Developer ID =="
  codesign --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" \
    --entitlements "$ROOT/AirDesk-Mac/AirDesk.entitlements" \
    "$APP_PATH"
else
  echo "== Developer ID not configured; signing locally =="
  codesign --force --deep --sign - \
    --entitlements "$ROOT/AirDesk-Mac/AirDesk.entitlements" \
    "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ ${#NOTARY_ARGS[@]} -gt 0 && -n "$IDENTITY" ]]; then
  echo "== Notarize app before packaging =="
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP_PATH"
  xcrun notarytool submit "$NOTARY_ZIP_PATH" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$APP_PATH"
  rm -f "$NOTARY_ZIP_PATH"
else
  echo "== Notarization skipped: set DEVELOPER_ID_APPLICATION and either Apple ID or App Store Connect API key notarization variables =="
fi

echo "== Create ZIP and DMG =="
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
mkdir -p "$STAGING"
ditto "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"

if [[ -n "$IDENTITY" ]]; then
  echo "== Sign DMG with Developer ID =="
  codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
fi

if [[ ${#NOTARY_ARGS[@]} -gt 0 && -n "$IDENTITY" ]]; then
  echo "== Notarize DMG =="
  xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$DMG_PATH"
fi

ls -lh "$APP_PATH" "$ZIP_PATH" "$DMG_PATH"

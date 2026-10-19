#!/usr/bin/env bash
# Optional distribution helper. Uses only signing assets already configured by you.
# This script never imports certificates, creates keys, or changes keychains.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEAM_ID:?Set TEAM_ID to your own Apple developer team}"
: "${BUNDLE_ID:?Set BUNDLE_ID to your own registered application identifier}"
: "${EXPORT_OPTIONS_PLIST:?Set EXPORT_OPTIONS_PLIST to your private Xcode export options file}"
[[ -f "$EXPORT_OPTIONS_PLIST" ]] || { echo 'Export options file does not exist.' >&2; exit 1; }
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
BUILD_NUMBER=${BUILD_NUMBER:-$(date +%s)}
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo 'BUILD_NUMBER must be numeric.' >&2; exit 1; }
command -v xcodegen >/dev/null || { echo 'Install XcodeGen before running this script.' >&2; exit 1; }
xcodegen generate
mkdir -p build
archive="build/Velvet-${BUILD_NUMBER}.xcarchive"
[[ ! -e "$archive" ]] || { echo 'Archive already exists; choose a new BUILD_NUMBER.' >&2; exit 1; }
xcodebuild archive -project Velvet.xcodeproj -scheme Velvet -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY='Apple Development' CODE_SIGN_STYLE=Automatic
args=()
if [[ -n "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]]; then
  : "${ASC_KEY_PATH:?Set all three ASC authentication variables or none}"
  : "${ASC_KEY_ID:?Set all three ASC authentication variables or none}"
  : "${ASC_ISSUER_ID:?Set all three ASC authentication variables or none}"
  args=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
# Export versus upload is explicitly chosen by destination in your private plist.
xcodebuild -exportArchive -archivePath "$archive" -exportPath "build/export-${BUILD_NUMBER}" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" "${args[@]}"
echo 'Export completed using your signing configuration.'

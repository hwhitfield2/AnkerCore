#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
team_id="${ANKERCORE_TEAM_ID:-}"
bundle_id="${ANKERCORE_BUNDLE_ID:-com.ankercore.app}"
version="${ANKERCORE_VERSION:-1.0}"

if [[ -z "$team_id" ]]; then
  echo "Set ANKERCORE_TEAM_ID to the Apple Developer team that owns $bundle_id." >&2
  exit 64
fi

if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ANKERCORE_TEAM_ID must be a 10-character Apple Developer Team ID." >&2
  exit 64
fi

if [[ ! "$bundle_id" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "ANKERCORE_BUNDLE_ID contains unsupported characters." >&2
  exit 64
fi

if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "ANKERCORE_VERSION must contain one to three period-separated integers." >&2
  exit 64
fi

if [[ -n "${ANKERCORE_BUILD_NUMBER:-}" ]]; then
  build_number="$ANKERCORE_BUILD_NUMBER"
else
  year="$(date -u +%Y)"
  month_day="$(date -u +%m%d)"
  hour_minute_second="$(date -u +%H%M%S)"
  build_number="${year}.$((10#$month_day)).$((10#$hour_minute_second))"
fi

if [[ ! "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "ANKERCORE_BUILD_NUMBER must contain one to three period-separated integers." >&2
  exit 64
fi

output_root="${ANKERCORE_OUTPUT_DIR:-$repo_root/build/TestFlight}"
archive_path="$output_root/AnkerCore-${version}-${build_number}.xcarchive"
export_path="$output_root/export-${version}-${build_number}"

mkdir -p "$output_root" "$export_path"

echo "Archiving AnkerCore $version ($build_number) for $bundle_id..."
xcodebuild \
  -project "$repo_root/AnkerCore.xcodeproj" \
  -scheme AnkerCore \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$team_id" \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  clean archive

echo "Uploading AnkerCore $version ($build_number) to App Store Connect..."
xcodebuild \
  -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$repo_root/Config/TestFlightExportOptions.plist" \
  -allowProvisioningUpdates

echo "Upload accepted. App Store Connect will process AnkerCore $version ($build_number) before it appears in TestFlight."

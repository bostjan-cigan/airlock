#!/bin/zsh
# Builds a shareable copy of AIrlock: a release build for Apple silicon, signed ad hoc (no Apple
# account needed), as dist/AIrlock-<version>.zip and dist/AIrlock-<version>.dmg (drag to
# Applications; LICENSE and NOTICE sit beside it), with SHA256SUMS.txt.
#   Tools/package.sh                          # version from AIRLOCK_VERSION, else the project's
#   AIRLOCK_VERSION=1.2.0 AIRLOCK_BUILD=42 Tools/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ADHOC=1 Tools/build.sh release
app=build/AIrlock.app
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")

rm -rf dist
mkdir -p dist
ditto -c -k --keepParent "$app" "dist/AIrlock-$version.zip"

stage=build/dmg
rm -rf "$stage"
mkdir -p "$stage"
ditto "$app" "$stage/AIrlock.app"
ln -s /Applications "$stage/Applications"
cp LICENSE NOTICE "$stage/"
hdiutil create -volname AIrlock -srcfolder "$stage" -fs HFS+ -format UDZO -ov "dist/AIrlock-$version.dmg" >/dev/null
rm -rf "$stage"

(cd dist && shasum -a 256 AIrlock-* > SHA256SUMS.txt)
echo "Built dist/AIrlock-$version.dmg and .zip"

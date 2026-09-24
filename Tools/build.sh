#!/bin/zsh
# Builds AIrlock.app into build/.
#   Tools/build.sh [debug|release]
# Set ADHOC=1 to sign ad hoc (no Apple developer account needed). AIRLOCK_VERSION and
# AIRLOCK_BUILD set the version the app reports (e.g. 1.2.0 and the CI run number).
set -euo pipefail
cd "$(dirname "$0")/.."

config=${1:-debug}
case $config in
    debug) configuration=Debug ;;
    release) configuration=Release ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

mkdir -p build
signing=()
version=()
[[ -n "${AIRLOCK_VERSION:-}" ]] && version+=(MARKETING_VERSION="$AIRLOCK_VERSION")
[[ -n "${AIRLOCK_BUILD:-}" ]] && version+=(CURRENT_PROJECT_VERSION="$AIRLOCK_BUILD")
if [[ "${ADHOC:-0}" == 1 ]]; then
    signing=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
fi

xcodebuild \
    -project AIrlock.xcodeproj \
    -scheme AIrlock \
    -configuration "$configuration" \
    -derivedDataPath build/DerivedData \
    -destination 'platform=macOS,arch=arm64' \
    -skipPackagePluginValidation -skipMacroValidation \
    "${signing[@]}" \
    "${version[@]}" \
    build > build/xcodebuild.log 2>&1 || {
        grep -E "error:|BUILD FAILED" build/xcodebuild.log | sort -u >&2
        echo "Full log: build/xcodebuild.log" >&2
        exit 1
    }

app="build/DerivedData/Build/Products/$configuration/AIrlock.app"
[[ -d "$app" ]] || { echo "build failed" >&2; exit 1; }
rm -rf build/AIrlock.app
ditto "$app" build/AIrlock.app
# ditto keeps the bundle folder's original date; Finder should show when it was built.
touch build/AIrlock.app
echo "Built build/AIrlock.app"

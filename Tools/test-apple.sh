#!/bin/zsh
# Runs the end-to-end check on the Apple VM runtime. The CLI must be signed with
# the virtualization entitlement, which `swift run` binaries aren't.
#   Tools/test-apple.sh [worktree|volumeClone] [restricted|open]
set -euo pipefail
cd "$(dirname "$0")/../Packages/AirlockKit"
swift build --product airlock-cli
codesign --force --sign - --entitlements ../../Config/AIrlock.entitlements .build/debug/airlock-cli
scratch=$(mktemp -d)
.build/debug/airlock-cli e2e "$scratch" "${1:-worktree}" "${2:-restricted}" apple

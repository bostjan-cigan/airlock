#!/bin/sh
# AIrlock tasks need a git repository with compose.yaml at its root. This copies
# the sample into a fresh standalone repo (outside the AIrlock checkout) and
# makes an initial commit on main.
#
#   scripts/make-repo.sh [destination]
#   default destination: ~/AIrlockSamples/sample-app-multiple-containers
set -eu

src=$(cd "$(dirname "$0")/.." && pwd)
dest=${1:-"$HOME/AIrlockSamples/sample-app-multiple-containers"}

if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
  echo "error: $dest already exists and isn't empty; pass another path or remove it" >&2
  exit 1
fi

mkdir -p "$dest"
(cd "$src" && tar --exclude node_modules --exclude .DS_Store -cf - .) | (cd "$dest" && tar -xf -)

cd "$dest"
git init -q -b main
git add .
git -c user.name="AIrlock Sample" -c user.email="sample@example.invalid" commit -qm "Notes API with Postgres and Redis"

echo "Repository ready: $dest"

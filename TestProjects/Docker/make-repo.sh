#!/bin/sh
# Copies a sample into a fresh standalone git repository (outside the AIrlock
# checkout, where AIrlock can't see it as part of this repo) and commits it on main.
#
#   TestProjects/Docker/make-repo.sh <sample> [destination]
#   default destination: ~/AIrlockSamples/<sample>
#   make-repo.sh all      every sample, side by side in ~/AIrlockSamples
set -eu

here=$(cd "$(dirname "$0")" && pwd)
if [ "${1:-}" = "" ]; then
  echo "usage: $0 <sample>|all [destination]" >&2
  ls -d "$here"/*/ | xargs -n1 basename >&2
  exit 2
fi
if [ "$1" = "all" ]; then
  for dir in "$here"/*/; do "$0" "$(basename "$dir")"; done
  exit 0
fi

src="$here/$1"
[ -d "$src" ] || { echo "error: no sample named $1" >&2; exit 1; }
dest=${2:-"$HOME/AIrlockSamples/$1"}
if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
  echo "error: $dest already exists and isn't empty; pass another path or remove it" >&2
  exit 1
fi

mkdir -p "$dest"
(cd "$src" && tar --exclude node_modules --exclude .venv --exclude target --exclude vendor --exclude .DS_Store -cf - .) | (cd "$dest" && tar -xf -)
cd "$dest"
git init -q -b main
git add .
git -c user.name="AIrlock Sample" -c user.email="sample@example.invalid" commit -qm "$1"
echo "Repository ready: $dest"

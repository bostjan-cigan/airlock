#!/bin/zsh
# Turns the frames a screenshot tour saved into GIFs, with ffmpeg.
#   Tools/make-gifs.sh <folder>     # <folder>/frames/<name>/NNNN.png → <folder>/<name>.gif
# Take the screenshots first:
#   build/AIrlock.app/Contents/MacOS/AIrlock --demo --screenshots <folder>
set -euo pipefail

folder=${1:?usage: $0 <folder>}
command -v ffmpeg >/dev/null || { echo "ffmpeg is needed: brew install ffmpeg" >&2; exit 1; }

for dir in "$folder"/frames/*(/); do
    name=${dir:t}
    size=$(sips -g pixelWidth -g pixelHeight "$dir/0000.png" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}')
    # The window's rounded corners are transparent. Flattened onto the tour's backdrop colour,
    # frames only store what changed (the spinners), so the GIF stays small.
    ffmpeg -v error -y -framerate 8 -i "$dir/%04d.png" -filter_complex \
        "color=c=0xEDF0F5:s=${size}[bg];[bg][0]overlay=shortest=1,format=rgb24,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
        "$folder/$name.gif"
    echo "$folder/$name.gif ($(du -h "$folder/$name.gif" | cut -f1))"
done

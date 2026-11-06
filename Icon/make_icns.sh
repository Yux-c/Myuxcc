#!/bin/zsh
# Renders the chosen icon design and packs it into Icon/AppIcon.icns, which build.sh copies into the app.
set -euo pipefail
cd "$(dirname "$0")"

VARIANT=ivory-layers
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swiftc -O make_icon.swift -o "$WORK/make_icon"
"$WORK/make_icon" "$VARIANT" "$WORK/icon_1024.png"

SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for pt in 16 32 128 256 512; do
    sips -z $pt $pt "$WORK/icon_1024.png" --out "$SET/icon_${pt}x${pt}.png" >/dev/null
    px=$((pt * 2))
    sips -z $px $px "$WORK/icon_1024.png" --out "$SET/icon_${pt}x${pt}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
cp "$WORK/icon_1024.png" AppIcon-1024.png
echo "Wrote Icon/AppIcon.icns"

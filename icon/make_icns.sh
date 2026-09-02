#!/bin/bash
# Build AppIcon.icns from a 1024x1024 master PNG.
#   usage: bash make_icns.sh [master.png]
set -e
cd "$(dirname "$0")"
SRC="${1:-AppIcon-1024.png}"
[ -f "$SRC" ] || { echo "no such file: $SRC"; exit 1; }

DIM=$(sips -g pixelWidth -g pixelHeight "$SRC" | awk '/pixel/{print $2}' | paste -sd x -)
[ "$DIM" = "1024x1024" ] || { echo "master must be 1024x1024, got $DIM"; exit 1; }

SET="AppIcon.iconset"
rm -rf "$SET"; mkdir -p "$SET"
for S in 16 32 128 256 512; do
  sips -z $S      $S      "$SRC" --out "$SET/icon_${S}x${S}.png"    > /dev/null
  sips -z $((S*2)) $((S*2)) "$SRC" --out "$SET/icon_${S}x${S}@2x.png" > /dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$SET"
echo "built $(pwd)/AppIcon.icns ($(stat -f%z AppIcon.icns) bytes)"

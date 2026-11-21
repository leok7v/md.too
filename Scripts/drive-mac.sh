#!/bin/sh
# usage: Scripts/drive-mac.sh <file.md> <step>...
# MDTOO_APP overrides the app; the default is the Debug build product.
set -eu
cd "$(dirname "$0")/.."
app=${MDTOO_APP:-Build/Products/Debug/md.too.app}
app=$(cd "$(dirname "$app")" && pwd)/$(basename "$app")
exe=$app/Contents/MacOS/md.too
bundle=com.leok7v.md.too
drive=$HOME/Library/Containers/$bundle/Data/Library/Caches/$bundle/drive
file=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
shift
count=$#
for step; do set -- "$@" --step "$step"; done
shift "$count"
pkill -f "$exe" || true
until ! pgrep -f "$exe" > /dev/null; do sleep 0.2; done
rm -rf "$drive"
open -n -a "$app" "$file" --args "$@"
tries=0
until grep -q '^\[drive\] done' "$drive/log.txt" 2> /dev/null ||
      [ "$tries" -ge 120 ]; do
    sleep 1
    tries=$((tries + 1))
done
out=tmp/drive/$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"
cp "$drive"/* "$out"/
cat "$out/log.txt"
echo "$out"
grep -q '^\[drive\] done' "$out/log.txt"

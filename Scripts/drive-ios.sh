#!/bin/sh
# usage: Scripts/drive-ios.sh <udid> <file.md> <step>...
# MDTOO_INSTALL=1 installs the Debug iOS build first.
# MDTOO_IOS_APP overrides the app to install.
set -eu
cd "$(dirname "$0")/.."
bundle=com.leok7v.md.too
app=${MDTOO_IOS_APP:-Build/Products/Debug-iphoneos/md.too.app}
udid=$1
file=$2
name=$(basename "$file")
shift 2
count=$#
for step; do set -- "$@" --step "$step"; done
shift "$count"
out=tmp/drive/$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"
copy_to() {
    xcrun devicectl device copy to --device "$udid" \
        --domain-type appDataContainer --domain-identifier "$bundle" \
        --source "$1" --destination "$2" > /dev/null
}
copy_from() {
    xcrun devicectl device copy from --device "$udid" \
        --domain-type appDataContainer --domain-identifier "$bundle" \
        --source "Library/Caches/$bundle/drive/$1" \
        --destination "$out/$1" > /dev/null
}
if [ "${MDTOO_INSTALL:-0}" = 1 ]; then
    xcrun devicectl device install app --device "$udid" "$app"
fi
copy_to "$file" "Documents/$name"
printf '[drive] stale\n' > "$out/stale.txt"
copy_to "$out/stale.txt" "Library/Caches/$bundle/drive/log.txt"
xcrun devicectl device process launch --device "$udid" \
    --terminate-existing "$bundle" -- --open "Documents/$name" "$@"
tries=0
until copy_from log.txt 2> /dev/null &&
      grep -q '^\[drive\] done' "$out/log.txt" ||
      [ "$tries" -ge 90 ]; do
    sleep 2
    tries=$((tries + 1))
done
sed -n 's/^\[drive\] [0-9]* shot .* ok file=\(.*\.png\) bytes=[0-9]*$/\1/p' \
    "$out/log.txt" | while read -r shot; do
    copy_from "$shot"
done
cat "$out/log.txt"
echo "$out"
grep -q '^\[drive\] done' "$out/log.txt"

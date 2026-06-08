#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

app_name="MeetingTruth"
bundle="dist/${app_name}.app"
stamp="$(date +%Y%m%d)"
zip_name="${app_name}-macOS-${stamp}.zip"
zip_path="dist/${zip_name}"
manifest_path="dist/${app_name}-package-info.txt"

./script/build_and_run.sh --verify >/dev/null

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")"
if [[ "$bundle_id" != "local.meetingtruth.clean" ]]; then
  printf 'Refusing to package %s: expected bundle id local.meetingtruth.clean, got %s\n' "$bundle" "$bundle_id" >&2
  exit 1
fi

rm -f "$zip_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$bundle" "$zip_path"

bundle_size="$(du -sh "$bundle" | awk '{print $1}')"
zip_size="$(du -sh "$zip_path" | awk '{print $1}')"
sha256="$(shasum -a 256 "$zip_path" | awk '{print $1}')"

cat > "$manifest_path" <<EOF
Package: ${zip_name}
Created: $(date '+%Y-%m-%d %H:%M:%S %z')
Bundle: ${bundle}
Bundle Size: ${bundle_size}
Zip: ${zip_path}
Zip Size: ${zip_size}
SHA256: ${sha256}

Runtime Notes:
- First launch copies Scripts/ and script/ into ~/Library/Application Support/MeetingTruthClean/RuntimeWorkspace
- External model download/setup requires network access
- Some external runtimes require Python 3.11; if missing, set LOCAL_ASR_PYTHON311 to a valid python3.11 path
- Downloaded models and runtime envs are stored under ~/Library/Application Support/MeetingTruthClean
EOF

printf '%s\n' "$zip_path"

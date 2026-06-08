#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage:
  ./script/build_and_run.sh
  ./script/build_and_run.sh --cli --audio /path/to/audio.wav [--model MODEL]
  ./script/build_and_run.sh --verify

This builds and launches the MeetingTruth macOS app.
EOF
  exit 0
fi

product_name="MeetingTruth"
app_name="MeetingTruth"
bundle="dist/${app_name}.app"
binary=".build/release/${product_name}"
icon_name="MeetingTruthIcon.icns"

/usr/bin/pkill -x "$product_name" 2>/dev/null || true
/usr/bin/pkill -f "/dist/${app_name}.app/Contents/MacOS/${product_name}" 2>/dev/null || true
for _ in {1..20}; do
  if ! /usr/bin/pgrep -x "$product_name" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

swift build -c release --product "$product_name"

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
mkdir -p "$bundle/Contents/Resources/RuntimePayload"
cp "$binary" "$bundle/Contents/MacOS/$product_name"
cp "Resources/AppIcon/$icon_name" "$bundle/Contents/Resources/$icon_name"
rsync -a --delete --exclude '__pycache__' --exclude '.DS_Store' Scripts "$bundle/Contents/Resources/RuntimePayload/"
rsync -a --delete --exclude '.DS_Store' script "$bundle/Contents/Resources/RuntimePayload/"
if [[ -d TestRuns ]]; then
  rsync -a --delete --exclude '.DS_Store' TestRuns "$bundle/Contents/Resources/RuntimePayload/"
fi

cat > "$bundle/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>MeetingTruth</string>
  <key>CFBundleIdentifier</key>
  <string>local.meetingtruth.clean</string>
  <key>CFBundleName</key>
  <string>MeetingTruth</string>
  <key>CFBundleIconFile</key>
  <string>MeetingTruthIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>用于导入用户选择的会议音频、资料和候选转写，并复制到应用缓存目录进行本地处理。</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>用于导入用户选择的会议音频、资料和候选转写，并复制到应用缓存目录进行本地处理。</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>用于导入用户选择的会议音频、资料和候选转写，并复制到应用缓存目录进行本地处理。</string>
</dict>
</plist>
EOF

/usr/bin/codesign --force --deep --sign - --identifier local.meetingtruth.clean "$bundle" >/dev/null 2>&1 || true
/usr/bin/open -n "$bundle"

if [[ "${1:-}" == "--verify" ]]; then
  sleep 2
  /usr/bin/pgrep -x "$product_name" >/dev/null
fi

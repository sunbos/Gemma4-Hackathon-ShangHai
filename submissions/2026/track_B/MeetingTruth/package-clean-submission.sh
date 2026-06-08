#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$ROOT/source/MeetingTruthMacApp"
PACKAGE_NAME="MeetingTruth-Clean-Submission"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_ROOT="$(cd "$ROOT/.." && pwd)/release-output"
STAGING_PARENT="$OUT_ROOT/staging-$STAMP"
STAGING="$STAGING_PARENT/$PACKAGE_NAME"
ZIP_PATH="$OUT_ROOT/${PACKAGE_NAME}-${STAMP}.zip"

required_dirs=("source" "sample-data")
optional_dirs=("assets")
required_files=("README.md" "TECHNICAL_REPORT.md" "BUILD_AND_TEST.md" "package-clean-submission.sh")

exclude_args=(
  "--exclude=.git"
  "--exclude=.DS_Store"
  "--exclude=.build"
  "--exclude=DerivedData"
  "--exclude=dist"
  "--exclude=staging"
  "--exclude=dist-clean-submission"
  "--exclude=release-output"
  "--exclude=*.zip"
  "--exclude=venv"
  "--exclude=.venv"
  "--exclude=__pycache__"
  "--exclude=*.pyc"
  "--exclude=*.pyo"
  "--exclude=.pytest_cache"
  "--exclude=.mypy_cache"
  "--exclude=.ruff_cache"
  "--exclude=.cache"
  "--exclude=RuntimeWorkspace"
  "--exclude=MeetingTruthClean"
  "--exclude=UserData"
  "--exclude=Recordings"
  "--exclude=PrivateData"
  "--exclude=*.safetensors"
  "--exclude=*.gguf"
  "--exclude=*.bin"
  "--exclude=*.pt"
  "--exclude=*.pth"
  "--exclude=*.onnx"
  "--exclude=*.mlmodelc"
  "--exclude=*.part"
)

say() {
  printf '[package-clean-submission] %s\n' "$*"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

say "Checking required files"
for dir in "${required_dirs[@]}"; do
  [[ -d "$ROOT/$dir" ]] || { printf 'Missing required directory: %s\n' "$ROOT/$dir" >&2; exit 1; }
done
for file in "${required_files[@]}"; do
  [[ -f "$ROOT/$file" ]] || { printf 'Missing required file: %s\n' "$ROOT/$file" >&2; exit 1; }
done

require_command swift
require_command python3
require_command rsync
require_command shasum
require_command zip

say "Cleaning local build/cache artifacts"
rm -rf "$APP_ROOT/.build" "$APP_ROOT/dist"
find "$ROOT" -type d \( -name "__pycache__" -o -name ".pytest_cache" -o -name ".mypy_cache" -o -name ".ruff_cache" \) -prune -exec rm -rf {} +
find "$ROOT" -type f \( -name "*.pyc" -o -name "*.pyo" -o -name ".DS_Store" \) -delete

say "Running Swift release build"
(cd "$APP_ROOT" && swift build -c release --product MeetingTruth)

say "Compiling ASR Python scripts"
python3 -m py_compile "$APP_ROOT"/Scripts/asr/*.py
find "$ROOT" -type d -name "__pycache__" -prune -exec rm -rf {} +
find "$ROOT" -type f \( -name "*.pyc" -o -name "*.pyo" \) -delete
rm -rf "$APP_ROOT/.build" "$APP_ROOT/dist"

say "Preparing clean staging directory"
rm -rf "$STAGING_PARENT"
mkdir -p "$STAGING"

for file in "${required_files[@]}"; do
  cp "$ROOT/$file" "$STAGING/$file"
done

for dir in "${required_dirs[@]}"; do
  rsync -a "${exclude_args[@]}" "$ROOT/$dir/" "$STAGING/$dir/"
done

for dir in "${optional_dirs[@]}"; do
  if [[ -d "$ROOT/$dir" ]] && find "$ROOT/$dir" -type f | grep -q .; then
    rsync -a "${exclude_args[@]}" "$ROOT/$dir/" "$STAGING/$dir/"
  fi
done

say "Generating CHECKSUMS.sha256"
(
  cd "$STAGING"
  find . -type f ! -name "CHECKSUMS.sha256" -print0 \
    | sort -z \
    | xargs -0 shasum -a 256 > CHECKSUMS.sha256
)
cp "$STAGING/CHECKSUMS.sha256" "$ROOT/CHECKSUMS.sha256"

say "Creating zip outside source tree"
mkdir -p "$OUT_ROOT"
rm -f "$ZIP_PATH"
(cd "$STAGING_PARENT" && zip -qry -X "$ZIP_PATH" "$PACKAGE_NAME")
rm -rf "$STAGING_PARENT"

say "Done"
printf 'Final package: %s\n' "$ZIP_PATH"

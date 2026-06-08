#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

runtime_dir=".runtime/qwen-asr"
source "$(dirname "$0")/runtime_common.sh"
python_bin="$(local_asr_python)"
local_asr_validate_python "$python_bin"

local_asr_emit_download_progress "检查 Qwen3-ASR 推理依赖"

if [[ -x "$runtime_dir/bin/python" ]]; then
  if "$runtime_dir/bin/python" - <<'PY' >/dev/null 2>&1
import qwen_asr, torch, soundfile
PY
  then
    printf 'ready\n' > "$runtime_dir/.local-asr-runtime-ready"
    local_asr_emit_download_progress "Qwen3-ASR 推理依赖已就绪"
    echo "Qwen3-ASR runtime ready"
    exit 0
  fi
fi

local_asr_emit_download_progress "创建 Qwen3-ASR Python 环境"
"$python_bin" -m venv "$runtime_dir"

local_asr_pip_install_with_fallback "$runtime_dir/bin/python" "安装 Qwen3-ASR 推理依赖" --upgrade qwen-asr torch soundfile

local_asr_emit_download_progress "校验 Qwen3-ASR 推理依赖"
"$runtime_dir/bin/python" - <<'PY'
import qwen_asr, torch, soundfile
print("Qwen3-ASR runtime ready")
PY
printf 'ready\n' > "$runtime_dir/.local-asr-runtime-ready"

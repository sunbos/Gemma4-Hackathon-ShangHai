#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

runtime_dir=".runtime/hf-asr"
source "$(dirname "$0")/runtime_common.sh"
python_bin="$(local_asr_python)"
local_asr_validate_python "$python_bin"

local_asr_emit_download_progress "检查 HuggingFace ASR 推理依赖"
if [[ -x "$runtime_dir/bin/python" ]]; then
  if "$runtime_dir/bin/python" - <<'PY' >/dev/null 2>&1
import transformers, torch, soundfile
from transformers import GlmAsrForConditionalGeneration
PY
  then
    printf 'ready\n' > "$runtime_dir/.local-asr-runtime-ready"
    local_asr_emit_download_progress "HuggingFace ASR 推理依赖已就绪"
    echo "HuggingFace ASR runtime ready"
    exit 0
  fi
fi

local_asr_emit_download_progress "创建 HuggingFace ASR Python 环境"
"$python_bin" -m venv "$runtime_dir"
local_asr_pip_install_with_fallback "$runtime_dir/bin/python" "安装 HuggingFace ASR 推理依赖" --upgrade transformers accelerate torch soundfile

"$runtime_dir/bin/python" - <<'PY'
import transformers, torch, soundfile
from transformers import GlmAsrForConditionalGeneration
print("HuggingFace ASR runtime ready")
PY
printf 'ready\n' > "$runtime_dir/.local-asr-runtime-ready"

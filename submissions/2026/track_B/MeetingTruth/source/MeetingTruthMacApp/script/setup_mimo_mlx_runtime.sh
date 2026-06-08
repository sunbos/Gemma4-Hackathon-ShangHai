#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

runtime_dir=".runtime/mimo-mlx"
mlx_audio_commit="6241c57d61663725bb8a0ca1e1695c89ab6c09c0"
mlx_audio_package="git+https://github.com/ailuntx/mlx-audio@${mlx_audio_commit}"
source "$(dirname "$0")/runtime_common.sh"
python_bin="$(local_asr_python)"
local_asr_validate_python "$python_bin"

local_asr_patch_mimo_mlx_runtime() {
  "$runtime_dir/bin/python" - <<'PY'
from pathlib import Path
import mlx_audio.stt.models.qwen2_audio as qwen2_audio
import shutil

alias_dir = Path(qwen2_audio.__file__).resolve().parents[1] / "qwen2"
if alias_dir.exists():
    shutil.rmtree(alias_dir)
PY
  printf 'ready\n' > "$runtime_dir/.local-asr-runtime-ready"
  printf 'ready\n' > "$runtime_dir/.local-asr-generation-ready"
}

local_asr_verify_mimo_mlx_runtime() {
  "$runtime_dir/bin/python" - "$mlx_audio_commit" <<'PY'
from importlib.metadata import distribution, version
import json
import mlx.core
import mlx_audio
from mlx_audio.stt import load
import mlx_audio.stt.models.qwen2_audio
import soundfile
import sys

expected_commit = sys.argv[1]
assert version("mlx-audio") == "0.4.3"
assert version("transformers") == "5.8.1"

dist = distribution("mlx-audio")
direct_url = None
for file in dist.files or []:
    if str(file).endswith("direct_url.json"):
        direct_url = dist.locate_file(file)
        break
assert direct_url is not None and direct_url.exists(), "mlx-audio must be installed from the pinned MiMo GitHub revision"
payload = json.loads(direct_url.read_text(encoding="utf-8"))
commit = payload.get("vcs_info", {}).get("commit_id", "")
assert commit == expected_commit, f"wrong mlx-audio commit: {commit or 'unknown'}"
PY
}

local_asr_emit_download_progress "检查 MiMo MLX 推理依赖"
if [[ -x "$runtime_dir/bin/python" ]]; then
  if local_asr_verify_mimo_mlx_runtime >/dev/null 2>&1
  then
    local_asr_patch_mimo_mlx_runtime
    local_asr_emit_download_progress "MiMo MLX 推理依赖已就绪"
    echo "MiMo MLX runtime ready"
    exit 0
  fi
fi

local_asr_emit_download_progress "创建 MiMo MLX Python 环境"
"$python_bin" -m venv "$runtime_dir"
local_asr_pip_install_with_fallback "$runtime_dir/bin/python" "安装 MiMo MLX 基础依赖" --upgrade \
  "numpy==2.4.5" \
  "soundfile==0.13.1" \
  "huggingface_hub" \
  "transformers==5.8.1"

if [[ -n "${LOCAL_ASR_MLX_AUDIO_PACKAGE:-}" ]]; then
  local_asr_pip_install_with_fallback "$runtime_dir/bin/python" "安装 MiMo MLX 音频依赖" --upgrade "$LOCAL_ASR_MLX_AUDIO_PACKAGE"
else
  local_asr_emit_download_progress "安装 MiMo MLX 官方固定修订依赖"
  local_asr_pip_install_with_fallback "$runtime_dir/bin/python" "安装 MiMo MLX 音频依赖" --upgrade --force-reinstall --no-deps "$mlx_audio_package"
fi

local_asr_patch_mimo_mlx_runtime
local_asr_verify_mimo_mlx_runtime

"$runtime_dir/bin/python" - <<'PY'
import platform
from importlib.metadata import version
import mlx.core as mx
import mlx_audio
from mlx_audio.stt import load
import mlx_audio.stt.models.qwen2_audio
import soundfile

print("MiMo MLX runtime ready")
print(f"Python: {platform.python_version()}")
print(f"MLX default device: {mx.default_device()}")
print(f"mlx-audio: {version('mlx-audio')}")
print(f"transformers: {version('transformers')}")
PY
printf 'ready\n' > "$runtime_dir/.local-asr-runtime-ready"
printf 'ready\n' > "$runtime_dir/.local-asr-generation-ready"

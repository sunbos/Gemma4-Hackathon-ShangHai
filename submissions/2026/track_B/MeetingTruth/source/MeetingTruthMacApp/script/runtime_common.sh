#!/usr/bin/env bash

local_asr_python() {
  if [[ -n "${LOCAL_ASR_PYTHON311:-}" && -x "${LOCAL_ASR_PYTHON311:-}" ]]; then
    printf '%s\n' "$LOCAL_ASR_PYTHON311"
    return 0
  fi

  for candidate in \
    /opt/homebrew/bin/python3.11 \
    /usr/local/bin/python3.11 \
    /opt/homebrew/bin/python3.12 \
    /usr/local/bin/python3.12 \
    /opt/homebrew/bin/python3.10 \
    /usr/local/bin/python3.10 \
    "$(command -v python3.11 2>/dev/null || true)" \
    "$(command -v python3.12 2>/dev/null || true)" \
    "$(command -v python3.10 2>/dev/null || true)" \
    "$(command -v python3 2>/dev/null || true)"
  do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "找不到可用 Python。请安装 Python 3.11，或设置 LOCAL_ASR_PYTHON311=/path/to/python3.11。" >&2
  return 1
}

local_asr_emit_download_progress() {
  local stage="$1"
  printf 'LOCAL_ASR_DOWNLOAD_PROGRESS {"stage":"%s","downloadedBytes":0,"totalBytes":0,"speedBytesPerSecond":0,"estimatedRemainingSeconds":null}\n' "$stage" >&2
}

local_asr_validate_python() {
  local python_executable="$1"
  "$python_executable" - <<'PY'
import platform
import sys

major, minor = sys.version_info[:2]
machine = platform.machine()
if major != 3 or minor < 10 or minor > 12:
    raise SystemExit(f"当前 Python {major}.{minor} 不适合自动安装本地 ASR 依赖；请安装 Python 3.11。")
if machine not in {"arm64", "x86_64"}:
    raise SystemExit(f"当前架构 {machine} 未确认支持本地 ASR runtime。")
print(f"Python runtime: {major}.{minor} / {machine}", file=sys.stderr)
PY
}

local_asr_pip_indexes() {
  if [[ -n "${LOCAL_ASR_PIP_INDEX_URLS:-}" ]]; then
    local old_ifs="$IFS"
    IFS=','
    read -r -a configured_indexes <<< "${LOCAL_ASR_PIP_INDEX_URLS:-}"
    IFS="$old_ifs"
    printf '%s\n' "${configured_indexes[@]}"
    return 0
  fi

  printf '%s\n' \
    "https://pypi.tuna.tsinghua.edu.cn/simple" \
    "https://mirrors.aliyun.com/pypi/simple" \
    "https://pypi.mirrors.ustc.edu.cn/simple" \
    "https://pypi.org/simple"
}

local_asr_pip_install_with_fallback() {
  local python_executable="$1"
  local stage="$2"
  shift 2

  local last_status=1
  "$python_executable" -m ensurepip --upgrade >/dev/null 2>&1 || true
  "$python_executable" -m pip install --disable-pip-version-check --upgrade pip setuptools wheel || true
  while IFS= read -r index_url; do
    index_url="${index_url#"${index_url%%[![:space:]]*}"}"
    index_url="${index_url%"${index_url##*[![:space:]]}"}"
    [[ -z "$index_url" ]] && continue
    local_asr_emit_download_progress "${stage}：$(printf '%s' "$index_url" | sed -E 's#^https?://##; s#/simple/?$##')"
    if "$python_executable" -m pip install \
      --disable-pip-version-check \
      --prefer-binary \
      --timeout 30 \
      --retries 3 \
      -i "$index_url" \
      "$@"; then
      return 0
    fi
    last_status=$?
  done < <(local_asr_pip_indexes)
  echo "依赖安装失败：$stage。失败包/参数：$*" >&2
  echo "请检查网络和 pip 镜像；可设置 LOCAL_ASR_PIP_INDEX_URLS=https://pypi.org/simple,https://pypi.tuna.tsinghua.edu.cn/simple 后重试。" >&2
  echo "如果当前 Python 版本不是 3.10-3.12，推荐安装 Python 3.11 并设置 LOCAL_ASR_PYTHON311=/path/to/python3.11。" >&2
  return "$last_status"
}

#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from pathlib import Path

DOWNLOAD_RETRIES = 3
CONNECT_TIMEOUT_SECONDS = 45
READ_TIMEOUT_SECONDS = 90


def fail(message: str, code: int = 2):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def download_endpoints() -> list[str | None]:
    configured = os.environ.get("LOCAL_ASR_HF_ENDPOINTS", "")
    endpoints = [value.strip() for value in configured.split(",") if value.strip()]
    endpoints.extend([
        os.environ.get("HF_ENDPOINT", "").strip(),
        "https://hf-mirror.com",
        "https://huggingface.co",
    ])

    result: list[str | None] = []
    seen = set()
    for endpoint in endpoints:
        key = endpoint or "default"
        if key in seen:
            continue
        seen.add(key)
        result.append(endpoint or None)
    return result


def emit_download_progress(stage: str, downloaded: int, total: int, speed: float, eta: float | None, extra: dict | None = None):
    payload = {
        "stage": stage,
        "downloadedBytes": downloaded,
        "totalBytes": total,
        "speedBytesPerSecond": speed,
        "estimatedRemainingSeconds": eta,
    }
    if extra:
        payload.update(extra)
    print("LOCAL_ASR_DOWNLOAD_PROGRESS " + json.dumps(payload, ensure_ascii=False), file=sys.stderr, flush=True)


def resolve_repo_files(model_id: str, endpoint: str | None, allow_patterns: list[str] | None) -> list[str]:
    try:
        from huggingface_hub import HfApi
        api = HfApi(endpoint=endpoint) if endpoint else HfApi()
        files = api.list_repo_files(repo_id=model_id)
    except Exception:
        files = resolve_repo_files_via_http(model_id, endpoint)
    if allow_patterns:
        files = [
            file
            for file in files
            if any(fnmatch.fnmatch(Path(file).name, pattern) or fnmatch.fnmatch(file, pattern) for pattern in allow_patterns)
        ]
    return sorted(files)


def resolve_repo_files_via_http(model_id: str, endpoint: str | None) -> list[str]:
    base = (endpoint or "https://huggingface.co").rstrip("/")
    quoted_model = urllib.parse.quote(model_id, safe="")
    urls = [
        f"{base}/api/models/{quoted_model}/tree/main?recursive=1",
        f"{base}/api/models/{model_id}/tree/main?recursive=1",
    ]
    last_error = None
    for url in urls:
        try:
            request = urllib.request.Request(url, headers={"Accept": "application/json"})
            with urllib.request.urlopen(request, timeout=45, context=ssl_context()) as response:
                payload = json.loads(response.read().decode("utf-8"))
            files = []
            for item in payload:
                if isinstance(item, dict) and item.get("type") == "file" and item.get("path"):
                    files.append(item["path"])
            if files:
                return sorted(files)
        except Exception as exc:
            last_error = exc
    raise RuntimeError(f"读取 Hugging Face 文件列表失败：{last_error}")


def resolve_url(endpoint: str | None, model_id: str, filename: str) -> str:
    base = (endpoint or "https://huggingface.co").rstrip("/")
    quoted = urllib.parse.quote(filename, safe="/")
    return f"{base}/{model_id}/resolve/main/{quoted}"


def ssl_context():
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def remote_size(url: str) -> int:
    request = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(request, timeout=CONNECT_TIMEOUT_SECONDS, context=ssl_context()) as response:
        value = response.headers.get("Content-Length")
        return int(value) if value and value.isdigit() else 0


def retry_delay(attempt: int) -> float:
    return min(2.0 * attempt, 6.0)


def open_with_retries(request: urllib.request.Request, timeout: int):
    last_error: Exception | None = None
    for attempt in range(1, DOWNLOAD_RETRIES + 1):
        try:
            return urllib.request.urlopen(request, timeout=timeout, context=ssl_context())
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as exc:
            last_error = exc
            if attempt >= DOWNLOAD_RETRIES:
                break
            emit_download_progress(
                f"网络波动，重试 {attempt}/{DOWNLOAD_RETRIES - 1}",
                0,
                0,
                0,
                None,
                {
                    "url": getattr(request, "full_url", ""),
                    "error": str(exc),
                },
            )
            time.sleep(retry_delay(attempt))
    raise RuntimeError(f"下载请求失败：{getattr(request, 'full_url', '')}\n{last_error}")


def download_file(url: str, destination: Path, expected_size: int, aggregate_start: int, aggregate_total: int, meta: dict) -> int:
    destination.parent.mkdir(parents=True, exist_ok=True)
    part = destination.with_suffix(destination.suffix + ".part")

    if destination.exists() and expected_size > 0 and destination.stat().st_size == expected_size:
        emit_download_progress(
            f"已缓存 {destination.name}",
            aggregate_start + expected_size,
            aggregate_total,
            0,
            0 if aggregate_total > 0 else None,
            meta,
        )
        return expected_size

    resume_from = part.stat().st_size if part.exists() else 0
    if expected_size > 0 and resume_from >= expected_size:
        part.unlink(missing_ok=True)
        resume_from = 0
    headers = {}
    if resume_from > 0:
        headers["Range"] = f"bytes={resume_from}-"

    request = urllib.request.Request(url, headers=headers)
    with open_with_retries(request, timeout=READ_TIMEOUT_SECONDS) as response:
        if resume_from > 0 and response.status == 200:
            resume_from = 0
            part.unlink(missing_ok=True)

        mode = "ab" if resume_from > 0 else "wb"
        downloaded = resume_from
        speed_samples = deque(maxlen=12)
        last_emit_time = 0.0
        with part.open(mode + "") as handle:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
                downloaded += len(chunk)
                now = time.monotonic()
                speed_samples.append((now, aggregate_start + downloaded))
                while len(speed_samples) > 1 and now - speed_samples[0][0] > 5:
                    speed_samples.popleft()
                if len(speed_samples) >= 2:
                    elapsed = max(speed_samples[-1][0] - speed_samples[0][0], 1e-6)
                    speed = (speed_samples[-1][1] - speed_samples[0][1]) / elapsed
                else:
                    speed = 0
                total_downloaded = aggregate_start + downloaded
                remaining = (aggregate_total - total_downloaded) / speed if speed > 0 and aggregate_total > 0 else None
                if now - last_emit_time >= 0.5 or total_downloaded >= aggregate_total:
                    emit_download_progress(
                        f"下载 {destination.name}",
                        total_downloaded,
                        aggregate_total,
                        speed,
                        remaining,
                        meta,
                    )
                    last_emit_time = now

    final_size = part.stat().st_size
    if expected_size > 0 and final_size != expected_size:
        fail(f"下载大小不匹配：{destination.name}，期望 {expected_size}，实际 {final_size}")
    os.replace(part, destination)
    return final_size


def read_json(path: Path, label: str) -> dict:
    if not path.exists():
        fail(f"{label} 下载不完整：缺少 {path.relative_to(path.parent) if path.parent.exists() else path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"{label} 下载不完整：{path} 不是有效 JSON：{exc}")
    if not isinstance(payload, dict):
        fail(f"{label} 下载不完整：{path} JSON 顶层不是对象。")
    return payload


def sum_file_bytes(paths: list[Path]) -> int:
    total = 0
    for path in paths:
        try:
            total += path.stat().st_size
        except OSError:
            pass
    return total


def verify_downloaded_files(target: Path, files: list[str], sizes: dict[str, int]) -> None:
    missing = []
    mismatched = []
    for filename in files:
        path = target / filename
        expected = sizes.get(filename, 0)
        if not path.exists():
            missing.append(filename)
            continue
        actual = path.stat().st_size
        if expected > 0 and actual != expected:
            mismatched.append(f"{filename} 期望 {expected} 实际 {actual}")
    partials = partial_download_files(target)
    if missing or mismatched or partials:
        fail(
            "下载校验失败：\n"
            + ("\n缺失文件：\n" + "\n".join(missing) if missing else "")
            + ("\n大小不匹配：\n" + "\n".join(mismatched) if mismatched else "")
            + ("\n未完成断点文件：\n" + "\n".join(partials) if partials else "")
        )


def estimate_hf_snapshot_size(model_id: str, allow_patterns: list[str] | None = None) -> int:
    for endpoint in download_endpoints():
        try:
            files = resolve_repo_files(model_id, endpoint, allow_patterns)
            return sum(remote_size(resolve_url(endpoint, model_id, filename)) for filename in files)
        except Exception:
            continue
    return 0


def hf_snapshot(
    model_id: str,
    target: Path,
    allow_patterns: list[str] | None = None,
    progress_offset: int = 0,
    progress_total: int | None = None,
) -> tuple[Path, int]:
    target.mkdir(parents=True, exist_ok=True)

    errors = []
    for endpoint in download_endpoints():
        try:
            display_total = progress_total if progress_total is not None else 0
            emit_download_progress(
                f"连接下载源 {model_id}",
                progress_offset,
                display_total,
                0,
                None,
                {
                    "repo": model_id,
                    "endpoint": endpoint or "default",
                },
            )
            print(
                f"LOCAL_ASR_DOWNLOAD_SOURCE {json.dumps({'repo': model_id, 'endpoint': endpoint or 'default'}, ensure_ascii=False)}",
                file=sys.stderr,
                flush=True,
            )
            emit_download_progress(
                f"读取文件列表 {model_id}",
                progress_offset,
                display_total,
                0,
                None,
                {
                    "repo": model_id,
                    "endpoint": endpoint or "default",
                },
            )
            files = resolve_repo_files(model_id, endpoint, allow_patterns)
            if not files:
                raise RuntimeError(f"{model_id} 没有匹配文件：{allow_patterns or '*'}")

            emit_download_progress(
                f"计算下载大小 {model_id}",
                progress_offset,
                display_total,
                0,
                None,
                {
                    "repo": model_id,
                    "endpoint": endpoint or "default",
                },
            )
            sizes: dict[str, int] = {}
            for filename in files:
                sizes[filename] = remote_size(resolve_url(endpoint, model_id, filename))
            aggregate_total = sum(size if size > 0 else 0 for size in sizes.values())
            display_total = progress_total if progress_total is not None else progress_offset + aggregate_total
            aggregate_done = 0

            for filename in files:
                destination = target / filename
                size = sizes[filename]
                aggregate_done += download_file(
                    resolve_url(endpoint, model_id, filename),
                    destination,
                    size,
                    progress_offset + aggregate_done,
                    display_total,
                    {
                        "repo": model_id,
                        "file": filename,
                        "endpoint": endpoint or "default",
                    },
                )
            verify_downloaded_files(target, files, sizes)
            return target, aggregate_total
        except Exception as exc:
            errors.append(f"{endpoint or 'default'}: {exc}")
            time.sleep(1)

    fail("所有 Hugging Face 下载源都失败：\n" + "\n".join(errors))


def write_manifest(target: Path, payload: dict):
    target.mkdir(parents=True, exist_ok=True)
    payload.setdefault("prepared_at", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    payload.setdefault("preparedAt", payload["prepared_at"])
    payload.setdefault("download_source", payload.get("source", "huggingface"))
    payload.setdefault("downloadSource", payload["download_source"])
    payload.setdefault("expected_size", directory_size(target))
    payload.setdefault("expectedSize", payload["expected_size"])
    payload.setdefault("validation_status", "模型目录已写入，App 将继续做关键文件和体积校验。")
    payload.setdefault("validationStatus", payload["validation_status"])
    payload.setdefault("error_message", None)
    payload.setdefault("errorMessage", None)
    (target / "LOCAL_ASR_MODEL_MANIFEST.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def rewrite_json_file(path: Path, updates: dict):
    if not path.exists():
        return
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return
    payload.update(updates)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def directory_size(path: Path) -> int:
    if not path.exists():
        return 0
    total = 0
    for item in path.rglob("*"):
        if item.is_file():
            try:
                total += item.stat().st_size
            except OSError:
                pass
    return total


def has_basic_hf_model_files(path: Path) -> bool:
    if not path.exists():
        return False
    has_config = (path / "config.json").exists()
    has_weights = any(path.glob("*.safetensors")) or any(path.glob("*.bin"))
    has_tokenizer = any(
        (path / name).exists()
        for name in [
            "tokenizer_config.json",
            "tokenizer.json",
            "vocab.json",
            "merges.txt",
            "preprocessor_config.json",
        ]
    )
    return has_config and has_weights and has_tokenizer


def partial_download_files(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [str(item.relative_to(path)) for item in path.rglob("*.part") if item.is_file()]


def validate_hf_snapshot_common(target: Path, label: str, minimum_weight_bytes: int, required_tokenizer: bool = True):
    partials = partial_download_files(target)
    if partials:
        fail(f"{label} 下载不完整：仍存在断点文件：\n" + "\n".join(partials[:20]))
    config = read_json(target / "config.json", label)
    weights = sorted(target.glob("*.safetensors")) + sorted(target.glob("*.bin"))
    weight_bytes = sum_file_bytes(weights)
    if weight_bytes < minimum_weight_bytes:
        fail(
            f"{label} 下载不完整：权重体积异常，"
            f"体积 {weight_bytes}/{minimum_weight_bytes}，目录 {target}"
        )
    if required_tokenizer:
        tokenizer_files = [
            target / "tokenizer_config.json",
            target / "tokenizer.json",
            target / "vocab.json",
            target / "merges.txt",
            target / "preprocessor_config.json",
            target / "processor_config.json",
        ]
        if not any(path.exists() and path.stat().st_size > 0 for path in tokenizer_files):
            fail(f"{label} 下载不完整：缺少 tokenizer / processor 配置文件：{target}")
    return config, weights, weight_bytes


def validate_glm_snapshot(target: Path):
    config, _weights, _weight_bytes = validate_hf_snapshot_common(
        target,
        "GLM-ASR",
        minimum_weight_bytes=int(3.5 * 1_000_000_000),
    )
    if config.get("model_type") != "glmasr":
        fail(f"GLM-ASR 下载不完整：config.model_type 异常：{config.get('model_type')!r}")
    architectures = config.get("architectures") or []
    if "GlmAsrForConditionalGeneration" not in architectures:
        fail(f"GLM-ASR 下载不完整：config.architectures 异常：{architectures!r}")
    if not (target / "processor_config.json").exists():
        fail(f"GLM-ASR 下载不完整：缺少 processor_config.json：{target}")


def validate_qwen_snapshot(target: Path, include_forced_aligner: bool):
    config, weights, weight_bytes = validate_hf_snapshot_common(
        target,
        "Qwen3-ASR",
        minimum_weight_bytes=int(700 * 1_000_000),
    )
    if config.get("model_type") != "qwen3_asr":
        fail(f"Qwen3-ASR 下载不完整：config.model_type 异常：{config.get('model_type')!r}")
    if include_forced_aligner and weight_bytes < int(3.8 * 1_000_000_000):
        fail(f"Qwen3-ASR 1.7B 下载不完整：主模型权重体积异常：{weight_bytes}")
    if include_forced_aligner:
        aligner = target / "Qwen3-ForcedAligner-0.6B"
        aligner_config, _aligner_weights, aligner_bytes = validate_hf_snapshot_common(
            aligner,
            "Qwen3 ForcedAligner",
            minimum_weight_bytes=int(1.0 * 1_000_000_000),
        )
        if aligner_config.get("model_type") != "qwen3_asr":
            fail(f"Qwen3 ForcedAligner 下载不完整：config.model_type 异常：{aligner_config.get('model_type')!r}")
        rewrite_json_file(
            target / "LOCAL_ASR_MODEL_MANIFEST.json",
            {
                "forcedAligner": str(aligner),
                "forcedAlignerSource": "Qwen/Qwen3-ForcedAligner-0.6B",
                "forcedAlignerBytes": aligner_bytes,
            },
        )
    if not weights:
        fail(f"Qwen3-ASR 下载不完整：缺少主模型权重：{target}")


def validate_mimo_mlx_snapshot(target: Path, app_model_id: str | None):
    partials = partial_download_files(target)
    if partials:
        fail("MiMo MLX 下载不完整：仍存在断点文件：\n" + "\n".join(partials[:20]))

    manifest = target / "mlx_manifest.json"
    config = target / "config.json"
    if not manifest.exists() and not config.exists():
        fail(f"MiMo MLX 下载不完整：缺少 mlx_manifest.json 或 config.json：{target}")

    weights = sorted(target.glob("*.safetensors"))
    if not weights:
        fail(f"MiMo MLX 下载不完整：缺少 safetensors 权重：{target}")

    total_weight_bytes = sum(path.stat().st_size for path in weights)
    is_bf16 = "bf16" in (app_model_id or target.name).lower()
    minimum_weight_count = 6 if is_bf16 else 1
    minimum_weight_bytes = int(12.0 * 1_000_000_000) if is_bf16 else int(3.5 * 1_000_000_000)
    if len(weights) < minimum_weight_count or total_weight_bytes < minimum_weight_bytes:
        fail(
            "MiMo MLX 下载不完整：权重体积异常，"
            f"文件数 {len(weights)}/{minimum_weight_count}，"
            f"体积 {total_weight_bytes}/{minimum_weight_bytes}。"
        )

    tokenizer_dir = target / "MiMo-Audio-Tokenizer"
    if not (tokenizer_dir / "config.json").exists():
        fail(f"MiMo MLX 下载不完整：缺少音频 tokenizer config.json：{tokenizer_dir}")
    tokenizer_weights = sorted(tokenizer_dir.glob("*.safetensors"))
    tokenizer_bytes = sum(path.stat().st_size for path in tokenizer_weights)
    if tokenizer_bytes < int(500 * 1_000_000):
        fail(f"MiMo MLX 下载不完整：音频 tokenizer 权重体积异常：{tokenizer_dir}")

    try:
        if manifest.exists():
            payload = json.loads(manifest.read_text(encoding="utf-8"))
            audio_tokenizer_dir = payload.get("audio_tokenizer_dir") or payload.get("audioTokenizerDir")
            if audio_tokenizer_dir and not (target / str(audio_tokenizer_dir) / "config.json").exists():
                fail(f"MiMo MLX manifest 指向的 audio_tokenizer_dir 不可用：{audio_tokenizer_dir}")
    except json.JSONDecodeError as exc:
        fail(f"MiMo MLX manifest 不是有效 JSON：{manifest}: {exc}")


def prefetch_qwen(model_id: str, target: Path, include_forced_aligner: bool) -> Path:
    aligner_id = "Qwen/Qwen3-ForcedAligner-0.6B"
    aligner_target = target / "Qwen3-ForcedAligner-0.6B"
    model_estimated = estimate_hf_snapshot_size(model_id)
    aligner_estimated = estimate_hf_snapshot_size(aligner_id) if include_forced_aligner else 0
    combined_total = model_estimated + aligner_estimated

    if has_basic_hf_model_files(target):
        model_total = max(directory_size(target) - directory_size(aligner_target), 0)
        local_path = target
        emit_download_progress(
            "已识别本地 Qwen3 主模型",
            model_total,
            combined_total if combined_total > 0 else model_total,
            0,
            0 if not include_forced_aligner else None,
            {
                "repo": model_id,
            },
        )
    else:
        emit_download_progress(
            "读取 Qwen3 模型清单",
            0,
            0,
            0,
            None,
            {
                "repo": model_id,
            },
        )
        local_path, model_total = hf_snapshot(
            model_id,
            target,
            progress_offset=0,
            progress_total=combined_total if combined_total > 0 else None,
        )
    if include_forced_aligner:
        if has_basic_hf_model_files(aligner_target):
            aligner_total = directory_size(aligner_target)
            emit_download_progress(
                "Qwen 时间戳对齐器已缓存",
                model_total + aligner_total,
                model_total + aligner_total,
                0,
                0,
                {
                    "repo": aligner_id,
                },
            )
        else:
            emit_download_progress(
                "准备下载 Qwen 时间戳对齐器",
                model_total,
                0,
                0,
                None,
                {
                    "repo": aligner_id,
                },
            )
            hf_snapshot(
                aligner_id,
                aligner_target,
                progress_offset=model_total,
                progress_total=combined_total if combined_total > 0 else None,
            )
            rewrite_json_file(
                target / "LOCAL_ASR_MODEL_MANIFEST.json",
                {
                    "forcedAligner": str(aligner_target),
                    "forcedAlignerSource": aligner_id,
                },
            )
    validate_qwen_snapshot(target, include_forced_aligner)
    return local_path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-kind", required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--shared-target")
    parser.add_argument("--app-model-id")
    parser.add_argument("--app-model-name")
    parser.add_argument("--runtime")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    target = Path(args.target).expanduser().resolve()
    shared_target = Path(args.shared_target).expanduser().resolve() if args.shared_target else target.parent / "_shared"
    if args.dry_run:
        target.mkdir(parents=True, exist_ok=True)
        print(json.dumps({
            "ok": True,
            "dryRun": True,
            "modelKind": args.model_kind,
            "modelID": args.model_id,
            "target": str(target),
            "sharedTarget": str(shared_target),
            "endpoints": [endpoint or "default" for endpoint in download_endpoints()],
            "existingBytes": directory_size(target),
            "partialFiles": partial_download_files(target),
            "message": "dry-run 只检查本地目标和下载源配置，不下载模型文件。",
        }, ensure_ascii=False))
        return

    if args.model_kind == "mimo-mlx":
        model_patterns = ["*.json", "*.safetensors", "*.txt", "*.model", "*.md"]
        tokenizer_patterns = ["*.json", "*.safetensors", "*.txt", "*.model", "*.md"]
        model_estimated = estimate_hf_snapshot_size(args.model_id, model_patterns)
        tokenizer_estimated = estimate_hf_snapshot_size("mlx-community/MiMo-Audio-Tokenizer", tokenizer_patterns)
        combined_total = model_estimated + tokenizer_estimated

        local_path, model_total = hf_snapshot(
            args.model_id,
            target,
            allow_patterns=model_patterns,
            progress_offset=0,
            progress_total=combined_total if combined_total > 0 else None,
        )
        hf_snapshot(
            "mlx-community/MiMo-Audio-Tokenizer",
            target / "MiMo-Audio-Tokenizer",
            allow_patterns=tokenizer_patterns,
            progress_offset=model_total,
            progress_total=combined_total if combined_total > 0 else None,
        )
        rewrite_json_file(
            target / "mlx_manifest.json",
            {
                "audio_tokenizer_dir": "MiMo-Audio-Tokenizer",
                "audio_tokenizer_repo": "mlx-community/MiMo-Audio-Tokenizer",
            },
        )
        validate_mimo_mlx_snapshot(target, args.app_model_id)
        write_manifest(
            target,
            {
                "schemaVersion": 1,
                "modelID": args.app_model_id or target.name,
                "modelName": args.app_model_name or args.model_id,
                "runtime": args.runtime or "external",
                "sourceType": "huggingface",
                "source": args.model_id,
                "downloadedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "localPath": str(local_path),
                "requiredFiles": ["mlx_manifest.json/config.json", "*.safetensors", "MiMo-Audio-Tokenizer/config.json"],
                "notes": "Apple Silicon MLX route. Tokenizer source: mlx-community/MiMo-Audio-Tokenizer.",
            },
        )
    elif args.model_kind == "qwen":
        include_forced_aligner = "timestamps" in (args.app_model_id or "").lower()
        local_path = prefetch_qwen(
            args.model_id,
            target,
            include_forced_aligner=include_forced_aligner,
        )
        write_manifest(
            target,
            {
                "schemaVersion": 1,
                "modelID": args.app_model_id or target.name,
                "modelName": args.app_model_name or args.model_id,
                "runtime": args.runtime or "external",
                "sourceType": "huggingface",
                "source": args.model_id,
                "downloadedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "localPath": str(local_path),
                "requiredFiles": [
                    item for item in [
                    "config.json",
                    "*.safetensors",
                    "tokenizer/preprocessor config",
                    "Qwen3-ForcedAligner-0.6B/config.json" if include_forced_aligner else "",
                    "Qwen3-ForcedAligner-0.6B/*.safetensors" if include_forced_aligner else "",
                    ] if item
                ],
                "notes": "Official Qwen3-ASR Hugging Face snapshot with forced aligner when timestamps are enabled.",
            },
        )
    elif args.model_kind == "glm":
        local_path, _ = hf_snapshot(args.model_id, target)
        validate_glm_snapshot(target)
        write_manifest(
            target,
            {
                "schemaVersion": 1,
                "modelID": args.app_model_id or target.name,
                "modelName": args.app_model_name or args.model_id,
                "runtime": args.runtime or "external",
                "sourceType": "huggingface",
                "source": args.model_id,
                "downloadedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "localPath": str(local_path),
                "requiredFiles": ["config.json", "model.safetensors", "tokenizer_config.json", "processor_config.json"],
                "notes": "Official GLM-ASR Hugging Face snapshot.",
            },
        )
    else:
        local_path, _ = hf_snapshot(args.model_id, target)

    print(json.dumps({"localPath": str(local_path)}, ensure_ascii=False))


if __name__ == "__main__":
    main()

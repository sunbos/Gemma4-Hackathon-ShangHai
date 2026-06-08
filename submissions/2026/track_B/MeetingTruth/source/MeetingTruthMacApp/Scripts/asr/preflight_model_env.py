#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import ssl
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


MIN_MACOS = (14, 0)


def emit(payload):
    print("LOCAL_ASR_PREFLIGHT " + json.dumps(payload, ensure_ascii=False), file=sys.stderr, flush=True)


def endpoint_candidates():
    values = []
    configured = os.environ.get("LOCAL_ASR_HF_ENDPOINTS", "")
    values.extend([item.strip() for item in configured.split(",") if item.strip()])
    values.append(os.environ.get("HF_ENDPOINT", "").strip())
    values.extend(["https://huggingface.co", "https://hf-mirror.com"])
    result = []
    seen = set()
    for value in values:
        endpoint = value.rstrip("/") if value else "https://huggingface.co"
        if endpoint in seen:
            continue
        seen.add(endpoint)
        result.append(endpoint)
    return result


def ssl_context():
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def parse_macos_version():
    version = platform.mac_ver()[0]
    parts = []
    for value in version.split(".")[:2]:
        try:
            parts.append(int(value))
        except ValueError:
            parts.append(0)
    while len(parts) < 2:
        parts.append(0)
    return tuple(parts), version


def check_network(model_id, timeout):
    quoted_model = urllib.parse.quote(model_id, safe="/")
    errors = []
    for endpoint in endpoint_candidates():
        url = "%s/api/models/%s" % (endpoint, quoted_model)
        started = time.monotonic()
        try:
            request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "MeetingTruth-ASR-Preflight/1.0"})
            with urllib.request.urlopen(request, timeout=timeout, context=ssl_context()) as response:
                if 200 <= response.status < 500:
                    return {
                        "ok": True,
                        "endpoint": endpoint,
                        "latencySeconds": round(time.monotonic() - started, 3),
                    }
                errors.append("%s: HTTP %s" % (endpoint, response.status))
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403, 404):
                return {
                    "ok": True,
                    "endpoint": endpoint,
                    "latencySeconds": round(time.monotonic() - started, 3),
                    "warning": "仓库返回 HTTP %s，网络本身可达，但模型权限或名称可能需要确认。" % exc.code,
                }
            errors.append("%s: HTTP %s" % (endpoint, exc.code))
        except Exception as exc:
            errors.append("%s: %s" % (endpoint, exc))
    return {"ok": False, "errors": errors}


def partial_files(target):
    if not target.exists():
        return []
    return [str(path.relative_to(target)) for path in target.rglob("*.part") if path.is_file()]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--runtime-dir", required=True)
    parser.add_argument("--expected-bytes", type=int, default=0)
    parser.add_argument("--min-python", default="3.10")
    parser.add_argument("--max-python", default="3.12")
    parser.add_argument("--network-timeout", type=float, default=12.0)
    parser.add_argument("--skip-network", action="store_true")
    args = parser.parse_args()

    target = Path(args.target).expanduser().resolve()
    runtime_dir = Path(args.runtime_dir).expanduser().resolve()
    target_parent = target.parent

    errors = []
    warnings = []
    checks = []

    try:
        target_parent.mkdir(parents=True, exist_ok=True)
        runtime_dir.parent.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        errors.append("无法创建模型缓存或 runtime 目录：%s。" % exc)

    min_major, min_minor = [int(part) for part in args.min_python.split(".", 1)]
    max_major, max_minor = [int(part) for part in args.max_python.split(".", 1)]
    current = sys.version_info[:3]
    if current < (min_major, min_minor, 0):
        errors.append("当前 Python %d.%d.%d 低于要求 %s。" % (current[0], current[1], current[2], args.min_python))
    elif current > (max_major, max_minor, 99):
        errors.append("当前 Python %d.%d.%d 高于已验证范围 %s；推荐 Python 3.11。" % (current[0], current[1], current[2], args.max_python))
    else:
        checks.append("Python %d.%d.%d 可用" % current)

    try:
        import venv  # noqa: F401

        checks.append("venv 模块可用")
    except Exception as exc:
        errors.append("Python venv 模块不可用：%s。" % exc)

    try:
        import ensurepip  # noqa: F401

        checks.append("pip/ensurepip 可用")
    except Exception as exc:
        errors.append("pip/ensurepip 不可用：%s。" % exc)

    machine = platform.machine()
    if machine != "arm64":
        warnings.append("当前架构是 %s；三路默认 ASR runtime 为 Apple Silicon 优先，Intel Mac 可能无法完成本地推理。" % (machine or "unknown"))
    else:
        checks.append("Apple Silicon 架构可用")

    macos_tuple, macos_text = parse_macos_version()
    if macos_tuple < MIN_MACOS:
        errors.append("当前 macOS %s 低于建议版本 %d.%d。" % (macos_text or "unknown", MIN_MACOS[0], MIN_MACOS[1]))
    else:
        checks.append("macOS %s 可用" % (macos_text or "unknown"))

    try:
        usage = shutil.disk_usage(str(target_parent))
        required = int(args.expected_bytes * 1.15) if args.expected_bytes > 0 else int(2.0 * 1000 * 1000 * 1000)
        if usage.free < required:
            errors.append("磁盘空间不足：可用 %.1f GB，至少需要 %.1f GB。" % (usage.free / 1e9, required / 1e9))
        else:
            checks.append("磁盘空间可用 %.1f GB" % (usage.free / 1e9))
    except Exception as exc:
        errors.append("无法检查磁盘空间：%s。" % exc)

    try:
        target.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(prefix=".meetingtruth-write-test-", dir=str(target), delete=True) as handle:
            handle.write(b"ok")
        checks.append("模型缓存目录可写")
    except Exception as exc:
        errors.append("无法写入模型缓存目录 %s：%s。" % (target, exc))

    partials = partial_files(target)
    if partials:
        warnings.append("发现 %d 个未完成下载文件；会尝试断点续传，若反复失败请清理损坏缓存后重试。" % len(partials))

    network = None
    if args.skip_network:
        warnings.append("已跳过网络预检。")
    else:
        network = check_network(args.model_id, args.network_timeout)
        if network.get("ok"):
            endpoint = network.get("endpoint", "")
            checks.append("下载源可访问：%s" % endpoint)
            if network.get("warning"):
                warnings.append(network["warning"])
        else:
            errors.append("网络不可达或下载源无响应。请检查网络，或配置 HF_ENDPOINT / LOCAL_ASR_HF_ENDPOINTS。")

    payload = {
        "ok": not errors,
        "checks": checks,
        "warnings": warnings,
        "errors": errors,
        "python": platform.python_version(),
        "machine": machine,
        "macOS": macos_text,
        "target": str(target),
        "runtimeDir": str(runtime_dir),
        "partialFiles": partials[:20],
        "network": network,
        "endpoints": endpoint_candidates(),
    }
    emit(payload)
    if errors:
        print("模型准备预检失败：" + errors[0], file=sys.stderr)
        for warning in warnings:
            print("提示：" + warning, file=sys.stderr)
        raise SystemExit(2)
    print(json.dumps(payload, ensure_ascii=False))


if __name__ == "__main__":
    main()

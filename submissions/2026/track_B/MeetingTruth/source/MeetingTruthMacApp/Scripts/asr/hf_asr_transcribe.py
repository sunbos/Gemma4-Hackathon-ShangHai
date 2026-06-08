#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def fail(message: str, code: int = 2):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def ensure_wav(audio_path: Path) -> Path:
    if audio_path.suffix.lower() == ".wav":
        return audio_path

    tmp = Path(tempfile.mkdtemp(prefix="local-asr-hf-audio-")) / "input.wav"
    ffmpeg = Path("/opt/homebrew/bin/ffmpeg")
    if ffmpeg.exists():
        cmd = [str(ffmpeg), "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(audio_path), "-ac", "1", "-ar", "16000", str(tmp)]
    else:
        cmd = ["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(audio_path), str(tmp)]

    completed = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if completed.returncode != 0:
        fail(completed.stderr or f"音频转换失败：{audio_path}")
    return tmp


def audio_duration(audio_path: Path) -> float:
    import soundfile as sf
    info = sf.info(str(audio_path))
    return float(info.frames / info.samplerate) if info.samplerate else 0.0


def run_glm_asr(
    model_id: str,
    audio_path: Path,
    source_audio_path: Path,
    hotwords: list[str],
    enable_corrections: bool,
    cache_dir: Path | None,
    chunk_seconds: float,
    overlap_seconds: float,
    max_new_tokens: int,
) -> str:
    import torch
    import soundfile as sf
    from transformers import AutoProcessor, GlmAsrForConditionalGeneration

    duration = audio_duration(audio_path)
    run_cache_dir = resolve_run_cache_dir(
        cache_dir=cache_dir,
        audio_path=source_audio_path,
        model_id=model_id,
        hotwords=hotwords,
        enable_corrections=enable_corrections,
        chunk_seconds=chunk_seconds,
        overlap_seconds=overlap_seconds,
    )

    processor = AutoProcessor.from_pretrained(model_id, trust_remote_code=True)
    model = GlmAsrForConditionalGeneration.from_pretrained(
        model_id,
        dtype=torch.float32,
        device_map="auto",
        trust_remote_code=True,
    )

    info = sf.info(str(audio_path))
    sample_rate = info.samplerate
    chunk_samples = max(int(sample_rate * chunk_seconds), sample_rate)
    overlap_samples = min(max(int(sample_rate * overlap_seconds), 0), chunk_samples // 2)
    total_chunks = max(math.ceil(max(info.frames - overlap_samples, 1) / max(chunk_samples - overlap_samples, 1)), 1)
    safe_max_new_tokens = max(128, min(max_new_tokens, 500))
    started = time.perf_counter()
    texts = []
    cached_count = 0
    completed_count = 0

    for index, start_seconds, end_seconds, chunk in iter_audio_chunks(audio_path, chunk_samples, overlap_samples):
        if len(chunk) < sample_rate * 0.2:
            continue

        cached = read_cached_segment(run_cache_dir, index)
        if cached is not None:
            text = cached.get("text", "")
            if is_glm_repetition_failure(text):
                cached = None
            else:
                cached_count += 1
        else:
            text = ""

        if cached is None:
            inputs = processor.apply_transcription_request(chunk, return_tensors="pt")
            inputs = inputs.to(model.device, dtype=model.dtype)

            text = generate_glm_chunk_text(
                model=model,
                processor=processor,
                inputs=inputs,
                hotwords=hotwords,
                enable_corrections=enable_corrections,
                max_new_tokens=safe_max_new_tokens,
                no_repeat_ngram_size=8,
            )
            if is_glm_repetition_failure(text):
                text = generate_glm_chunk_text(
                    model=model,
                    processor=processor,
                    inputs=inputs,
                    hotwords=hotwords,
                    enable_corrections=enable_corrections,
                    max_new_tokens=min(safe_max_new_tokens, 256),
                    no_repeat_ngram_size=4,
                )

            if is_glm_repetition_failure(text):
                text = ""
            else:
                write_cached_segment(
                    run_cache_dir,
                    index,
                    {
                        "index": index,
                        "start": start_seconds,
                        "end": end_seconds,
                        "text": text,
                    },
                )

        completed_count += 1
        elapsed = time.perf_counter() - started
        fraction = min(completed_count / total_chunks, 0.98)
        emit_progress(
            stage=f"片段 {completed_count}/{total_chunks}",
            fraction=fraction,
            elapsed=elapsed,
            estimated_remaining=(elapsed / fraction - elapsed) if fraction > 0 else None,
            partial_text=text,
            extra={
                "segmentIndex": index,
                "segmentStart": start_seconds,
                "segmentEnd": end_seconds,
                "cachedSegments": cached_count,
                "totalSegments": total_chunks,
            },
        )
        if text:
            texts.append(text)

    merged = merge_transcripts(texts, hotwords=hotwords, enable_corrections=enable_corrections)
    if run_cache_dir is not None:
        write_cached_segment(
            run_cache_dir,
            -1,
            {
                "text": merged,
                "duration": duration,
                "chunkSeconds": chunk_seconds,
                "overlapSeconds": overlap_seconds,
                "segments": completed_count,
                "cachedSegments": cached_count,
            },
            filename="merged.json",
        )
    return merged


def generate_glm_chunk_text(
    model,
    processor,
    inputs,
    hotwords: list[str],
    enable_corrections: bool,
    max_new_tokens: int,
    no_repeat_ngram_size: int,
) -> str:
    output_ids = model.generate(
        **inputs,
        do_sample=False,
        max_new_tokens=max_new_tokens,
        no_repeat_ngram_size=no_repeat_ngram_size,
    )
    generated_ids = output_ids[:, inputs.input_ids.shape[1]:]
    return clean_glm_text(
        processor.batch_decode(generated_ids, skip_special_tokens=True)[0],
        hotwords=hotwords,
        enable_corrections=enable_corrections,
    )


def iter_audio_chunks(audio_path: Path, chunk_samples: int, overlap_samples: int):
    import soundfile as sf

    stride_samples = max(chunk_samples - overlap_samples, 1)
    with sf.SoundFile(str(audio_path)) as audio_file:
        sample_rate = audio_file.samplerate
        total_frames = len(audio_file)
        start = 0
        index = 0
        while start < total_frames:
            audio_file.seek(start)
            frames_to_read = min(chunk_samples, total_frames - start)
            chunk = audio_file.read(frames_to_read, dtype="float32", always_2d=False)
            if getattr(chunk, "ndim", 1) > 1:
                chunk = chunk.mean(axis=1)
            end = start + len(chunk)
            yield index, start / sample_rate, end / sample_rate, chunk
            index += 1
            if end >= total_frames:
                break
            start += stride_samples


def resolve_run_cache_dir(
    cache_dir: Path | None,
    audio_path: Path,
    model_id: str,
    hotwords: list[str],
    enable_corrections: bool,
    chunk_seconds: float,
    overlap_seconds: float,
    runtime: str = "glm",
) -> Path | None:
    if cache_dir is None:
        return None
    try:
        stat = audio_path.stat()
        payload = {
            "audio": str(audio_path.resolve()),
            "size": stat.st_size,
            "mtime": int(stat.st_mtime),
            "model": model_id,
            "runtimeVersion": "glm-repetition-guard-v2" if runtime == "glm" else runtime,
            "hotwords": hotwords,
            "enableCorrections": enable_corrections,
            "chunkSeconds": chunk_seconds,
            "overlapSeconds": overlap_seconds,
        }
        digest = hashlib.sha256(json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()[:24]
        path = cache_dir / "long-audio" / runtime / digest
        path.mkdir(parents=True, exist_ok=True)
        return path
    except Exception:
        return None


def read_cached_segment(cache_dir: Path | None, index: int) -> dict | None:
    if cache_dir is None:
        return None
    path = cache_dir / f"segment-{index:05d}.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def write_cached_segment(cache_dir: Path | None, index: int, payload: dict, filename: str | None = None):
    if cache_dir is None:
        return
    path = cache_dir / (filename or f"segment-{index:05d}.json")
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def emit_progress(stage: str, fraction: float, elapsed: float, estimated_remaining: float | None, partial_text: str, extra: dict | None = None):
    payload = {
        "stage": stage,
        "fraction": fraction,
        "elapsed": elapsed,
        "estimatedRemaining": estimated_remaining,
        "partialText": partial_text,
    }
    if extra:
        payload.update(extra)
    print("LOCAL_ASR_PROGRESS " + json.dumps(payload, ensure_ascii=False), file=sys.stderr, flush=True)


def format_bytes(value: int) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    amount = float(max(value, 0))
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            return f"{amount:.1f}{unit}" if unit != "B" else f"{int(amount)}B"
        amount /= 1024
    return f"{int(value)}B"


def expected_forced_aligner_bytes(model_id: str) -> int:
    if model_id == "Qwen/Qwen3-ForcedAligner-0.6B":
        return 1_835_544_544
    return int(os.environ.get("LOCAL_ASR_QWEN_ALIGNER_BYTES", "0") or "0")


def find_forced_aligner_downloads(forced_aligner: str) -> list[Path]:
    hf_home = Path(os.environ.get("HF_HOME", "")).expanduser()
    if not str(hf_home):
        return []
    repo_dir = "models--" + forced_aligner.replace("/", "--")
    root = hf_home / "hub" / repo_dir
    if not root.exists():
        return []
    return sorted(root.glob("blobs/*.incomplete")) + sorted(root.glob("blobs/*"))


def start_forced_aligner_watchdog(forced_aligner: str, started: float, stop_event: threading.Event) -> threading.Thread:
    expected = expected_forced_aligner_bytes(forced_aligner)
    stall_seconds = float(os.environ.get("LOCAL_ASR_ALIGNER_STALL_SECONDS", "90"))

    def run():
        last_size = -1
        last_growth = time.perf_counter()
        while not stop_event.wait(2.0):
            paths = find_forced_aligner_downloads(forced_aligner)
            active_paths = [path for path in paths if path.suffix == ".incomplete"]
            complete_paths = [path for path in paths if path.suffix != ".incomplete"]
            size = max((path.stat().st_size for path in active_paths + complete_paths if path.exists()), default=0)
            if size > last_size:
                last_size = size
                last_growth = time.perf_counter()

            if expected > 0 and size >= expected and complete_paths:
                emit_progress(
                    "Qwen 时间戳对齐器已就绪",
                    0.18,
                    time.perf_counter() - started,
                    None,
                    f"{format_bytes(size)} / {format_bytes(expected)}",
                )
                return

            fraction = 0.08
            if expected > 0:
                fraction = 0.08 + min(max(size / expected, 0), 1) * 0.10
            remaining = None
            elapsed_since_growth = max(time.perf_counter() - last_growth, 0)
            emit_progress(
                "下载 Qwen 时间戳对齐器",
                min(fraction, 0.18),
                time.perf_counter() - started,
                remaining,
                f"{format_bytes(size)} / {format_bytes(expected) if expected > 0 else '未知大小'}",
            )

            if size > 0 and elapsed_since_growth >= stall_seconds:
                print(
                    "Qwen3-ASR 时间戳对齐器下载停滞："
                    f"{format_bytes(size)} 已下载，但 {int(elapsed_since_growth)} 秒没有继续增长。"
                    "请检查网络后重试；普通非时间戳 Qwen 路线不受影响。",
                    file=sys.stderr,
                    flush=True,
                )
                os._exit(3)

    thread = threading.Thread(target=run, name="qwen-aligner-watchdog", daemon=True)
    thread.start()
    return thread


def clean_glm_text(text: str, hotwords: list[str], enable_corrections: bool) -> str:
    prefixes = [
        "Please transcribe this audio into text",
        "Transcribe this audio into text",
    ]
    cleaned = text.strip()
    for prefix in prefixes:
        if cleaned.startswith(prefix):
            cleaned = cleaned[len(prefix):].strip()
    return apply_asr_corrections(cleaned, hotwords) if enable_corrections else cleaned


def is_glm_repetition_failure(text: str) -> bool:
    import re

    normalized = re.sub(r"[\s，。！？、,.!?；;：“”\"'（）()\[\]{}<>《》…—-]+", "", text or "")
    if len(normalized) < 32:
        return False

    filler_chars = set("嗯呃啊哦喔唔哼额呐呀诶")
    filler_count = sum(1 for char in normalized if char in filler_chars)
    if filler_count / max(len(normalized), 1) >= 0.55 and len(set(normalized)) <= 10:
        return True

    units = [unit.strip() for unit in re.split(r"[。！？!?；;\n]+", text or "") if unit.strip()]
    if len(units) >= 10:
        unit_counts: dict[str, int] = {}
        for unit in units:
            key = re.sub(r"[\s，、,.]+", "", unit)
            if not key:
                continue
            unit_counts[key] = unit_counts.get(key, 0) + 1
        if unit_counts:
            most_common = max(unit_counts.values())
            if most_common >= 8 and most_common / len(units) >= 0.55:
                return True

    for width in range(1, 7):
        if len(normalized) < width * 10:
            continue
        chunks = [normalized[index:index + width] for index in range(0, len(normalized) - width + 1, width)]
        if not chunks:
            continue
        current = 1
        longest = 1
        for previous, current_chunk in zip(chunks, chunks[1:]):
            if current_chunk == previous:
                current += 1
                longest = max(longest, current)
            else:
                current = 1
        if longest >= 12:
            return True

    return False


def merge_transcripts(texts: list[str], hotwords: list[str], enable_corrections: bool) -> str:
    merged = ""
    for text in texts:
        text = text.strip()
        if not text:
            continue
        if not merged:
            merged = text
            continue
        overlap = longest_overlap(merged, text, max_chars=120)
        if overlap > 0:
            merged += text[overlap:]
        else:
            merged += "\n" + text
    merged = remove_repeated_boundary_text(merged.strip())
    return apply_asr_corrections(merged, hotwords) if enable_corrections else merged


def longest_overlap(left: str, right: str, max_chars: int) -> int:
    left_tail = normalize_for_overlap(left[-max_chars:])
    best = 0
    for length in range(min(len(right), max_chars), 3, -1):
        candidate = normalize_for_overlap(right[:length])
        if candidate and left_tail.endswith(candidate):
            best = length
            break
    return best


def normalize_for_overlap(text: str) -> str:
    punctuation = "，。！？、,.!? \n\t"
    return "".join(ch for ch in text if ch not in punctuation)


def apply_asr_corrections(text: str, hotwords: list[str]) -> str:
    replacements = parse_correction_rules(hotwords)
    for wrong, right in replacements.items():
        text = text.replace(wrong, right)
    return text


def parse_correction_rules(hotwords: list[str]) -> dict[str, str]:
    rules = {}
    for item in hotwords:
        if "=>" in item:
            wrong, right = item.split("=>", 1)
        elif "->" in item:
            wrong, right = item.split("->", 1)
        else:
            continue
        wrong = wrong.strip()
        right = right.strip()
        if wrong and right:
            rules[wrong] = right
    return rules


def remove_repeated_boundary_text(text: str) -> str:
    import re

    text = re.sub(r"([^。！？\n]{6,40}[。！？，])\n?\1", r"\1", text)
    return text


def run_auto_asr(model_id: str, audio_path: Path) -> str:
    from transformers import pipeline

    pipe = pipeline(
        "automatic-speech-recognition",
        model=model_id,
        trust_remote_code=True,
        device_map="auto",
    )
    result = pipe(str(audio_path))
    if isinstance(result, dict):
        return str(result.get("text", "")).strip()
    return str(result).strip()


def write_audio_chunk(path: Path, chunk, sample_rate: int):
    import soundfile as sf

    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), chunk, sample_rate)


def decode_qwen_result(results) -> str:
    if not results:
        return ""
    first = results[0]
    return str(getattr(first, "text", first)).strip()


def qwen_timestamp_segments(results, offset_seconds: float) -> list[dict]:
    if not results:
        return []
    stamps = getattr(results[0], "time_stamps", None)
    items = getattr(stamps, "items", None)
    if not items:
        return []

    segments = []
    for item in items:
        text = str(getattr(item, "text", "")).strip()
        if not text:
            continue
        start = getattr(item, "start_time", None)
        end = getattr(item, "end_time", None)
        if start is None or end is None:
            continue
        segments.append(
            {
                "start": round(float(start) + offset_seconds, 3),
                "end": round(float(end) + offset_seconds, 3),
                "text": text,
            }
        )
    return segments


def format_timestamp(seconds: float) -> str:
    seconds = max(float(seconds), 0.0)
    total = int(seconds)
    millis = int(round((seconds - total) * 1000))
    if millis >= 1000:
        total += 1
        millis -= 1000
    hours = total // 3600
    minutes = (total % 3600) // 60
    secs = total % 60
    if hours > 0:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"
    return f"{minutes:02d}:{secs:02d}.{millis:03d}"


def timestamped_text(segments: list[dict]) -> str:
    lines = []
    for segment in segments:
        text = str(segment.get("text", "")).strip()
        if not text:
            continue
        start = format_timestamp(float(segment.get("start", 0)))
        end = format_timestamp(float(segment.get("end", 0)))
        lines.append(f"[{start} - {end}] {text}")
    return "\n".join(lines).strip()


def sentence_timestamp_segments(segment_texts: list[dict], max_chars: int = 48) -> list[dict]:
    display_segments = []
    next_start = 0.0
    previous_text = ""
    for segment in sorted(segment_texts, key=lambda item: (float(item.get("start", 0)), int(item.get("index", 0)))):
        text = trim_repeated_prefix(str(segment.get("text", "")).strip(), previous_text)
        if not text:
            continue
        start = max(float(segment.get("start", 0)), next_start)
        end = max(float(segment.get("end", start)), start + 0.2)
        if end <= start + 0.05:
            continue
        units = split_subtitle_units(text, max_chars=max_chars)
        if not units:
            continue
        weights = [max(len(normalize_subtitle_text(unit)), 1) for unit in units]
        total_weight = max(sum(weights), 1)
        cursor = start
        duration = max(end - start, 0.2)
        for index, unit in enumerate(units):
            if index == len(units) - 1:
                unit_end = end
            else:
                unit_end = start + duration * (sum(weights[: index + 1]) / total_weight)
            unit_end = max(unit_end, cursor + 0.2)
            display_segments.append(
                {
                    "start": round(cursor, 3),
                    "end": round(min(unit_end, end), 3),
                    "text": unit.strip(),
                }
            )
            cursor = min(unit_end, end)
        next_start = max(next_start, end)
        previous_text += text
    return display_segments


def trim_repeated_prefix(text: str, previous_text: str, max_chars: int = 90) -> str:
    if not text or not previous_text:
        return text
    previous_tail = normalize_for_overlap(previous_text[-max_chars:])
    limit = min(len(text), max_chars)
    for length in range(limit, 4, -1):
        candidate = normalize_for_overlap(text[:length])
        if candidate and previous_tail.endswith(candidate):
            trimmed = text[length:].lstrip("，。！？、,.!?；; ")
            if trimmed.startswith(("的", "了", "着", "过", "们")):
                return text
            return trimmed
    return text


def split_subtitle_units(text: str, max_chars: int = 48) -> list[str]:
    import re

    normalized = re.sub(r"\s+", "", text.strip())
    if not normalized:
        return []
    pieces = [piece for piece in re.split(r"(?<=[。！？!?；;])", normalized) if piece]
    units = []
    for piece in pieces or [normalized]:
        while len(piece) > max_chars:
            split_at = subtitle_split_index(piece, max_chars)
            units.append(piece[:split_at])
            piece = piece[split_at:]
        if piece:
            units.append(piece)
    return units


def subtitle_split_index(text: str, max_chars: int) -> int:
    punctuation = "，、,：: "
    limit = min(max_chars, len(text))
    for index in range(limit, max(4, limit // 3), -1):
        if text[index - 1] in punctuation:
            return index
    return limit


def compact_timestamp_segments(
    segments: list[dict],
    min_duration: float = 2.0,
    max_duration: float = 6.0,
    max_chars: int = 42,
) -> list[dict]:
    compacted = []
    current: dict | None = None

    def flush():
        nonlocal current
        if current is not None and str(current.get("text", "")).strip():
            current["text"] = normalize_subtitle_text(str(current["text"]))
            compacted.append(current)
        current = None

    for segment in sorted(segments, key=lambda item: float(item.get("start", 0))):
        text = normalize_subtitle_text(str(segment.get("text", "")))
        if not text:
            continue
        start = float(segment.get("start", 0))
        end = max(float(segment.get("end", start)), start)

        if current is None:
            current = {"start": round(start, 3), "end": round(end, 3), "text": text}
            continue

        current_end = float(current.get("end", start))
        current_start = float(current.get("start", start))
        gap = start - current_end
        candidate_text = normalize_subtitle_text(str(current.get("text", "")) + text)
        candidate_duration = max(end - current_start, 0)
        current_text = str(current.get("text", ""))
        current_duration = max(current_end - current_start, 0)
        should_flush = (
            gap > 0.8
            or len(candidate_text) > max_chars
            or candidate_duration > max_duration
            or (current_duration >= min_duration and ends_sentence(current_text))
        )

        if should_flush:
            flush()
            current = {"start": round(start, 3), "end": round(end, 3), "text": text}
        else:
            current["end"] = round(end, 3)
            current["text"] = candidate_text

    flush()
    return compacted


def normalize_subtitle_text(text: str) -> str:
    return "".join(str(text).split())


def ends_sentence(text: str) -> bool:
    return text.rstrip().endswith(("。", "！", "？", ".", "!", "?", "；", ";"))


def run_qwen_asr(
    model_id: str,
    audio_path: Path,
    source_audio_path: Path,
    hotwords: list[str],
    enable_corrections: bool,
    cache_dir: Path | None,
    chunk_seconds: float,
    overlap_seconds: float,
    return_timestamps: bool,
    forced_aligner: str,
) -> dict:
    import torch
    import soundfile as sf
    from qwen_asr import Qwen3ASRModel

    if return_timestamps:
        chunk_seconds = min(chunk_seconds, 30.0)
        overlap_seconds = min(max(overlap_seconds, 1.5), 3.0)

    duration = audio_duration(audio_path)
    run_cache_dir = resolve_run_cache_dir(
        cache_dir=cache_dir,
        audio_path=source_audio_path,
        model_id=model_id,
        hotwords=hotwords,
        enable_corrections=enable_corrections,
        chunk_seconds=chunk_seconds,
        overlap_seconds=overlap_seconds,
        runtime="qwen-timestamps" if return_timestamps else "qwen",
    )

    if torch.backends.mps.is_available():
        device_map = "mps"
        dtype = torch.float16
    else:
        device_map = "cpu"
        dtype = torch.float32

    model_kwargs = {}
    if return_timestamps:
        model_kwargs["forced_aligner"] = forced_aligner

    if return_timestamps:
        emit_progress(
            stage="加载 Qwen 时间戳对齐器",
            fraction=0.08,
            elapsed=0,
            estimated_remaining=None,
            partial_text="",
        )

    aligner_stop_event = threading.Event()
    aligner_watchdog = None
    if return_timestamps:
        aligner_watchdog = start_forced_aligner_watchdog(forced_aligner, time.perf_counter(), aligner_stop_event)

    try:
        model = Qwen3ASRModel.from_pretrained(
            model_id,
            dtype=dtype,
            device_map=device_map,
            max_inference_batch_size=1,
            max_new_tokens=2048,
            **model_kwargs,
        )
    except Exception as exc:
        message = str(exc)
        if return_timestamps and ("xet" in message.lower() or "416" in message or "incomplete" in message.lower()):
            fail(
                "Qwen3-ASR 时间戳对齐器下载失败。当前 HuggingFace/Xet 缓存可能有未完成断点文件，"
                "请稍后重试或先预下载 Qwen/Qwen3-ForcedAligner-0.6B；普通非时间戳 Qwen 路线不受影响。\n"
                f"原始错误：{message}"
            )
        raise
    finally:
        if return_timestamps:
            aligner_stop_event.set()
            if aligner_watchdog is not None:
                aligner_watchdog.join(timeout=1)

    info = sf.info(str(audio_path))
    sample_rate = info.samplerate
    chunk_samples = max(int(sample_rate * chunk_seconds), sample_rate)
    overlap_samples = min(max(int(sample_rate * overlap_seconds), 0), chunk_samples // 2)
    total_chunks = max(math.ceil(max(info.frames - overlap_samples, 1) / max(chunk_samples - overlap_samples, 1)), 1)
    started = time.perf_counter()
    texts = []
    segment_texts = []
    timestamp_segments = []
    cached_count = 0
    completed_count = 0

    with tempfile.TemporaryDirectory(prefix="local-asr-qwen-segments-") as tmp:
        tmpdir = Path(tmp)
        for index, start_seconds, end_seconds, chunk in iter_audio_chunks(audio_path, chunk_samples, overlap_samples):
            if len(chunk) < sample_rate * 0.2:
                continue

            cached = read_cached_segment(run_cache_dir, index)
            if cached is not None:
                text = cached.get("text", "")
                timestamp_segments.extend(cached.get("timestampSegments", []))
                cached_count += 1
            else:
                segment_path = tmpdir / f"segment-{index:05d}.wav"
                write_audio_chunk(segment_path, chunk, sample_rate)
                results = model.transcribe(
                    audio=str(segment_path),
                    language=None,
                    return_time_stamps=return_timestamps,
                )
                text = decode_qwen_result(results)
                text = apply_asr_corrections(text, hotwords) if enable_corrections else text
                segment_timestamps = qwen_timestamp_segments(results, start_seconds) if return_timestamps else []
                if return_timestamps and not segment_timestamps and text:
                    segment_timestamps = [
                        {
                            "start": round(start_seconds, 3),
                            "end": round(end_seconds, 3),
                            "text": text,
                        }
                    ]
                write_cached_segment(
                    run_cache_dir,
                    index,
                    {
                        "index": index,
                        "start": start_seconds,
                        "end": end_seconds,
                        "text": text,
                        "timestampSegments": segment_timestamps,
                    },
                )
                timestamp_segments.extend(segment_timestamps)

            if text:
                segment_texts.append(
                    {
                        "index": index,
                        "start": start_seconds,
                        "end": end_seconds,
                        "text": text,
                    }
                )

            completed_count += 1
            elapsed = time.perf_counter() - started
            fraction = min(completed_count / total_chunks, 0.98)
            emit_progress(
                stage=f"Qwen 片段 {completed_count}/{total_chunks}",
                fraction=fraction,
                elapsed=elapsed,
                estimated_remaining=(elapsed / fraction - elapsed) if fraction > 0 else None,
                partial_text=text,
                extra={
                    "segmentIndex": index,
                    "segmentStart": start_seconds,
                    "segmentEnd": end_seconds,
                    "cachedSegments": cached_count,
                    "totalSegments": total_chunks,
                },
            )
            if text:
                texts.append(text)

    merged = merge_transcripts(texts, hotwords=hotwords, enable_corrections=enable_corrections)
    display_segments = sentence_timestamp_segments(segment_texts) if return_timestamps and segment_texts else []
    if return_timestamps and not display_segments and timestamp_segments:
        display_segments = compact_timestamp_segments(timestamp_segments)
    display_text = timestamped_text(display_segments) if display_segments else merged
    if run_cache_dir is not None:
        write_cached_segment(
            run_cache_dir,
            -1,
            {
                "text": display_text,
                "plainText": merged,
                "duration": duration,
                "chunkSeconds": chunk_seconds,
                "overlapSeconds": overlap_seconds,
                "segments": completed_count,
                "textSegments": segment_texts,
                "timestampSegments": timestamp_segments,
                "displayTimestampSegments": display_segments,
                "cachedSegments": cached_count,
            },
            filename="merged.json",
        )
    return {
        "text": display_text,
        "plainText": merged,
        "duration": duration,
        "segments": display_segments or timestamp_segments,
        "segmentCount": completed_count,
        "cachedSegments": cached_count,
    }


def main():
    os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
    os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "0")
    os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "30")

    parser = argparse.ArgumentParser()
    parser.add_argument("--model-kind", required=True, choices=["glm", "mimo", "qwen", "auto"])
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--audio", required=True)
    parser.add_argument("--hotwords-json", default="[]")
    parser.add_argument("--enable-corrections", action="store_true")
    parser.add_argument("--cache-dir")
    parser.add_argument("--chunk-seconds", type=float, default=30.0)
    parser.add_argument("--overlap-seconds", type=float, default=1.5)
    parser.add_argument("--max-new-tokens", type=int, default=900)
    parser.add_argument("--return-timestamps", action="store_true")
    parser.add_argument("--forced-aligner", default="Qwen/Qwen3-ForcedAligner-0.6B")
    args = parser.parse_args()

    try:
        import transformers  # noqa: F401
        import soundfile  # noqa: F401
        import torch  # noqa: F401
    except Exception as exc:
        fail(f"缺少 HuggingFace/PyTorch 推理依赖：{exc}\n请运行：python3 -m pip install transformers accelerate torch soundfile")

    source_audio_path = Path(args.audio)
    audio_path = ensure_wav(source_audio_path)
    try:
        hotwords = json.loads(args.hotwords_json)
        if not isinstance(hotwords, list):
            hotwords = []
        hotwords = [str(item) for item in hotwords]
    except Exception:
        hotwords = []
    start = time.perf_counter()

    if args.model_kind == "glm":
        text = run_glm_asr(
            args.model_id,
            audio_path,
            source_audio_path,
            hotwords,
            args.enable_corrections,
            Path(args.cache_dir) if args.cache_dir else None,
            max(args.chunk_seconds, 5.0),
            max(args.overlap_seconds, 0.0),
            max(args.max_new_tokens, 128),
        )
        payload = {
            "text": text,
            "duration": audio_duration(audio_path),
            "elapsed": time.perf_counter() - start,
        }
    elif args.model_kind == "qwen":
        payload = run_qwen_asr(
            args.model_id,
            audio_path,
            source_audio_path,
            hotwords,
            args.enable_corrections,
            Path(args.cache_dir) if args.cache_dir else None,
            max(args.chunk_seconds, 5.0),
            max(args.overlap_seconds, 0.0),
            args.return_timestamps,
            args.forced_aligner,
        )
        payload["elapsed"] = time.perf_counter() - start
    else:
        text = run_auto_asr(args.model_id, audio_path)
        payload = {
            "text": text,
            "duration": audio_duration(audio_path),
            "elapsed": time.perf_counter() - start,
        }

    print(json.dumps(payload, ensure_ascii=False))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import argparse
import hashlib
import inspect
import json
import math
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

RUNTIME_VERSION = "mimo-mlx-completeness-v2"
MERGE_STRATEGY_VERSION = "conservative-overlap-v2"


def fail(message: str, code: int = 2):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def ensure_wav(audio_path: Path) -> Path:
    if audio_path.suffix.lower() == ".wav":
        return audio_path

    tmp = Path(tempfile.mkdtemp(prefix="local-asr-mimo-mlx-audio-")) / "input.wav"
    ffmpeg = Path("/opt/homebrew/bin/ffmpeg")
    if ffmpeg.exists():
        command = [
            str(ffmpeg),
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", str(audio_path),
            "-ac", "1",
            "-ar", "24000",
            str(tmp),
        ]
    else:
        command = [
            "/usr/bin/afconvert",
            "-f", "WAVE",
            "-d", "LEI16@24000",
            "-c", "1",
            str(audio_path),
            str(tmp),
        ]

    completed = subprocess.run(command, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if completed.returncode != 0:
        fail(completed.stderr or f"音频转换失败：{audio_path}")
    return tmp


def audio_duration(audio_path: Path) -> float:
    import soundfile as sf

    info = sf.info(str(audio_path))
    return float(info.frames / info.samplerate) if info.samplerate else 0.0


def iter_audio_chunks(audio_path: Path, chunk_seconds: float, overlap_seconds: float):
    import soundfile as sf

    with sf.SoundFile(str(audio_path)) as audio_file:
        sample_rate = audio_file.samplerate
        total_frames = len(audio_file)
        chunk_frames = max(int(sample_rate * chunk_seconds), sample_rate)
        overlap_frames = min(max(int(sample_rate * overlap_seconds), 0), chunk_frames // 2)
        stride_frames = max(chunk_frames - overlap_frames, 1)
        start = 0
        index = 0
        while start < total_frames:
            audio_file.seek(start)
            frames_to_read = min(chunk_frames, total_frames - start)
            chunk = audio_file.read(frames_to_read, dtype="float32", always_2d=False)
            if getattr(chunk, "ndim", 1) > 1:
                chunk = chunk.mean(axis=1)
            end = start + len(chunk)
            yield index, start / sample_rate, end / sample_rate, sample_rate, chunk
            index += 1
            if end >= total_frames:
                break
            start += stride_frames


def total_chunk_count(audio_path: Path, chunk_seconds: float, overlap_seconds: float) -> int:
    import soundfile as sf

    info = sf.info(str(audio_path))
    chunk_frames = max(int(info.samplerate * chunk_seconds), info.samplerate)
    overlap_frames = min(max(int(info.samplerate * overlap_seconds), 0), chunk_frames // 2)
    stride_frames = max(chunk_frames - overlap_frames, 1)
    return max(math.ceil(max(info.frames - overlap_frames, 1) / stride_frames), 1)


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


def write_json_atomic(path: Path, payload: dict):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


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


def write_cached_segment(cache_dir: Path | None, index: int, payload: dict):
    if cache_dir is None:
        return
    write_json_atomic(cache_dir / f"segment-{index:05d}.json", payload)


def resolve_run_cache_dir(cache_dir: Path | None, source_audio_path: Path, args) -> Path | None:
    if cache_dir is None:
        return None
    try:
        stat = source_audio_path.stat()
        payload = {
            "audio": str(source_audio_path.resolve()),
            "size": stat.st_size,
            "mtime": int(stat.st_mtime),
            "modelPath": args.model_path,
            "language": args.language,
            "maxNewTokens": args.max_new_tokens,
            "chunkSeconds": args.chunk_seconds,
            "overlapSeconds": args.overlap_seconds,
            "runtimeVersion": RUNTIME_VERSION,
            "mergeStrategy": MERGE_STRATEGY_VERSION,
        }
        digest = hashlib.sha256(json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()[:24]
        path = cache_dir / "long-audio" / "mimo-mlx" / digest
        path.mkdir(parents=True, exist_ok=True)
        return path
    except Exception:
        return None


def merge_transcripts(texts: list[str]) -> str:
    merged = ""
    for text in texts:
        text = text.strip()
        if not text:
            continue
        if not merged:
            merged = text
            continue
        overlap = longest_overlap(merged, text, max_chars=90)
        merged += text[overlap:] if overlap > 0 else "\n" + text
    return merged.strip()


def longest_overlap(left: str, right: str, max_chars: int) -> int:
    left_tail = normalize_for_overlap(left[-max_chars:])
    for raw_length in range(min(len(right), max_chars), 7, -1):
        raw_candidate = right[:raw_length]
        candidate = normalize_for_overlap(raw_candidate)
        if len(candidate) < 10:
            continue
        if candidate and left_tail.endswith(candidate):
            return raw_length
    return 0


def normalize_for_overlap(text: str) -> str:
    punctuation = "，。！？、,.!? \n\t"
    return "".join(ch for ch in text if ch not in punctuation)


def clean_text(text: str) -> str:
    return text.replace("<chinese>", "").replace("<english>", "").strip()


def generated_text(result) -> str:
    if isinstance(result, str):
        return result
    if isinstance(result, dict):
        for key in ("text", "transcription", "result"):
            value = result.get(key)
            if isinstance(value, str):
                return value
    value = getattr(result, "text", None)
    if isinstance(value, str):
        return value
    return str(result)


def count_cjk_or_alnum(text: str) -> int:
    return sum(1 for ch in text if "\u4e00" <= ch <= "\u9fff" or ch.isalnum())


def suspiciously_short_segment(text: str, start_seconds: float, end_seconds: float) -> bool:
    duration = max(end_seconds - start_seconds, 0.0)
    if duration < 20:
        return False
    return count_cjk_or_alnum(text) < max(12, int(duration * 0.8))


def generate_kwargs_for_budget(generate, language: str, max_new_tokens: int) -> dict:
    kwargs = {}
    if language != "auto":
        kwargs["language"] = "zh" if language == "zh" else "en"
    try:
        signature = inspect.signature(generate)
        parameters = signature.parameters
        accepts_kwargs = any(param.kind == inspect.Parameter.VAR_KEYWORD for param in parameters.values())
        if accepts_kwargs or "max_new_tokens" in parameters:
            kwargs["max_new_tokens"] = max_new_tokens
        elif "max_tokens" in parameters:
            kwargs["max_tokens"] = max_new_tokens
        elif "max_length" in parameters:
            kwargs["max_length"] = max_new_tokens
    except (TypeError, ValueError):
        pass
    return kwargs


def generate_segment(model, audio_path: Path, language: str, max_new_tokens: int) -> str:
    generate = model.generate
    kwargs = generate_kwargs_for_budget(generate, language, max_new_tokens)
    try:
        return clean_text(generated_text(generate(str(audio_path), **kwargs)))
    except TypeError as exc:
        if "max_new_tokens" not in kwargs and "max_tokens" not in kwargs and "max_length" not in kwargs:
            raise
        fallback_kwargs = {"language": kwargs["language"]} if "language" in kwargs else {}
        print(f"MiMo MLX generation budget was not accepted, retrying without it: {exc}", file=sys.stderr, flush=True)
        return clean_text(generated_text(generate(str(audio_path), **fallback_kwargs)))


def run_transcription(args, source_audio_path: Path, audio_path: Path, run_cache_dir: Path | None) -> dict:
    try:
        from mlx_audio.stt import load
    except Exception as exc:
        fail(f"缺少 MiMo MLX 推理依赖：{exc}\n请运行：./script/setup_mimo_mlx_runtime.sh")

    import soundfile as sf

    overall_start = time.perf_counter()
    print("Loading MiMo MLX...", file=sys.stderr, flush=True)
    model = load(args.model_path)
    load_elapsed = time.perf_counter() - overall_start

    transcribe_start = time.perf_counter()
    duration = audio_duration(audio_path)
    total_segments = total_chunk_count(audio_path, args.chunk_seconds, args.overlap_seconds)
    texts = []
    cached_count = 0
    completed_count = 0

    with tempfile.TemporaryDirectory(prefix="local-asr-mimo-mlx-segments-") as segment_dir_name:
        segment_dir = Path(segment_dir_name)
        for index, start_seconds, end_seconds, sample_rate, chunk in iter_audio_chunks(audio_path, args.chunk_seconds, args.overlap_seconds):
            cached = read_cached_segment(run_cache_dir, index)
            if cached is not None and suspiciously_short_segment(cached.get("text", ""), start_seconds, end_seconds):
                cached = None

            if cached is not None:
                text = cached.get("text", "")
                cached_count += 1
            else:
                segment_path = segment_dir / f"segment-{index:05d}.wav"
                sf.write(str(segment_path), chunk, sample_rate)
                print(f"Generating MLX transcript for segment {index + 1}/{total_segments}...", file=sys.stderr, flush=True)
                text = generate_segment(model, segment_path, args.language, args.max_new_tokens)
                low_output_suspicion = suspiciously_short_segment(text, start_seconds, end_seconds)
                write_cached_segment(
                    run_cache_dir,
                    index,
                    {
                        "index": index,
                        "start": start_seconds,
                        "end": end_seconds,
                        "text": text,
                        "device": "mlx",
                        "maxNewTokens": args.max_new_tokens,
                        "runtimeVersion": RUNTIME_VERSION,
                        "lowOutputSuspicion": low_output_suspicion,
                    },
                )

            completed_count += 1
            segment_elapsed = time.perf_counter() - transcribe_start
            elapsed = time.perf_counter() - overall_start
            fraction = min(completed_count / total_segments, 0.98)
            estimated_remaining = (segment_elapsed / fraction - segment_elapsed) if fraction > 0 and cached_count < completed_count else None
            emit_progress(
                stage=f"MLX 片段 {completed_count}/{total_segments}",
                fraction=fraction,
                elapsed=elapsed,
                estimated_remaining=estimated_remaining,
                partial_text=text,
                extra={
                    "segmentIndex": index,
                    "segmentStart": start_seconds,
                    "segmentEnd": end_seconds,
                    "cachedSegments": cached_count,
                    "totalSegments": total_segments,
                    "lowOutputSuspicion": suspiciously_short_segment(text, start_seconds, end_seconds),
                },
            )
            if text:
                texts.append(text)

    text = merge_transcripts(texts)
    transcribe_elapsed = time.perf_counter() - overall_start
    if run_cache_dir is not None:
        write_json_atomic(
            run_cache_dir / "merged.json",
            {
                "text": text,
                "duration": duration,
                "chunkSeconds": args.chunk_seconds,
                "overlapSeconds": args.overlap_seconds,
                "maxNewTokens": args.max_new_tokens,
                "segments": completed_count,
                "cachedSegments": cached_count,
                "device": "mlx",
                "runtimeVersion": RUNTIME_VERSION,
                "mergeStrategy": MERGE_STRATEGY_VERSION,
            },
        )

    return {
        "text": text,
        "duration": duration,
        "device": "mlx",
        "loadElapsed": load_elapsed,
        "transcribeElapsed": transcribe_elapsed,
        "mpsFallbackReason": None,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-path", required=True)
    parser.add_argument("--audio", required=True)
    parser.add_argument("--language", choices=["auto", "zh", "en"], default="auto")
    parser.add_argument("--cache-dir")
    parser.add_argument("--chunk-seconds", type=float, default=30.0)
    parser.add_argument("--overlap-seconds", type=float, default=3.0)
    parser.add_argument("--max-new-tokens", type=int, default=1200)
    args = parser.parse_args()

    source_audio_path = Path(args.audio).expanduser()
    audio_path = ensure_wav(source_audio_path)
    run_cache_dir = resolve_run_cache_dir(Path(args.cache_dir) if args.cache_dir else None, source_audio_path, args)
    emit_progress(
        stage="MiMo MLX 设备：Apple Silicon",
        fraction=0.06,
        elapsed=0,
        estimated_remaining=None,
        partial_text="",
    )
    result = run_transcription(args, source_audio_path, audio_path, run_cache_dir)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()

import gradio as gr
import torch
import torchaudio
import soundfile as sf
import pandas as pd
import subprocess
import tempfile
import time
import numpy as np
import os

from transformers import (
    AutoTokenizer,
    AutoModelForCausalLM
)

from faster_whisper import WhisperModel

from model import CNN2D

# =========================================================
# CONFIG
# =========================================================

DEVICE = "cpu"

MODEL_PATH = "best_phone_model.pth"

TARGET_SR = 16000
TARGET_LEN = 64000

# =========================================================
# STARTUP
# =========================================================

print("=" * 60)
print("CPU INDUSTRIAL AI VOICE DETECTOR")
print("=" * 60)

# =========================================================
# LOAD CNN
# =========================================================

print("Loading CNN model...")

model = CNN2D()

checkpoint = torch.load(
    MODEL_PATH,
    map_location=DEVICE
)

model.load_state_dict(checkpoint)

model.to(DEVICE)
model.eval()

print("CNN ready")

# =========================================================
# LOAD WHISPER
# =========================================================

print("Loading Whisper tiny...")

whisper_model = WhisperModel(
    "tiny",
    device="cpu",
    compute_type="int8"
)

print("Whisper ready")

# =========================================================
# LOAD GEMMA4
# =========================================================

print("Loading Gemma4...")

tokenizer = AutoTokenizer.from_pretrained(
    "google/gemma-4-e2b-it"
)

gemma_model = AutoModelForCausalLM.from_pretrained(
    "google/gemma-4-e2b-it",
    torch_dtype=torch.float32,
    low_cpu_mem_usage=True
)

gemma_model.to("cpu")
gemma_model.eval()

print("Gemma4 ready")

# =========================================================
# MEL
# =========================================================

mel_transform = torchaudio.transforms.MelSpectrogram(
    sample_rate=TARGET_SR,
    n_fft=1024,
    hop_length=512,
    n_mels=64
)

# =========================================================
# AUDIO NORMALIZATION
# =========================================================

def normalize_audio(path):

    tmp = tempfile.NamedTemporaryFile(
        delete=False,
        suffix=".wav"
    )

    tmp.close()

    result = subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-i",
            path,
            "-ar",
            str(TARGET_SR),
            "-ac",
            "1",
            tmp.name
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

    if result.returncode != 0:

        raise Exception(
            "FFmpeg failed. Please install ffmpeg."
        )

    return tmp.name

# =========================================================
# LOAD AUDIO
# =========================================================

def load_audio(path):

    wav, sr = sf.read(path)

    # stereo -> mono
    if len(wav.shape) > 1:
        wav = wav.mean(axis=1)

    wav = torch.tensor(wav).float()

    # resample
    if sr != TARGET_SR:

        resampler = torchaudio.transforms.Resample(
            sr,
            TARGET_SR
        )

        wav = resampler(wav)

    # waveform normalize
    wav = (
        wav - wav.mean()
    ) / (
        wav.std() + 1e-8
    )

    # pad / truncate
    if wav.shape[0] < TARGET_LEN:

        wav = torch.nn.functional.pad(
            wav,
            (
                0,
                TARGET_LEN - wav.shape[0]
            )
        )

    else:

        wav = wav[:TARGET_LEN]

    return wav

# =========================================================
# FEATURE EXTRACTION
# =========================================================

def extract_feature(wav):

    mel = mel_transform(wav)

    mel = torch.log(mel + 1e-6)

    # normalize
    mel = (
        mel - mel.mean()
    ) / (
        mel.std() + 1e-8
    )

    mel = mel.unsqueeze(0)
    mel = mel.unsqueeze(0)

    return mel

# =========================================================
# SPOOF DETECTION
# =========================================================

def detect_spoof(audio_path):

    wav = load_audio(audio_path)

    feat = extract_feature(wav)

    feat = feat.to(DEVICE)

    with torch.no_grad():

        out = model(feat)

        # auto compatible
        if out.dim() > 1:
            out = out.squeeze(1)

        # IMPORTANT:
        # sigmoid = REAL probability
        real_prob = torch.sigmoid(out).item()

        spoof_prob = 1 - real_prob

    return spoof_prob, real_prob

# =========================================================
# WHISPER
# =========================================================

def transcribe_audio(audio_path):

    segments, _ = whisper_model.transcribe(audio_path)

    text = ""

    for seg in segments:
        text += seg.text + " "

    return text.strip()

# =========================================================
# GEMMA4 ANALYSIS
# =========================================================

def analyze_text(text, spoof_prob):

    if len(text.strip()) == 0:
        return "No speech detected."

    # VERY SHORT PROMPT
    prompt = f"""
Transcript:
{text}

Spoof probability:
{spoof_prob:.4f}

Briefly explain:
- AI or human
- scam risk
- recommendation
"""

    inputs = tokenizer(
        prompt,
        return_tensors="pt"
    )

    with torch.no_grad():

        outputs = gemma_model.generate(
            **inputs,
            max_new_tokens=40,
            do_sample=False
        )

    decoded = tokenizer.decode(
        outputs[0],
        skip_special_tokens=True
    )

    return decoded[len(prompt):].strip()

# =========================================================
# MAIN PIPELINE
# =========================================================

_last_request = 0

def full_pipeline(audio):

    global _last_request

    # =====================================================
    # FILE SIZE LIMIT
    # =====================================================

    if audio is not None:

        if os.path.getsize(audio) > 10 * 1024 * 1024:

            return (
                "❌ Audio too large",
                "",
                "",
                "FAILED"
            )

    # =====================================================
    # CLICK LIMIT
    # =====================================================

    now = time.time()

    if now - _last_request < 1:

        return (
            "⚠️ Please wait...",
            "",
            "",
            ""
        )

    _last_request = now

    # =====================================================
    # EMPTY AUDIO
    # =====================================================

    if audio is None:

        return (
            "❌ No audio detected",
            "",
            "",
            ""
        )

    try:

        print("\n" + "=" * 40)
        print("NEW ANALYSIS")
        print("=" * 40)

        # =================================================
        # NORMALIZE AUDIO
        # =================================================

        audio = normalize_audio(audio)

        # =================================================
        # START TIMER
        # =================================================

        start = time.time()

        # =================================================
        # SPOOF DETECTION
        # =================================================

        spoof_prob, real_prob = detect_spoof(audio)

        # =================================================
        # RISK LEVEL
        # =================================================

        if spoof_prob > 0.80:

            pred = "FAKE / AI VOICE"
            emoji = "🚨"
            risk = "HIGH RISK"

        elif spoof_prob > 0.50:

            pred = "SUSPICIOUS"
            emoji = "⚠️"
            risk = "MEDIUM RISK"

        else:

            pred = "REAL HUMAN"
            emoji = "✅"
            risk = "LOW RISK"

        # =================================================
        # TRANSCRIBE
        # =================================================

        transcript = transcribe_audio(audio)

        # =================================================
        # GEMMA4
        # =================================================

        analysis = analyze_text(
            transcript,
            spoof_prob
        )

        # =================================================
        # PERFORMANCE
        # =================================================

        end = time.time()

        total_time = end - start

        # =================================================
        # RESULT TEXT
        # =================================================

        spoof_text = f"""
# {emoji} {pred}

### Risk Level
{risk}

### REAL Probability
{real_prob:.4f}

### SPOOF Probability
{spoof_prob:.4f}

### Runtime
{total_time:.2f} seconds
"""

        # =================================================
        # SAVE CSV
        # =================================================

        result = pd.DataFrame([
            {
                "spoof_probability": spoof_prob,
                "real_probability": real_prob,
                "prediction": pred,
                "risk": risk,
                "transcript": transcript,
                "gemma_analysis": analysis
            }
        ])

        result.to_csv(
            "result.csv",
            index=False,
            encoding="utf-8-sig"
        )

        return (
            spoof_text,
            transcript,
            analysis,
            "✅ Saved to result.csv"
        )

    except Exception as e:

        return (
            f"❌ ERROR:\n{str(e)}",
            "",
            "",
            "FAILED"
        )

# =========================================================
# UI
# =========================================================

demo = gr.Interface(
    fn=full_pipeline,

    inputs=gr.Audio(
        sources=["microphone", "upload"],
        type="filepath",
        label="Speak or Upload Audio"
    ),

    outputs=[

        gr.Markdown(
            label="Spoof Detection"
        ),

        gr.Textbox(
            label="Transcript",
            lines=5
        ),

        gr.Textbox(
            label="Gemma4 Analysis",
            lines=10
        ),

        gr.Textbox(
            label="Status"
        )
    ],

    title="Industrial AI Voice Scam Detection System",

    description="""
CNN Spoof Detection + Whisper + Gemma4

Features:
- AI voice detection
- Scam risk analysis
- Speech transcription
- Real-time assessment
- Upload or microphone input
"""
)

# =========================================================
# LAUNCH
# =========================================================

demo.queue().launch(
    share=True
)
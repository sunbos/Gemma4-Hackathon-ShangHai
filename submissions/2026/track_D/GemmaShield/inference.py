import os
import torch
import torchaudio
import soundfile as sf
import pandas as pd

from transformers import pipeline
from faster_whisper import WhisperModel

from model import CNN2D

# =========================================================
# CONFIG
# =========================================================

DEVICE = "cpu"

MODEL_PATH = r"D:\ASVspoof2021\2021-main\2021-main\LA\Baseline-RawNet2\best_model.pth"

TEST_AUDIO = r"D:\data\data\train-renamepart_006\train-rename\kaggle-audio-train-000018.wav"

TARGET_SR = 16000
TARGET_LEN = 64000

# =========================================================
# START
# =========================================================

print("=" * 60)
print("INDUSTRIAL SPOOF PIPELINE")
print("=" * 60)

# =========================================================
# LOAD MODEL
# =========================================================

model = CNN2D()

checkpoint = torch.load(
    MODEL_PATH,
    map_location=DEVICE
)

model.load_state_dict(checkpoint)

model.to(DEVICE)
model.eval()

print("CNN loaded")

# =========================================================
# LOAD WHISPER
# =========================================================

print("Loading Whisper...")

whisper_model = WhisperModel(
    "base",
    device="cpu",
    compute_type="int8"
)

print("Whisper ready")

# =========================================================
# LOAD GEMMA
# =========================================================

print("Loading Gemma...")

gemma_pipe = pipeline(
    "text-generation",
    model="google/gemma-2b-it",
    device=-1
)

print("Gemma ready")

# =========================================================
# MEL
# =========================================================

mel_transform = torchaudio.transforms.MelSpectrogram(
    sample_rate=16000,
    n_fft=1024,
    hop_length=512,
    n_mels=64
)

# =========================================================
# AUDIO LOADER
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
# FEATURE
# =========================================================

def extract_feature(wav):

    mel = mel_transform(wav)

    mel = torch.log(mel + 1e-6)

    # feature normalize
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

        # IMPORTANT
        # sigmoid = REAL probability
        real_prob = torch.sigmoid(out).item()

        spoof_prob = 1 - real_prob

    return spoof_prob, real_prob

# =========================================================
# WHISPER
# =========================================================

def transcribe_audio(audio_path):

    segments, info = whisper_model.transcribe(audio_path)

    text = ""

    for seg in segments:
        text += seg.text + " "

    return text.strip()

# =========================================================
# GEMMA
# =========================================================

def analyze_text(text, spoof_prob):

    if spoof_prob > 0.5:
        risk = "HIGH RISK"
        assessment = "Likely AI-generated"
    else:
        risk = "LOW RISK"
        assessment = "Likely real human voice"

    prompt = f"""
You are an AI telecom fraud analyst.

Transcript:
{text}

Spoof probability:
{spoof_prob:.4f}

Assessment:
{assessment}

Risk:
{risk}

Tasks:
1. Analyze whether this may be AI-generated.
2. Explain suspicious patterns.
3. Explain scam risks.
4. Provide final recommendation.
"""

    output = gemma_pipe(
        prompt,
        max_new_tokens=150,
        do_sample=False,
        return_full_text=False
    )

    return output[0]["generated_text"]

# =========================================================
# MAIN
# =========================================================

if __name__ == "__main__":

    print("\nSTART ANALYSIS\n")

    # =====================================================
    # SPOOF
    # =====================================================

    spoof_prob, real_prob = detect_spoof(TEST_AUDIO)

    print(f"REAL Probability : {real_prob:.4f}")
    print(f"SPOOF Probability: {spoof_prob:.4f}")

    if spoof_prob > 0.5:
        prediction = "FAKE / AI VOICE"
    else:
        prediction = "REAL HUMAN"

    print("Prediction:", prediction)

    # =====================================================
    # WHISPER
    # =====================================================

    print("\nTRANSCRIBING...\n")

    transcript = transcribe_audio(TEST_AUDIO)

    print("TRANSCRIPT:")
    print(transcript)

    # =====================================================
    # GEMMA
    # =====================================================

    print("\nGEMMA ANALYSIS...\n")

    analysis = analyze_text(
        transcript,
        spoof_prob
    )

    print(analysis)

    # =====================================================
    # SAVE
    # =====================================================

    result = pd.DataFrame([
        {
            "audio": TEST_AUDIO,
            "real_probability": real_prob,
            "spoof_probability": spoof_prob,
            "prediction": prediction,
            "transcript": transcript,
            "gemma_analysis": analysis
        }
    ])

    result.to_csv(
        "final_result.csv",
        index=False,
        encoding="utf-8-sig"
    )

    print("\nDONE")
    print("Saved: final_result.csv")
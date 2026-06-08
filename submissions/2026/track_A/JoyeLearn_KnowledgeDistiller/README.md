# 🧠 组织经验淬炼师 | Knowledge Distiller Agent

**GDG Shanghai Gemma 4 Hackathon 2026 | Track A: AI Agent**
**Team: Joyelearn**

> "把专家的经验变成组织的资产 — Turn what's in people's heads into what's in the company's hands."

---

## Problem

When senior employees leave, their tacit knowledge walks out the door with them. Companies lose an estimated ¥230,000 per expert departure (Deloitte Research). Traditional documentation is slow, incomplete, and fails to capture the *why* behind decisions.

## Solution

An AI Agent powered by **Gemma 4 (26B MoE)** that acts as a Chief Knowledge Distillation Guide:

1. Conducts structured BEI interviews — guides experts to share specific past events
2. Distills tacit knowledge — surfaces hidden decision logic and underlying principles  
3. Outputs structured Skill Cards and SOPs via native function calling
4. Scales organizational learning across the whole team

---

## Gemma 4 Features Used

| Feature | How We Use It |
|---------|--------------|
| **Thinking Mode** | Deep reasoning for identifying knowledge gaps during interviews |
| **Native Function Calling** | `save_skill_card`, `search_skills`, `generate_sop` |
| **256K Context Window** | Full interview transcripts processed without chunking |
| **26B MoE Architecture** | High capability at low inference cost for real-time conversation |

---

## Model Selection Rationale

**Primary: `gemma-4-26b-a4b-it` (MoE)**
- 25.2B total parameters → top-tier reasoning for interview guidance
- Only 3.8B parameters activated per inference → fast response for real-time conversation
- 256K context = entire interview session in one window, causal chains preserved

**Secondary: `gemma-4-31b-it` (Dense)**
- Used for final SOP generation where logical precision is critical

---

## Quick Start

### Option A: Google Colab (Recommended)

1. Open `demo.ipynb` in Google Colab
2. Replace `YOUR_API_KEY_HERE` with your Gemini API key from [aistudio.google.com](https://aistudio.google.com)
3. Run all cells in order

### Option B: Local

```bash
pip install google-genai

# Set API key
export GEMINI_API_KEY="your_key_here"      # macOS/Linux
$env:GEMINI_API_KEY="your_key_here"        # Windows PowerShell

python agent.py
```

---

## Architecture

```
User Input
    │
    ▼
Gemma 4 Agent (26B MoE)
├── System Prompt: BEI Interview Framework
├── Thinking Mode: thought blocks filtered from history (IRON RULE)
├── Native Function Calling: save_skill_card / search_skills / generate_sop
└── 256K Context: full session history maintained
    │
    ├── Text Response → Interview guidance (next BEI question)
    └── Function Call → Structured Skill Card saved to library
```

---

## Sampling Parameters (Official Gemma 4 Spec)

```python
temperature = 1.0
top_p       = 0.95
top_k       = 64
```

---

## Data & Privacy Compliance

- No data stored persistently — in-memory only during session
- Model: official Gemma 4 pretrained weights via Google AI Studio API
- No proprietary training data used
- Interview data never sent to third parties

---

## Team

**Joyelearn** — AI tools for organizational learning and knowledge management.
GitHub: [github.com/joyelearn](https://github.com/joyelearn)

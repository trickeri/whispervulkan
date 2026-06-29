# parakeet — Parakeet TDT 0.6B as an STT backend for local English voice commands

**Repo:** `trickeri/whispermodel` (`whispervulkan`) → `~/programming/whispervulkan`
**Status:** PLAN / not started. Drafted from a comparison session; needs a build + A/B test on the 4090 box.
**Goal:** Evaluate and (likely) add **NVIDIA Parakeet TDT 0.6B v3** as an alternative STT backend to
whisper-large-v3-turbo, specifically for **local, English-only, single-speaker voice commands /
dictation** where there is **sometimes background music**. Keep the existing daemon HTTP API contract
so `voicechat` and other clients don't change — just swap (or route to) the engine behind it.

---

## 1. Why this exists (the problem with turbo for *commands*)

The current daemon runs whisper-large-v3-turbo (see [`whispervulkan-daemon-plan.md`](./whispervulkan-daemon-plan.md)).
Turbo is great for general transcription, but for an **always-listening voice-command** use case it has one
failure mode that actually matters here:

- **Whisper hallucinates on non-speech.** Its decoder always wants to emit text, so during
  silence or **background-music-only** stretches it can invent words — i.e. fire phantom commands.
  For a command system that is the worst possible failure.
- Latency on short push-to-talk clips is higher than it needs to be.

Parakeet is a **transducer (TDT)**: silence in → silence out. It emits *nothing* during music/silence
rather than hallucinating, it's much faster on short utterances, and it's *more* accurate on clean
English. It was also trained on 36k+ hours of noisy/non-speech audio, so speaking over music holds up.

**Net:** for "my own English voice commands, sometimes music in the background," Parakeet is the better
fit on all three axes that matter — latency, no hallucinated commands, English WER — at roughly the
**same VRAM** as int8 turbo.

## 2. What this is NOT

- **Not ripping out Whisper.** Turbo stays the default/general backend (multilingual, robust on unknown
  audio, the `voicechat` dictation path). Parakeet is added for the command path, or as a selectable
  engine. Decide after the A/B (§7).
- **Not a fork of NeMo.** We do not pull the full NeMo runtime (that's where the ~5 GB VRAM comes from).
  Run the **int8 ONNX** export via **sherpa-onnx** / onnxruntime — keeps the footprint at ~1–2 GB.
- **Not network-exposed.** Same as the whisper daemon: bind `127.0.0.1` only.

## 3. The model

- **`nvidia/parakeet-tdt-0.6b-v3`** — FastConformer encoder + Token-and-Duration Transducer decoder.
  English (+24 other European langs we won't use). ~6.3% avg WER on Open ASR Leaderboard,
  ~1.9% LibriSpeech-clean (beats turbo's ~3.0%), RTFx in the thousands.
- **Use the int8 ONNX build**, not the NeMo checkpoint:
  - `nasedkinpv/parakeet-tdt-0.6b-v3-onnx-int8` (prebuilt int8 ONNX), or
  - `grikdotnet/parakeet-tdt-0.6b-fp16` if we'd rather spend a little more VRAM for max single-stream speed.
- **Footprint:** int8 weights ≈ 670 MB (encoder 652 MB + decoder 18 MB); runtime VRAM ~1–2 GB —
  same neighborhood as the int8 turbo currently in use, not the 16 GB figure floating around (that was
  Mac unified-memory guidance for a full app, not a real floor).
- Note: int8 is tuned for packing concurrent workers, not max single-stream throughput. Still far
  faster than turbo for our use; revisit fp16 only if single-stream latency disappoints.

## 4. Runtime / backend on the 4090 box

The whisper daemon uses **Vulkan** (whisper.cpp). Parakeet ONNX does **not** use that path:

- **Preferred:** `sherpa-onnx` (k2-fsa) with `onnxruntime-gpu` (CUDA — the box is an RTX 4090, CUDA is
  available even though whisper uses Vulkan). Falls back to CPU int8, which is still fast for commands.
- sherpa-onnx ships NeMo transducer support + offline/streaming recognizers and an end-of-utterance
  story that fits push-to-talk.
- Keep it **sudo-free** like the rest of this repo (per the Vulkan/SPIRV-Headers convention in the
  whisper plan): install onnxruntime + sherpa-onnx into a venv / `~/.local`, no pacman in build.sh.
- Consider `parakeet-eou` (end-of-utterance) variant for cleaner command segmentation if sherpa's VAD
  isn't enough.

## 5. Keep the same HTTP API contract

Clients (`voicechat`, etc.) already speak the whisper-server shape: `POST /inference`, multipart
`file=@audio.wav` (16 kHz mono), `response_format=text|json|...`, optional `language`. The Parakeet
backend must expose the **same** contract so nothing downstream changes:

- A small FastAPI (or equivalent) wrapper around sherpa-onnx that mirrors `POST /inference`.
  (There are existing references, e.g. `parakeet-tdt-0.6b-v3-fastapi-openai` wrappers, that already do
  an OpenAI/whisper-style HTTP shape — crib from one, don't depend on it.)
- Bind `127.0.0.1:<port>`. Pick a port distinct from the whisper daemon's `48450` if both run at once
  (e.g. `48451`), or make engine selection a config switch on the existing port.

**Decision to make:** one daemon with a `WV_ENGINE=whisper|parakeet` switch on `48450`, **or** two
daemons side-by-side on `48450`/`48451` with the client choosing. Lean toward the **engine switch**
(single endpoint, less client churn); two-port only if we want both warm simultaneously.

## 6. Proposed layout (mirrors the whisper daemon)

```
~/programming/whispermodel/
├── AIPlans/
│   ├── whispervulkan-daemon-plan.md
│   └── parakeet-voicecommand-plan.md        # this file
├── parakeet/                                 # new
│   ├── fetch-parakeet.sh                     # pull int8 ONNX from HF into models/ (gitignored)
│   ├── parakeet-server.py                    # FastAPI wrapper, /inference contract = whisper-server
│   ├── parakeet.service                      # systemd --user unit, model warm in VRAM/RAM
│   ├── requirements.txt                      # sherpa-onnx, onnxruntime-gpu, fastapi, uvicorn
│   └── config.env.example                    # PK_MODEL, PK_HOST, PK_PORT, PK_DEVICE=cuda|cpu, PK_LANG=en
└── (existing whisper files unchanged)
```

`models/` stays gitignored (already is). Sudo-free install; service keeps the model warm so command
latency is instant.

## 7. A/B test plan (the actual decision gate)

Before committing Parakeet as the command backend, measure on **this** box with **my** voice:

1. Record a small fixed set of real command clips: clean, over music (low + loud), and pure-music /
   silence segments (the hallucination trap).
2. Run both backends on the set, capture: WER on the spoken clips, **false-emission rate on the
   music/silence clips** (the key metric — turbo should hallucinate here, Parakeet should stay empty),
   and end-to-end latency on short clips.
3. Decide: Parakeet as default command engine (expected), turbo retained for general/multilingual.

## 8. Steps

1. [ ] `parakeet/fetch-parakeet.sh` → download int8 ONNX (`nasedkinpv/...-onnx-int8`) into `models/`.
2. [ ] venv + `requirements.txt` (sherpa-onnx, onnxruntime-gpu, fastapi, uvicorn), sudo-free.
3. [ ] `parakeet-server.py` exposing the whisper-server `/inference` contract over sherpa-onnx.
4. [ ] Smoke test: `curl -F file=@clip.wav -F response_format=text http://127.0.0.1:48451/inference`.
5. [ ] `parakeet.service` (systemd --user), model warm.
6. [ ] Run the §7 A/B; record numbers in this file.
7. [ ] Decide engine-switch vs two-port; wire `voicechat` accordingly.
8. [ ] Update README with a Parakeet/engine-selection section.

## 9. Open questions (resolve on linux)

- onnxruntime-gpu CUDA vs CPU int8 — is CUDA latency worth the dependency, or is CPU int8 already
  instant enough for commands? (Test both in §7.)
- Single endpoint w/ engine switch vs two warm daemons — depends on whether we ever want both at once.
- Is sherpa-onnx VAD enough for command segmentation, or do we want the `parakeet-eou` variant?
- fp16 vs int8 — only revisit fp16 if int8 single-stream latency disappoints.

---

### TL;DR
Add int8 Parakeet TDT 0.6B v3 (via sherpa-onnx) behind the existing `/inference` API as the
voice-command engine. It doesn't hallucinate commands during background music (turbo does), it's
lower-latency on short clips, and it's more accurate on clean English — all at ~1–2 GB VRAM, the same
as int8 turbo. Keep turbo for general/multilingual. Gate the swap on the §7 A/B test.

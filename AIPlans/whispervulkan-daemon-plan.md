# whispervulkan — system-wide Whisper STT daemon

**Repo:** `trickeri/whispervulkan` → `~/programming/whispervulkan`
**Status:** BUILT — running as a `systemd --user` service on `127.0.0.1:48450` (large-v3-turbo, Vulkan).
**Goal:** One Whisper **large-v3-turbo** model loaded **once** into VRAM, inferenced via **Vulkan**,
running as a long-lived background process that **any** program on this machine can ask for
speech-to-text over **local HTTP**. Replaces the per-app `whisper-cli` rebuild/embed dance
(Trik_Klip, future apps) with a single shared backend.

---

## 1. Why this exists (the problem)

- We have rebuilt the whisper.cpp Vulkan backend per project (Trik_Klip ships its own `whisper-cli`
  + a 142 MB `ggml-base.bin` in `resources/`). Every Tauri app re-embeds whisper. See
  memory `trik-klip-linux-dev`.
- "open whisper" (the dictation app being replaced) eats ~1 GB RAM, throws popups, and can't be
  placed where we want on the desktop.
- We want: **load the model once**, keep it warm in the RTX 4090's VRAM, and let every client
  (Trik_Klip, the new `voicechat` client, ricescripts, twitch bot, anything) hit a tiny HTTP API.
  No per-app model copy, no per-app rebuild, minimal idle RAM.

## 2. What it is NOT

- Not a rewrite of whisper inference. We **reuse upstream `ggml-org/whisper.cpp`** (already cloned
  and building with Vulkan at `~/programming/whisper.cpp`). whisper.cpp already ships
  `examples/server/server.cpp` (`whisper-server`, HTTP, `httplib.h`) and `examples/stream`.
- Not a GUI. It's a headless daemon. UI lives in `voicechat` (see that plan).
- Not network-exposed. Binds `127.0.0.1` only.

## 3. Architecture decision

**Thin wrapper over upstream `whisper-server`, not a fork.**

whisper.cpp's `examples/server/server.cpp` already does almost exactly what we want:
loads a model once, keeps the `whisper_context` warm, exposes `POST /inference` (multipart audio
→ JSON/text/SRT/VTT) and `POST /load` (swap model). We do **not** fork whisper.cpp. Instead:

```
~/programming/whispervulkan/
├── AIPlans/
├── README.md
├── build.sh                # builds whisper.cpp's whisper-server with Vulkan into ./bin
├── whispervulkan.sh        # launcher: resolves model path, picks port, exec's whisper-server
├── whispervulkan.service   # systemd --user unit (loads model into VRAM at login / on demand)
├── config.toml             # port, model path, language, threads, VAD on/off
├── models/                 # ggml-large-v3-turbo*.bin (gitignored, downloaded by fetch-model.sh)
├── fetch-model.sh          # downloads the turbo model from HF
├── client/                 # tiny reference clients other apps copy
│   ├── whispervulkan.py    # one function: transcribe(wav_bytes) -> text
│   ├── whispervulkan.sh    # curl one-liner wrapper
│   └── whispervulkan.rs    # reqwest snippet for Tauri apps (Trik_Klip drop-in)
└── .gitignore              # models/, bin/, whisper.cpp checkout
```

`build.sh` either (a) builds against the sibling `~/programming/whisper.cpp` checkout, or
(b) clones a pinned tag into `./whisper.cpp` (gitignored) and builds there for reproducibility.
**Decision: pin a tag in `./whisper.cpp`** so the daemon's behavior doesn't drift when we hack on
the Trik_Klip checkout. One source of truth for the binary; clients only see the HTTP API.

> If upstream `whisper-server` ever proves too limiting (e.g. we want a custom `/transcribe` shape,
> streaming partials, or a request queue), the fallback is a **~200-line C++ `main` of our own**
> linking `libwhisper`, copied from `server.cpp`. Keep that in mind but don't start there.

## 4. The model

- **whisper-large-v3-turbo** (809M params, 4 decoder layers — the fast variant).
- File: `ggml-large-v3-turbo.bin` from HF `ggerganov/whisper.cpp`.
  - f16 ≈ **1.62 GB** (best quality, fits the 4090 trivially) — **default**.
  - `-q8_0` ≈ 834 MB, `-q5_0` ≈ 547 MB if we ever want it smaller. Config-selectable.
- VRAM resident: ~1.5–2 GB warm. Idle **system RAM** for the daemon process itself is tiny
  (model lives in VRAM); this is the whole point vs. the 1 GB-RAM "open whisper".
- `fetch-model.sh` downloads to `models/`, verifies size/sha, idempotent.

## 5. Build (grounded in what already works here)

Reuse the **exact** Vulkan recipe proven in memory `trik-klip-linux-dev` (the SPIRV-Headers
workaround is mandatory on this Arch box — `vulkan-headers`/`spirv-tools`/`glslang`/`shaderc` are
present but `SPIRV-Headers` is not; installed sudo-free in `~/.local`):

```bash
export CPLUS_INCLUDE_PATH="$HOME/.local/include:$CPLUS_INCLUDE_PATH"
cmake -B build -DGGML_VULKAN=1 -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_TESTS=OFF \
      -DSPIRV-Headers_DIR="$HOME/.local/share/cmake/SPIRV-Headers"
cmake --build build -j --target whisper-server     # NOTE: target is whisper-server, not whisper-cli
```

- `whisper-server` is dynamically linked (rpath) to `libwhisper`/`libggml*.so` in the build dir —
  **do not relocate the binary alone**. `build.sh` symlinks/keeps the build tree intact and points
  the launcher at the build location (same gotcha Trik_Klip hit).
- Sudo-free throughout (per memory `avoid-per-iteration-sudo`). No pacman installs in build.sh;
  if SPIRV-Headers is missing, build.sh prints the one-time `~/.local` install command and exits.

## 6. The HTTP API (what clients see)

Bind `127.0.0.1:<port>` (config default e.g. **48450**; pick an unused high port — Trik_Klip uses
31416, its frontend 5175, so avoid clashes). Endpoints (whisper-server native + our conventions):

| Method | Path          | Body                              | Returns |
|--------|---------------|-----------------------------------|---------|
| POST   | `/inference`  | multipart `file=@audio.wav`, opt `response_format=json\|text\|srt\|vtt`, `language` | transcript |
| POST   | `/load`       | `{model: "<path>"}`               | swaps the warm model |
| GET    | `/health`     | —                                 | 200 + `{model, vram, uptime}` (our tiny addition; if using stock server, clients just probe `/inference` readiness) |

Clients send 16 kHz mono WAV (whisper's native rate). Reference clients in `client/` do the
ffmpeg resample + POST. Example contract the `voicechat` plan and Trik_Klip both rely on:

```bash
curl -s -F file=@clip.wav -F response_format=text http://127.0.0.1:48450/inference
```

**Decision: clients are responsible for capture + resample to 16 kHz mono WAV.** Keeps the daemon
a pure transcription service; capture/VAD/hotkeys live in clients (`voicechat`). Daemon may enable
whisper.cpp's built-in VAD (`--vad`, silero) as a config flag to trim long silences.

## 7. Lifecycle — `systemd --user`

- `whispervulkan.service` (user unit, `~/.config/systemd/user/`): `ExecStart=whispervulkan.sh`,
  `Restart=on-failure`. Enable with `systemctl --user enable --now whispervulkan`.
- **Two warm-strategy options (config):**
  1. **Always warm** — model resident from login. Instant first transcription. ~1.5 GB VRAM always
     held (fine on a 24 GB 4090). *Recommended for a dictation/voice box used all day.*
  2. **Socket/idle-activated** — `systemd` socket-activation or an idle timeout that unloads the
     model after N minutes, reloads on next request (cold ~few sec). Saves VRAM when gaming, etc.
- Expose `~/.local/bin/whispervulkan` shim (PATH per memory `local-bin-graphical-path`) so it can be
  started from KRunner / scripts.

## 8. Migrating Trik_Klip onto the daemon (proves the value)

Trik_Klip currently sets `WHISPER_CLI_PATH` + `WHISPER_MODEL_PATH` and shells out to `whisper-cli`
per clip (memory `trik-klip-linux-dev`, `config.rs` `WHISPER_CLI_BIN`). After this daemon exists:

- Add a `WHISPER_HTTP_URL=http://127.0.0.1:48450/inference` env path in Trik_Klip's pipeline; when
  set, POST the clip wav instead of spawning `whisper-cli`. Keep the spawn path as fallback.
- Trik_Klip can then **drop** its embedded `whisper-cli` + the 142 MB `ggml-base.bin` resource
  (it can stay for offline/Windows; **preserve the Windows path** per memory
  `preserve-windows-builds` — gate the HTTP path behind the env var / `cfg!(unix)`).
- Net: one model in VRAM serves Trik_Klip clip transcription AND voicechat dictation simultaneously.

## 9. Build order / milestones

1. **Scaffold repo** — folders above, `.gitignore`, `README.md`, `git init`, create `trickeri/whispervulkan`.
2. **`fetch-model.sh`** — pull `ggml-large-v3-turbo.bin` to `models/`.
3. **`build.sh`** — pinned whisper.cpp clone + Vulkan build of `whisper-server` (reuse §5 recipe).
4. **`whispervulkan.sh` + `config.toml`** — launch server, model + port + lang from config.
5. **Smoke test** — `curl` a sample wav (`whisper.cpp/samples/`) → transcript. Confirm Vulkan in use
   (`GGML_VULKAN=1` log line / `radeontop`/`nvtop` shows VRAM use, GPU active).
6. **`whispervulkan.service`** — user unit, both warm strategies, `~/.local/bin` shim.
7. **`client/` reference snippets** (py, sh, rs).
8. **Migrate Trik_Klip** to the HTTP path behind an env flag (§8). Validate a real clip.
9. **`/health` + idle-unload** polish (optional).

## 10. Open questions / decide during build

- Final port number (avoid 31416/5175). → propose **48450**.
- Always-warm vs idle-unload default. → propose **always-warm**, idle-unload opt-in.
- f16 vs q8_0 default. → propose **f16** (4090 has headroom; best accuracy).
- Pinned whisper.cpp tag — pick the latest release at scaffold time, record it in `build.sh`.

## Related memory
`trik-klip-linux-dev` (Vulkan build recipe + SPIRV-Headers), `preserve-windows-builds`,
`avoid-per-iteration-sudo`, `local-bin-graphical-path`. Sibling plan: `voicechat`.

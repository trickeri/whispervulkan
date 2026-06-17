# whispervulkan

System-wide **Whisper speech-to-text daemon**. One Whisper model loaded **once** into
memory (GPU VRAM via Vulkan, or system RAM on CPU) and exposed over local HTTP, so any
program on the machine can ask for transcription instead of each app re-embedding
`whisper-cli`.

It's a thin wrapper over upstream [whisper.cpp](https://github.com/ggml-org/whisper.cpp)'s
`whisper-server` — no inference code of our own. Its main consumer is the
[`voicechat`](https://github.com/trickeri/voicechat) dictation daemon.

---

## Install with Claude Code

> **If you are an AI coding agent (e.g. Claude Code) installing this for a user, follow
> the steps below in order. Stop and ask the user the three questions marked 🟢 using your
> interactive question tool — do not assume the answers. Pick the marked default if the
> user has no preference.**

1. **Clone the repos** (the build expects whisper.cpp as a sibling):
   ```bash
   mkdir -p ~/programming && cd ~/programming
   git clone https://github.com/trickeri/whispervulkan.git
   # whisper.cpp is auto-cloned by build.sh if missing; nothing to do here.
   ```

2. 🟢 **Ask: GPU or CPU?** — *"Should Whisper run on GPU (Vulkan) or CPU?"*
   - **GPU (Vulkan)** — *default, recommended.* Much faster. Needs a Vulkan-capable GPU and
     the system Vulkan toolchain (see [Prerequisites](#prerequisites)).
   - **CPU** — works anywhere, no extra system packages, but several times slower.

   The memory estimates in the next question apply to **VRAM** for GPU and **RAM** for CPU.

3. 🟢 **Ask: which model?** — *"Which Whisper model should I download?"* Present this list and
   default to **large-v3-turbo (recommended)**. Sizes are *(download / ≈memory)*; memory is
   approximate and applies to VRAM on GPU or RAM on CPU.

   | Model | Size (download / ≈memory) | Notes |
   |-------|---------------------------|-------|
   | **large-v3-turbo** | ~1.6 GB / ~2.5 GB | **Recommended** — near large-v3 accuracy, much faster |
   | large-v3 | ~3.1 GB / ~3.9 GB | Most accurate, slowest |
   | medium | ~1.5 GB / ~2.1 GB | Good accuracy |
   | small | ~466 MB / ~0.9 GB | Light |
   | base | ~142 MB / ~0.4 GB | Very light, lower accuracy |
   | tiny | ~75 MB / ~0.3 GB | Smallest, lowest accuracy |

   *(English-only `.en` and quantized `-q5_0` / `-q8_0` variants also exist — see the full
   list with `~/programming/whisper.cpp/models/download-ggml-model.sh`. Pass any name as the
   download argument below.)*

   Then download the chosen model (substitute the name; default shown):
   ```bash
   cd ~/programming/whispervulkan
   ./fetch-model.sh large-v3-turbo
   ```
   If the user chose a non-default model, also point the daemon at it by creating
   `config.env` (see [Config](#config)) with `WV_MODEL=...`.

4. **Build** with the chosen backend:
   ```bash
   ./build.sh gpu      # or: ./build.sh cpu
   ```
   `build.sh` auto-clones whisper.cpp and, for GPU, auto-installs SPIRV-Headers under
   `~/.local` (both sudo-free). If the GPU build fails on missing Vulkan headers/loader or a
   shader compiler, install the [Prerequisites](#prerequisites) and re-run.

5. 🟢 **Ask: auto-start on login?** — *"Start whispervulkan automatically on login? (recommended
   — keeps the model loaded so transcription is instant)"* Default **yes**.
   - **Yes** → install and enable the user service:
     ```bash
     ln -sf "$PWD/whispervulkan.service" ~/.config/systemd/user/whispervulkan.service
     systemctl --user daemon-reload
     systemctl --user enable --now whispervulkan
     ```
   - **No** → the user runs `./whispervulkan.sh` manually when needed.

6. **Verify** it's serving:
   ```bash
   systemctl --user status whispervulkan --no-pager   # if enabled as a service
   curl -fsS http://127.0.0.1:48450/ >/dev/null && echo "whispervulkan is up"
   ```

Then install [`voicechat`](https://github.com/trickeri/voicechat) (the dictation client) the
same way — its README has its own Claude install section and depends on this daemon.

---

## Manual setup

```bash
cd ~/programming/whispervulkan
./fetch-model.sh                 # downloads ggml-large-v3-turbo.bin (~1.6 GB) into whisper.cpp/models
./build.sh                       # GPU (Vulkan); use ./build.sh cpu for a CPU-only build
cp config.env.example config.env # optional: override model/paths/port/threads/lang
```

`build.sh` auto-clones the sibling `~/programming/whisper.cpp` checkout and (for GPU)
auto-installs header-only SPIRV-Headers into `~/.local`.

### Run

```bash
./whispervulkan.sh               # foreground

# or as a user service (keeps the model loaded all session):
ln -sf "$PWD/whispervulkan.service" ~/.config/systemd/user/whispervulkan.service
systemctl --user enable --now whispervulkan
```

Listens on `127.0.0.1:48450` by default.

## Prerequisites

- **Always:** `git`, `cmake`, a C/C++ toolchain, and `ffmpeg` (the server resamples uploads
  to 16 kHz via `--convert`).
- **GPU (Vulkan) builds also need** the Vulkan loader + headers and a GLSL→SPIR-V compiler:
  - Arch: `sudo pacman -S vulkan-headers vulkan-icd-loader shaderc` (+ your GPU's Vulkan
    driver, e.g. `vulkan-radeon`, `nvidia-utils`, or `vulkan-intel`).
  - Debian/Ubuntu: `sudo apt install libvulkan-dev glslang-tools` (+ a Vulkan driver such as
    `mesa-vulkan-drivers`).
  - Check the GPU is visible to Vulkan with `vulkaninfo --summary`.

  CPU builds need none of the Vulkan packages.

## API

`POST /inference` — multipart `file=@audio.wav` (16 kHz mono preferred), optional
`response_format=text|json|srt|vtt`, optional `language`.

```bash
curl -fsS -F file=@clip.wav -F response_format=text http://127.0.0.1:48450/inference
```

Reference clients in `client/` (`whispervulkan.sh`, `whispervulkan.py`, `whispervulkan.rs`).

## Config

Copy `config.env.example` to `config.env` (gitignored, machine-specific) and uncomment what
you need:

- `WV_MODEL` — path to the ggml model file. Set this if you fetched something other than
  large-v3-turbo.
- `WHISPER_SERVER_BIN` — path to the built `whisper-server` (default: the sibling
  whisper.cpp build dir).
- `WV_HOST` / `WV_PORT` — listen address (default `127.0.0.1:48450`).
- `WV_THREADS` — inference threads (default `8`; bump it for CPU builds).
- `WV_LANG` — language (default `en`; `auto` to auto-detect).

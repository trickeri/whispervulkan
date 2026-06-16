# whispervulkan

System-wide **Whisper speech-to-text daemon**. One `whisper-large-v3-turbo` model loaded **once**
into VRAM, inferenced via **Vulkan**, exposed over local HTTP so any program on the machine can ask
for transcription instead of each app re-embedding `whisper-cli`.

A thin wrapper over upstream [whisper.cpp](https://github.com/ggml-org/whisper.cpp)'s `whisper-server`
— no inference code of our own. See `AIPlans/whispervulkan-daemon-plan.md` for the full design.

## Setup

```bash
./fetch-model.sh                 # downloads ggml-large-v3-turbo.bin (~1.6 GB) into whisper.cpp/models
./build.sh                       # builds whisper-server with the Vulkan backend (sibling whisper.cpp)
cp config.env.example config.env # optional: override paths/port/threads/lang
```

Requires the sibling `~/programming/whisper.cpp` checkout and (on Arch) SPIRV-Headers in `~/.local`
— `build.sh` prints the one-time install command if it's missing.

## Run

```bash
./whispervulkan.sh               # foreground

# or as a user service (keeps the model warm in VRAM all session):
ln -sf "$PWD/whispervulkan.service" ~/.config/systemd/user/whispervulkan.service
systemctl --user enable --now whispervulkan
```

Listens on `127.0.0.1:48450` by default.

## API

`POST /inference` — multipart `file=@audio.wav` (16 kHz mono preferred), optional
`response_format=text|json|srt|vtt`, optional `language`.

```bash
curl -fsS -F file=@clip.wav -F response_format=text http://127.0.0.1:48450/inference
```

Reference clients in `client/` (`whispervulkan.sh`, `whispervulkan.py`, `whispervulkan.rs`).
Consumers: the `voicechat` dictation daemon and `Trik_Klip` clip transcription.

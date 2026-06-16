#!/usr/bin/env bash
# Build whisper.cpp's whisper-server with the Vulkan backend.
# Reuses the sibling ~/programming/whisper.cpp checkout. Sudo-free.
# (Vulkan recipe + SPIRV-Headers workaround documented in the trik-klip-linux-dev memory.)
set -euo pipefail

WC="${WHISPER_CPP_DIR:-$HOME/programming/whisper.cpp}"
[ -d "$WC" ] || { echo "whisper.cpp not found at $WC — clone https://github.com/ggml-org/whisper.cpp.git there first" >&2; exit 1; }

# SPIRV-Headers is NOT in the Arch repos; installed header-only under ~/.local.
SPIRV_DIR="$HOME/.local/share/cmake/SPIRV-Headers"
if [ ! -d "$SPIRV_DIR" ]; then
  cat >&2 <<'EOF'
SPIRV-Headers missing from ~/.local. One-time, sudo-free install:
  git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git /tmp/SPIRV-Headers
  cmake -S /tmp/SPIRV-Headers -B /tmp/SPIRV-Headers/build -DCMAKE_INSTALL_PREFIX="$HOME/.local"
  cmake --install /tmp/SPIRV-Headers/build
EOF
  exit 1
fi

# ggml-vulkan's CMake doesn't propagate the include dir to its .cpp — feed it via the env.
export CPLUS_INCLUDE_PATH="$HOME/.local/include:${CPLUS_INCLUDE_PATH:-}"

cmake -S "$WC" -B "$WC/build" \
  -DGGML_VULKAN=1 -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_TESTS=OFF \
  -DSPIRV-Headers_DIR="$SPIRV_DIR"
cmake --build "$WC/build" -j --target whisper-server

echo "Built: $WC/build/bin/whisper-server"

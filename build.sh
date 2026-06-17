#!/usr/bin/env bash
# Build whisper.cpp's whisper-server. Sudo-free. Reuses the sibling whisper.cpp
# checkout (auto-cloned if missing).
#
# Usage:
#   ./build.sh           # GPU (Vulkan) backend  [default]
#   ./build.sh gpu       # same
#   ./build.sh cpu       # CPU-only backend (no Vulkan / SPIRV-Headers needed)
#
# GPU builds need the system Vulkan toolchain (loader + headers + a shader compiler).
# See README "Prerequisites" for the per-distro package list. CPU builds need only a
# C/C++ toolchain + cmake.
set -euo pipefail

BACKEND="${1:-gpu}"
WC="${WHISPER_CPP_DIR:-$HOME/programming/whisper.cpp}"

# Clone the sibling whisper.cpp checkout if it isn't there yet.
if [ ! -d "$WC" ]; then
  echo "whisper.cpp not found at $WC — cloning…" >&2
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "$WC"
fi

CMAKE_ARGS=(-DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_TESTS=OFF)

case "$BACKEND" in
  gpu|vulkan)
    # SPIRV-Headers is NOT in the Arch repos; install it header-only under ~/.local (sudo-free).
    SPIRV_DIR="$HOME/.local/share/cmake/SPIRV-Headers"
    if [ ! -d "$SPIRV_DIR" ]; then
      echo "Installing SPIRV-Headers under ~/.local (one-time, sudo-free)…" >&2
      tmp="$(mktemp -d)"
      git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git "$tmp"
      cmake -S "$tmp" -B "$tmp/build" -DCMAKE_INSTALL_PREFIX="$HOME/.local"
      cmake --install "$tmp/build"
      rm -rf "$tmp"
    fi
    # ggml-vulkan's CMake doesn't propagate the include dir to its .cpp — feed it via the env.
    export CPLUS_INCLUDE_PATH="$HOME/.local/include:${CPLUS_INCLUDE_PATH:-}"
    CMAKE_ARGS+=(-DGGML_VULKAN=1 -DSPIRV-Headers_DIR="$SPIRV_DIR")
    echo "Building whisper-server with the Vulkan (GPU) backend." >&2
    ;;
  cpu)
    echo "Building whisper-server with the CPU backend (no GPU)." >&2
    ;;
  *)
    echo "Unknown backend '$BACKEND' — use 'gpu' or 'cpu'." >&2
    exit 1
    ;;
esac

cmake -S "$WC" -B "$WC/build" "${CMAKE_ARGS[@]}"
cmake --build "$WC/build" -j --target whisper-server

echo "Built: $WC/build/bin/whisper-server" >&2

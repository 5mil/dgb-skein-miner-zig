#!/usr/bin/env bash
# build-wsl.sh -- build rake on WSL / Linux x86_64
# Auto-installs Zig 0.16.0 if not present or wrong version.
# Usage: bash build-wsl.sh [clean]

REQUIRED="0.16.0"
ZIG_DIR="$HOME/.zig-0.16.0"
ZIG_BIN="$ZIG_DIR/zig"
ZIG_URL="https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz"
BIN=zig-out/bin/rake

if [ "$1" = "clean" ]; then
  echo "[*] Cleaning build cache..."
  rm -rf .zig-cache zig-out
fi

# Ensure xz-utils is present for tar extraction
if ! command -v xz &>/dev/null; then
  echo "[*] Installing xz-utils..."
  apt-get install -y xz-utils 2>/dev/null || true
fi

# Install Zig 0.16 if missing or wrong version
CURRENT=$("$ZIG_BIN" version 2>/dev/null || true)
if [ "$CURRENT" != "$REQUIRED" ]; then
  echo "[*] Installing Zig $REQUIRED to $ZIG_DIR ..."
  rm -rf "$ZIG_DIR"
  mkdir -p "$ZIG_DIR"
  TMP=$(mktemp -d)
  echo "[*] Downloading..."
  wget -q --show-progress -O "$TMP/zig.tar.xz" "$ZIG_URL" || { echo "[-] Download failed: $ZIG_URL"; exit 1; }
  echo "[*] Extracting..."
  tar xf "$TMP/zig.tar.xz" -C "$TMP" || { echo "[-] Extract failed"; exit 1; }
  EXTRACTED=$(find "$TMP" -maxdepth 1 -name 'zig-x86_64-linux-*' -type d | head -1)
  if [ -z "$EXTRACTED" ]; then echo "[-] Could not find extracted dir in $TMP"; ls "$TMP"; exit 1; fi
  mv "$EXTRACTED"/* "$ZIG_DIR/"
  rm -rf "$TMP"
  echo "[+] Zig $REQUIRED ready"
fi

# ---- From here, fail on any error ----
set -e

export PATH="$ZIG_DIR:$PATH"
echo "[*] Zig version: $(zig version)"

# Detect AVX2 -- Ryzen 9 always has it
CPU_FLAGS=()
if grep -q avx2 /proc/cpuinfo 2>/dev/null; then
  CPU_FLAGS+=("-Dcpu=x86_64_v3")
  echo "[*] AVX2 detected -- building with x86_64_v3"
else
  echo "[*] No AVX2 -- building baseline x86_64"
fi

echo "[*] Building rake (ReleaseFast, x86_64-linux-musl)..."

zig build \
  -Doptimize=ReleaseFast \
  -Dtarget=x86_64-linux-musl \
  "${CPU_FLAGS[@]}"

if [ -f "$BIN" ]; then
  echo "[+] Build successful: $BIN"
  echo "[*] Size: $(du -h $BIN | cut -f1)"
  echo
  echo "[*] Running self-tests..."
  "$BIN"
else
  echo "[-] Build failed: binary not found"
  exit 1
fi

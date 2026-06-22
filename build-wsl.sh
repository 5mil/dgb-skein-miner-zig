#!/usr/bin/env bash
# build-wsl.sh -- build rake on WSL / Linux x86_64
# Auto-installs Zig 0.16.0 if not present or wrong version, then re-execs.
# Usage: bash build-wsl.sh [clean]

set -e

REQUIRED="0.16.0"
ZIG_DIR="$HOME/.zig-0.16.0"
ZIG_BIN="$ZIG_DIR/zig"
ZIG_URL="https://ziglang.org/download/0.16.0/zig-linux-x86_64-0.16.0.tar.xz"
BIN=zig-out/bin/rake

if [ "$1" = "clean" ]; then
  echo "[*] Cleaning build cache..."
  rm -rf .zig-cache zig-out
fi

# Install Zig 0.16 if missing or wrong version
CURRENT=$("$ZIG_BIN" version 2>/dev/null || echo "none")
if [ "$CURRENT" != "$REQUIRED" ]; then
  echo "[*] Installing Zig $REQUIRED to $ZIG_DIR ..."
  mkdir -p "$ZIG_DIR"
  TMP=$(mktemp -d)
  wget -q --show-progress -O "$TMP/zig.tar.xz" "$ZIG_URL"
  tar xf "$TMP/zig.tar.xz" -C "$TMP"
  cp -r "$TMP"/zig-linux-x86_64-0.16.0/. "$ZIG_DIR/"
  rm -rf "$TMP"
  echo "[+] Zig $REQUIRED installed. Continuing build..."
fi

export PATH="$ZIG_DIR:$PATH"
echo "[*] Zig version: $(zig version)"

# Detect AVX2
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
  $BIN
else
  echo "[-] Build failed: binary not found"
  exit 1
fi

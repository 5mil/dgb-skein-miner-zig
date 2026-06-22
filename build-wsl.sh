#!/usr/bin/env bash
# build-wsl.sh -- build rake on WSL / Linux x86_64 (AMD Ryzen 9 or any x86_64)
# Detects AVX2 automatically and enables it if present.
# Usage: bash build-wsl.sh [clean]

set -e

BIN=zig-out/bin/rake

if [ "$1" = "clean" ]; then
  echo "[*] Cleaning build cache..."
  rm -rf .zig-cache zig-out
fi

# Check Zig is installed
if ! command -v zig &>/dev/null; then
  echo "[-] Zig not found. Install it:"
  echo "    https://ziglang.org/download/"
  echo "    or: snap install zig --classic --edge"
  exit 1
fi

echo "[*] Zig version: $(zig version)"

# Detect AVX2 -- Ryzen 9 always has it, but guard anyway
if grep -q avx2 /proc/cpuinfo 2>/dev/null; then
  CPU_FLAG="-Dcpu=x86_64_v3"   # AVX2 + BMI2 + FMA baseline
  echo "[*] AVX2 detected -- building with x86_64_v3"
else
  CPU_FLAG=""
  echo "[*] No AVX2 -- building baseline x86_64"
fi

echo "[*] Building rake (ReleaseFast, x86_64-linux-musl)..."

zig build \
  -Doptimize=ReleaseFast \
  -Dtarget=x86_64-linux-musl \
  $CPU_FLAG

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

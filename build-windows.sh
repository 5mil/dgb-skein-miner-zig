#!/data/data/com.termux/files/usr/bin/bash
# build-windows.sh -- cross-compile rake.exe for Windows x86_64 from Termux
# Output: zig-out/bin/rake.exe
# Transfer to Windows then run:  rake.exe --mine <wallet> --algo skein

set -e

if [ "$1" = "clean" ]; then
  echo "[*] Cleaning..."
  rm -rf .zig-cache zig-out
fi

echo "[*] Zig version: $(zig version)"
echo "[*] Cross-compiling rake.exe (x86_64-windows-gnu, ReleaseFast)..."

zig build windows -Doptimize=ReleaseFast

EXE=zig-out/bin/rake.exe
if [ -f "$EXE" ]; then
  echo "[+] Done: $EXE"
  echo "[*] Size: $(du -h $EXE | cut -f1)"
  echo
  echo "Copy to Windows:"
  echo "  termux-setup-storage  # first time only"
  echo "  cp $EXE /sdcard/Download/rake.exe"
else
  echo "[-] Build failed"
  exit 1
fi

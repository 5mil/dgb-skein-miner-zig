# rake

DGB Skein-512 / YescryptR16 miner written in Zig 0.16.
Builds natively on Android (Termux) and cross-compiles to Windows from the same machine.

---

## Install on Android (Termux)

### 1. Install dependencies

```sh
pkg update && pkg install zig git resolv-conf ca-certificates
```

### 2. Clone

```sh
git clone https://github.com/5mil/rake
cd rake
```

### 3. Build

```sh
bash build-termux.sh
```

Binary is placed at `~/bin/rake`.

### 4. Run

```sh
# Self-test
rake

# Mine Skein (DGB)
rake --mine YOUR_WALLET.workerName --algo skein --threads 4

# Mine YescryptR16 (DGB)
rake --mine YOUR_WALLET.workerName --algo yescrypt --threads 2

# Custom pool
rake --mine YOUR_WALLET.workerName --algo skein --host eu.mining-dutch.nl --port 9994 --threads 4
```

---

## Cross-compile `rake.exe` for Windows (from Termux)

```sh
bash build-windows.sh
# output: zig-out/bin/rake.exe
```

Copy to Windows:

```sh
termux-setup-storage   # first time only
cp zig-out/bin/rake.exe /sdcard/Download/rake.exe
```

Then on Windows (no install needed, fully static):

```cmd
rake.exe --mine YOUR_WALLET.workerName --algo skein --threads 8
```

---

## Options

| Flag | Default | Description |
|---|---|---|
| `--mine <wallet>` | — | Start mining with this wallet/worker |
| `--algo skein\|yescrypt` | `skein` | Algorithm |
| `--host <host>` | `americas.mining-dutch.nl` | Pool hostname |
| `--port <port>` | `9994` | Pool port |
| `--threads <n>` | `4` | Worker threads |

---

## Notes

- The Android binary is statically linked (musl) — no `.so` dependencies, runs on any Android/aarch64 device
- AVX2 is auto-detected on x86_64 Windows builds for faster Skein hashing
- If `getaddrinfo` fails, ensure `/etc/resolv.conf` exists: `echo 'nameserver 1.1.1.1' >> /etc/resolv.conf`

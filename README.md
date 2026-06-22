# rake

DGB Skein-512 / YescryptR16 miner written in Zig 0.16.
Builds natively on Android (Termux), WSL/Linux x86_64, and cross-compiles to Windows.

---

## Android / Termux

### 1. Install dependencies

```sh
pkg update && pkg install zig git resolv-conf ca-certificates
```

### 2. Clone & build

```sh
git clone https://github.com/5mil/rake
cd rake
bash build-termux.sh
```

Binary placed at `zig-out/bin/rake`.

---

## WSL / Linux x86_64 (AMD Ryzen 9 etc.)

### 1. Install Zig 0.16

```sh
# Option A -- snap (Ubuntu/Debian WSL)
snap install zig --classic --edge

# Option B -- manual
wget https://ziglang.org/download/0.16.0/zig-linux-x86_64-0.16.0.tar.xz
tar xf zig-linux-x86_64-0.16.0.tar.xz
export PATH=$PWD/zig-linux-x86_64-0.16.0:$PATH
```

### 2. Install git

```sh
sudo apt update && sudo apt install -y git
```

### 3. Clone & build

```sh
git clone https://github.com/5mil/rake
cd rake
bash build-wsl.sh
```

AVX2 is auto-detected — on a Ryzen 9 it will compile with `x86_64_v3` for maximum Skein throughput.

Binary placed at `zig-out/bin/rake`.

### 4. Run

```sh
# Self-test
./zig-out/bin/rake

# Mine Skein (DGB)
./zig-out/bin/rake --mine YOUR_WALLET.workerName --algo skein --threads 16

# Mine YescryptR16
./zig-out/bin/rake --mine YOUR_WALLET.workerName --algo yescrypt --threads 8
```

---

## Windows (cross-compiled from Termux or WSL)

```sh
bash build-windows.sh
# output: zig-out/bin/rake.exe
```

No installer needed -- fully static binary, no DLL dependencies.

```cmd
rake.exe --mine YOUR_WALLET.workerName --algo skein --threads 16
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

- All binaries are statically linked (musl) — zero runtime `.so` / `.dll` dependencies
- AVX2 is auto-detected on x86_64 builds for faster Skein hashing
- If DNS fails in WSL: `echo 'nameserver 1.1.1.1' | sudo tee /etc/resolv.conf`
- If DNS fails in Termux: `echo 'nameserver 1.1.1.1' >> /etc/resolv.conf`

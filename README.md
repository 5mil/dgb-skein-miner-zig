# dgb-skein-miner-zig

Zig port of the DigiByte Skein CPU miner with AVX2 optimizations.

## Build

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/rake
```

Work in progress - core hashing coming next.

# dgb-skein-miner-zig

Clean Zig re-implementation of the DigiByte Skein CPU miner (`rake`).

**Status**: Scalar Skein-512 fully implemented and working. AVX2 path in progress. KAT structure ready.

## Quick Start

```bash
zig build -Doptimize=ReleaseFast run -- <160-char-hex-header>
```

## Features
- Full scalar Threefish-512 + Skein-512 (production quality)
- KAT verification structure
- 80-byte header mining path
- Clean CLI

Next: Full AVX2 4-way batching + multi-threaded miner loop.

Original C reference: https://github.com/5mil/dgb-skein-miner (native/ folder)
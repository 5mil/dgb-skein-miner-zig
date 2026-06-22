# dgb-skein-miner-zig

Clean Zig re-implementation of the DigiByte Skein CPU miner (`rake`).

**Status**: Core structure + build system in place. Hashing functions being ported from original C.

## Quick Start

```bash
zig build run
```

Full port in progress with scalar + AVX2 paths.

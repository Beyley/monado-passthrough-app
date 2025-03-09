# monado-passthrough-app

all this does is put you in passthrough, it does nothing else.

## Building

### Prerequisites

- Zig `0.15.0-dev.23+1eb729b9b` (newer/older versions may work)
- The latest dev build of [Beyley/SDL#openxr](https://github.com/Beyley/SDL/tree/openxr) (tested against `d64e41f95ea641a32da18e526d57013966a96b41`)
- Internet connection

### Commands

```bash
zig build -Doptimize=ReleaseSafe

zig-out/bin/monado-passthrough-app
```

# KvoteReply

Pixel-perfect authentic Compose message bubble photo quote replies for [MandaGram](https://github.com/OwnerTS/MandaGram).

## Overview

KvoteReply intercepts replies to Telegram messages and generates authentic quote cards directly from MandaGram's Compose UI components (`MessageBubble`, `MandaGramTheme`, Skia `ImageComposeScene`).

- **Authentic UI**: Reuses native Compose rendering — same Google Sans typography, Apple emoji, avatars, and message bubbles.
- **Headless & Offscreen**: Pure offscreen rendering via Skia. Zero OS screen capturing, zero window focus dependency, zero GDI+ approximations.
- **Self-Contained**: Java bytecode is embedded directly into the native library and loaded into the JVM dynamically via JNI `DefineClass` (no `.jar` files needed).
- **Cross-Platform**: Builds cleanly for Windows x64 (`.dll`) and Linux x86_64 (`.so`).

## Building

Requires [Zig](https://ziglang.org/) **0.15.2+**.

```bash
# Build for host OS
zig build -Doptimize=ReleaseFast

# Cross-compile for Windows x64
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu

# Cross-compile for Linux x86_64
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu
```

The compiled binaries will be in `zig-out/bin/` (Windows `.dll`) or `zig-out/lib/` (Linux `.so`).

## Installation

1. Copy `quoteReply.dll` (Windows) or `libquoteReply.so` (Linux) into your MandaGram plugins directory:
   ```
   <MandaGram>/data/plugins/
   ```
2. Enable or reload the plugin in MandaGram settings.

## License

MIT

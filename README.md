# KvoteReply v2.0.0

Pixel-perfect authentic Compose message bubble photo quote replies for [MandaGram](https://github.com/OwnerTS/MandaGram).

## Overview

KvoteReply intercepts replies to Telegram messages and generates authentic quote cards directly from MandaGram's Compose UI components (`MessageBubble`, `MandaGramTheme`, Skia `ImageComposeScene`).

- **100% Pure Zig Native Architecture**: Zero Java bytecode files, zero `.class` files, zero JNI `DefineClass` calls, and zero C/C++ dependencies. The entire plugin is compiled into a single high-performance native dynamic library.
- **Authentic Compose UI**: Directly invokes MandaGram's Compose components (`MessageBubbleKt.MessageBubble` wrapped in `ThemeKt.MandaGramTheme`). Retains the exact same Google Sans typography, Apple emoji, avatars, message shape, and verified badges.
- **Headless & Offscreen**: Pure offscreen rendering via Jetpack Compose Desktop (`ImageComposeScene`) and Skia (`org.jetbrains.skia`). Zero OS window focus dependency, zero screen scraping, zero GDI+ approximations.
- **Direct Skia Memory Scan**: Inspects raw pixel memory (`Pixmap.getAddr()`) with stride pitch awareness (`rowBytes`) to determine the exact bounding box of the message bubble with zero intermediate JVM byte array copying.
- **Theme Matching**: Dynamically detects current MandaGram theme settings (Light, Dark, Monet Pistachio) and fills the bubble backdrop with the appropriate background color to prevent jarring white seams.
- **JNI Safety & RAII**: Strict frame management using `PushLocalFrame` / `PopLocalFrame`, leak-free global reference cleanup on unload via cached `JavaVM`, and safe reference promotion.
- **Cross-Platform**: Builds cleanly for Windows x64 (`.dll`) and Linux x86_64 (`.so`).

## Architecture & Pipeline

```
Telegram UI (AWT Thread)
       │
       ▼
ChatComposerActions#beginReply (Hook 1)
       │
       ├──► Asynchronous Headless Pre-rendering
       │       ├── ImageComposeScene (650x1500)
       │       ├── ComposeInterop.createComposableLambda
       │       ├── MandaGramTheme { MessageBubble(...) }
       │       └── Skia Image Snapshot
       │               │
       │               ├── Native Memory Scan (Pixmap.getAddr)
       │               ├── Find Non-Empty Alpha Bounding Box
       │               ├── Sub-surface Blit with Background Fill
       │               └── Lossless PNG Encode to Disk Cache
       │
ChatComposerActions#sendDraft (Hook 2)
       │
       ▼
TdLibSession#requestForSession / SimpleTelegramClient#send (Hooks 3 & 4)
       │
       ├──► Intercept it.tdlight.jni.TdApi$SendMessage
       ├──► Replace InputMessageText with InputMessagePhoto (using rendered PNG)
       ├──► Attach original message text as caption
       └──► Attach Telegram InputTextQuote metadata to replyTo
```

## Building

Requires [Zig](https://ziglang.org/) **0.15.2+**.

```bash
# Run unit tests
zig build test --summary all

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

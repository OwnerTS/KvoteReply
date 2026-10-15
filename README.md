# KvoteReply v2.0.0

Authentic photo quote replies for [MandaGram](https://github.com/OwnerTS/MandaGram) built on MandaGram's modern pure FFI plugin architecture.

## Overview

KvoteReply intercepts replies to Telegram messages and generates beautiful, authentic photo quote cards directly inside the native plugin layer with zero JNI overhead.

- **100% Pure Zig Native Architecture**: Zero JNI dependencies (`JNIEnv`, `JavaVM`), zero Java bytecode manipulation, and zero C runtime dependencies. The entire plugin is compiled into a single high-performance native dynamic library.
- **Pure FFI C-ABI Interop**: Seamlessly integrates with MandaGram's 53-slot `PluginApi` vtable and 40-byte `HookParam` layout (Project Panama FFM bridge).
- **Built-in Software Rasterizer**: Pure Zig RGBA8888 canvas with alpha blending, rounded card corners, author avatar badge with initials, accent quote bar, and multiline word wrapping.
- **Embedded Raster Typography**: Built-in 8x16 font supporting full ASCII (0x20..0x7E) and Russian Cyrillic (А-Я, а-я, Ё, ё, typographic quotes and dashes).
- **Pure Zig PNG Encoder**: Built-in lossless PNG generator with uncompressed Deflate IDAT streams and hardware-accurate CRC32 and Adler32 checksums.
- **Direct TDLib JSON Query Execution**: Cancels the default plain text send (`param.cancel()`) and dispatches `sendMessage` with `inputMessagePhoto` directly through `api.execute_tdlib_query`.
- **Zero-Latency Background Pipeline**: Pre-renders the quote card in the background immediately when the user initiates a reply (`ChatComposerActions#beginReply`), so the card is ready before the user clicks Send.
- **Settings & Action Menus**: Registers custom chat actions via `api.register_chat_action` and persists state via `api.get_storage_dir`.
- **Cross-Platform**: Compiles out-of-the-box for Windows x64 (`quoteReply.dll`) and Linux x86_64 (`libquoteReply.so`).

## Architecture & Pipeline

```
Telegram UI (AWT Thread)
       │
       ▼
ChatComposerActions#beginReply (Hook 1)
       │
       ├──► Parse replied message ID, sender title, and text via FFI reflection
       ├──► Asynchronous background render to cache (<cache_dir>/quote_replies/quote_reply_<id>.png)
       │       ├── RGBA8888 canvas allocation
       │       ├── Backdrop, rounded bubble, avatar circle, and accent line
       │       ├── 8x16 bitmap typography (ASCII + Cyrillic)
       │       └── Pure Zig PNG encoding (IHDR, IDAT, IEND)
       │
ChatComposerActions#sendDraft (Hook 2)
       │
       ▼
TdLibSession#requestForSession / SimpleTelegramClient#send (Hooks 3 & 4)
       │
       ├──► Intercept outgoing reply
       ├──► Check if quote PNG is ready
       ├──► Cancel default send: param.cancel()
       └──► Execute TDLib JSON via api.execute_tdlib_query:
               {
                 "@type": "sendMessage",
                 "chat_id": <chat_id>,
                 "reply_to": {
                   "@type": "inputMessageReplyToMessage",
                   "message_id": <reply_msg_id>
                 },
                 "input_message_content": {
                   "@type": "inputMessagePhoto",
                   "photo": {
                     "@type": "inputFileLocal",
                     "path": "<quote_png_path>"
                   },
                   "caption": {
                     "@type": "formattedText",
                     "text": "<outgoing_text>"
                   }
                 }
               }
```

## Building

Requires [Zig](https://ziglang.org/) **0.15.2+**.

```bash
# Run unit tests
zig build test --summary all

# Build for host OS (Windows x64 or Linux x86_64)
zig build -Doptimize=ReleaseFast

# Cross-compile for Windows x64 (from Linux or Windows)
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu

# Cross-compile for Linux x86_64 (from Windows or Linux)
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu
```

The compiled binaries will be placed in:
- Windows: `zig-out/bin/quoteReply.dll`
- Linux: `zig-out/lib/libquoteReply.so`

## Installation

1. Copy `quoteReply.dll` (Windows) or `libquoteReply.so` (Linux) into your MandaGram plugins directory:
   ```
   <MandaGram>/data/plugins/
   ```
2. Enable or reload the plugin in MandaGram settings.

## Unit Tests

The test suite validates:
- UTF-8 string truncation and bounds validation
- JSON character escaping (quotes, backslashes, control characters)
- Plugin metadata structure and hooks table
- Quote cache path generation and rotation logic
- Font glyph rendering and ASCII/Cyrillic character mapping
- PNG signature, chunks, CRC32, and Adler32 checksums
- Full quote card rendering and PNG encoding pipeline

Run tests with:
```bash
zig build test --summary all
```

## License

MIT

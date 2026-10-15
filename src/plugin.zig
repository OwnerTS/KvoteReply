//! ============================================================================
//! KvoteReply v2.0.0 — Pure Zig Compose Quote Renderer Plugin for MandaGram
//!
//! Данный плагин перехватывает исходящие ответы на сообщения в Telegram и
//! превращает их в фото-цитаты с аутентичным внешним видом Compose Desktop:
//! - Настоящий MessageBubble из MandaGram (тот же шрифт Google Sans, Apple эмодзи,
//!   скругления пузыря, аватарка, имя автора, галочки статуса).
//! - 100% Native Pure Zig архитектура без внешних Java-файлов, без .class байткода
//!   и без вызова небезопасного JNI DefineClass.
//! - Headless Offscreen рендеринг через Jetpack Compose Desktop (ImageComposeScene)
//!   и Skia (org.jetbrains.skia).
//! - Прямое сканирование нативной памяти пикселей (Skia Pixmap) для точного
//!   вычисления границ пузыря (bounding box) и обрезки без полей.
//! - Автоматическая адаптация цвета фона под текущую тему оформления MandaGram
//!   (светлая / тёмная / Monet Pistachio).
//! ============================================================================

const std = @import("std");
const plugin_api = @import("include/mandagram_plugin.zig");
const accessor = @import("include/jni_accessor.zig");

// Импорт базовых типов JNI и Plugin API
const HookParam = plugin_api.HookParam;
const PluginApi = plugin_api.PluginApi;
const JniAccessor = accessor.JniAccessor;
const JNIEnv = plugin_api.JNIEnv;
const JavaVM = plugin_api.JavaVM;
const jobject = plugin_api.jobject;
const jclass = plugin_api.jclass;
const jvalue = plugin_api.jvalue;
const jint = plugin_api.jint;
const jlong = plugin_api.jlong;
const jboolean = plugin_api.jboolean;
const jfloat = plugin_api.jfloat;

// -----------------------------------------------------------------------------
// Глобальное состояние плагина
// -----------------------------------------------------------------------------

/// Указатель на интерфейс ядра MandaGram Plugin API
var global_api: ?*const PluginApi = null;

/// Атомарный флаг активности плагина
var is_active = std.atomic.Value(bool).init(true);

/// Пользовательская настройка: отключать ли авто-фотоцитаты в топиках форумов и обсуждениях
var disable_in_discussions: bool = false;

/// Метаданные плагина, экспортируемые ядру MandaGram
pub const METADATA = plugin_api.PluginMetadata{
    .name = "KvoteReply",
    .version = "2.0.0",
    .author = "OwnerTS",
    .description = "Pixel-perfect authentic Compose message bubble photo quote replies for MandaGram (Pure Zig, Headless Skia).",
};

/// Точка входа для получения метаданных плагина загрузчиком MandaGram
pub export fn mandagram_plugin_metadata() callconv(.c) ?*const plugin_api.PluginMetadata {
    return &METADATA;
}

/// Состояние подготавливаемой цитаты
pub const PendingQuoteState = struct {
    msg_id: i64 = 0,
    chat_id: i64 = 0,
    is_discussion: bool = false,
    captured_path_buf: [512]u8 = [_]u8{0} ** 512,
    captured_path_len: usize = 0,
};

/// Мьютекс для защиты конкурентного доступа к состоянию ответа
var quote_mutex = std.Thread.Mutex{};

/// Активное состояние ответа
var pending_quote = PendingQuoteState{};

/// Кэшированная глобальная JNI-ссылка на объект MessageItem
var cached_message_item: ?jobject = null;

// -----------------------------------------------------------------------------
// Вспомогательные функции логирования и проверки исключений JNI
// -----------------------------------------------------------------------------

fn logFmt(comptime fmt: []const u8, args: anytype) void {
    const api = global_api orelse return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    api.log_info("KvoteReply", msg);
}

fn logErrFmt(comptime fmt: []const u8, args: anytype) void {
    const api = global_api orelse return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    api.log_error("KvoteReply", msg);
}

pub fn checkClearException(env: *JNIEnv) void {
    if (env.*.ExceptionOccurred) |occ| {
        if (occ(env)) |ex| {
            if (env.*.ExceptionDescribe) |desc| {
                desc(env);
            }
            if (env.*.ExceptionClear) |clear| {
                clear(env);
            }
            if (env.*.DeleteLocalRef) |del| {
                del(env, ex);
            }
            logErrFmt("[JNI Exception detected and cleared]", .{});
            return;
        }
    }
    if (env.*.ExceptionClear) |clear| {
        clear(env);
    }
}

pub fn utf8Truncate(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var len = max_bytes;
    while (len > 0 and (text[len] & 0xC0) == 0x80) {
        len -= 1;
    }
    return text[0..len];
}

pub fn escapeJson(text: []const u8, out_buf: []u8) []const u8 {
    var out_idx: usize = 0;
    for (text) |c| {
        if (out_idx + 6 >= out_buf.len) break;
        switch (c) {
            '"' => {
                out_buf[out_idx] = '\\';
                out_buf[out_idx + 1] = '"';
                out_idx += 2;
            },
            '\\' => {
                out_buf[out_idx] = '\\';
                out_buf[out_idx + 1] = '\\';
                out_idx += 2;
            },
            '\n' => {
                out_buf[out_idx] = '\\';
                out_buf[out_idx + 1] = 'n';
                out_idx += 2;
            },
            '\r' => {
                out_buf[out_idx] = '\\';
                out_buf[out_idx + 1] = 'r';
                out_idx += 2;
            },
            '\t' => {
                out_buf[out_idx] = '\\';
                out_buf[out_idx + 1] = 't';
                out_idx += 2;
            },
            else => {
                if (c < 0x20) {
                    const esc = std.fmt.bufPrint(out_buf[out_idx .. out_idx + 6], "\\u{x:0>4}", .{c}) catch break;
                    out_idx += esc.len;
                } else {
                    out_buf[out_idx] = c;
                    out_idx += 1;
                }
            },
        }
    }
    return out_buf[0..out_idx];
}

// -----------------------------------------------------------------------------
// Сохранение и загрузка настроек плагина
// -----------------------------------------------------------------------------

fn loadSettings(api: *const PluginApi) void {
    var dir_buf: [512]u8 = undefined;
    if (api.get_storage_dir) |get_dir| {
        const len = get_dir("KvoteReply", &dir_buf, dir_buf.len);
        if (len > 0) {
            const dir_path = dir_buf[0..@intCast(len)];
            var path_buf: [550]u8 = undefined;
            const file_path = std.fmt.bufPrint(&path_buf, "{s}/settings.txt", .{dir_path}) catch return;
            const file = std.fs.openFileAbsolute(file_path, .{}) catch return;
            defer file.close();
            var val_buf: [16]u8 = undefined;
            const read_len = file.readAll(&val_buf) catch return;
            if (read_len > 0 and val_buf[0] == '1') {
                disable_in_discussions = true;
            }
        }
    }
}

fn saveSettings() void {
    const api = global_api orelse return;
    var dir_buf: [512]u8 = undefined;
    if (api.get_storage_dir) |get_dir| {
        const len = get_dir("KvoteReply", &dir_buf, dir_buf.len);
        if (len > 0) {
            const dir_path = dir_buf[0..@intCast(len)];
            std.fs.makeDirAbsolute(dir_path) catch {};
            var path_buf: [550]u8 = undefined;
            const file_path = std.fmt.bufPrint(&path_buf, "{s}/settings.txt", .{dir_path}) catch return;
            const file = std.fs.createFileAbsolute(file_path, .{}) catch return;
            defer file.close();
            _ = file.write(if (disable_in_discussions) "1" else "0") catch {};
        }
    }
}

// -----------------------------------------------------------------------------
// Кэширование файлов на диске
// -----------------------------------------------------------------------------

pub const CacheFileEntry = struct {
    name: [128]u8,
    name_len: usize,
    mtime: i128,
};

pub fn cleanupCacheDir(dir_path: []const u8, max_files: usize) void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var entries_buf: [64]CacheFileEntry = undefined;
    var count: usize = 0;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "quote_reply_") or !std.mem.endsWith(u8, entry.name, ".png")) continue;

        const stat = dir.statFile(entry.name) catch continue;
        if (count < entries_buf.len) {
            const copy_len = @min(entry.name.len, entries_buf[count].name.len);
            @memcpy(entries_buf[count].name[0..copy_len], entry.name[0..copy_len]);
            entries_buf[count].name_len = copy_len;
            entries_buf[count].mtime = stat.mtime;
            count += 1;
        }
    }

    if (count > max_files) {
        const slice = entries_buf[0..count];
        std.mem.sort(CacheFileEntry, slice, {}, struct {
            fn lessThan(_: void, a: CacheFileEntry, b: CacheFileEntry) bool {
                return a.mtime < b.mtime;
            }
        }.lessThan);

        const to_delete = count - max_files;
        for (slice[0..to_delete]) |item| {
            dir.deleteFile(item.name[0..item.name_len]) catch {};
        }
    }
}

pub fn getQuotesCacheDir(api: *const PluginApi, out_buf: []u8) ?[]const u8 {
    var cache_buf: [512]u8 = undefined;
    if (api.get_cache_dir) |get_dir| {
        const len = get_dir("KvoteReply", &cache_buf, cache_buf.len);
        if (len > 0) {
            const base = cache_buf[0..@intCast(len)];
            const formatted = std.fmt.bufPrint(out_buf, "{s}/quote_replies", .{base}) catch return null;
            std.fs.makeDirAbsolute(formatted) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return null,
            };
            return formatted;
        }
    }
    const fallback = std.fmt.bufPrint(out_buf, "data/cache/quote_replies", .{}) catch return null;
    std.fs.cwd().makePath(fallback) catch {};
    return fallback;
}

pub fn savePngBytesToFile(
    api: *const PluginApi,
    bytes: []const u8,
    out_path_buf: []u8,
) ?[:0]const u8 {
    var dir_buf: [512]u8 = undefined;
    const cache_dir = getQuotesCacheDir(api, &dir_buf) orelse return null;

    cleanupCacheDir(cache_dir, 8);

    const ts = std.time.milliTimestamp();
    const full_path = std.fmt.bufPrint(
        out_path_buf,
        "{s}/quote_reply_{d}.png",
        .{ cache_dir, ts },
    ) catch return null;

    const file = std.fs.createFileAbsolute(full_path, .{}) catch return null;
    defer file.close();

    file.writeAll(bytes) catch return null;

    if (full_path.len < out_path_buf.len) {
        out_path_buf[full_path.len] = 0;
        return out_path_buf[0..full_path.len :0];
    }
    return null;
}

// -----------------------------------------------------------------------------
// Загрузка классов Java через JNI с поддержкой контекстного ClassLoader
// -----------------------------------------------------------------------------

fn getClassLoaderFromObject(env: *JNIEnv, obj: jobject) jobject {
    if (obj == null) return null;
    const item_cls = JniAccessor.getObjectClass(env, obj) orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, item_cls);
    const cls_cls = JniAccessor.getObjectClass(env, item_cls) orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, cls_cls);
    const mid = env.*.GetMethodID.?(
        env,
        cls_cls,
        "getClassLoader",
        "()Ljava/lang/ClassLoader;",
    ) orelse {
        checkClearException(env);
        return null;
    };
    return env.*.CallObjectMethod.?(env, item_cls, mid);
}

fn loadClass(env: *JNIEnv, loader: ?jobject, name_slashed: [*:0]const u8) ?jclass {
    const ldr = loader orelse plugin_api.getAppClassLoader(env);
    return plugin_api.loadClassWithLoader(env, ldr, name_slashed);
}

// -----------------------------------------------------------------------------
// Вспомогательные функции для работы со Skia (org.jetbrains.skia)
// -----------------------------------------------------------------------------

fn createRasterSurface(env: *JNIEnv, loader: jobject, width: usize, height: usize) jobject {
    const s_cls = loadClass(env, loader, "org/jetbrains/skia/Surface") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, s_cls);

    const comp_fid = env.*.GetStaticFieldID.?(env, s_cls, "Companion", "Lorg/jetbrains/skia/Surface$Companion;") orelse return null;
    const comp_obj = env.*.GetStaticObjectField.?(env, s_cls, comp_fid);
    if (comp_obj == null) return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, comp_obj.?);

    const comp_cls = loadClass(env, loader, "org/jetbrains/skia/Surface$Companion") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, comp_cls);

    const make_raster_mid = env.*.GetMethodID.?(env, comp_cls, "makeRasterN32Premul", "(II)Lorg/jetbrains/skia/Surface;") orelse return null;
    return env.*.CallObjectMethod.?(env, comp_obj.?, make_raster_mid, @as(jint, @intCast(width)), @as(jint, @intCast(height)));
}

fn getSurfaceCanvas(env: *JNIEnv, loader: jobject, surface: jobject) jobject {
    const s_cls = loadClass(env, loader, "org/jetbrains/skia/Surface") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, s_cls);

    const get_canvas_mid = env.*.GetMethodID.?(env, s_cls, "getCanvas", "()Lorg/jetbrains/skia/Canvas;") orelse return null;
    return env.*.CallObjectMethod.?(env, surface, get_canvas_mid);
}

fn clearCanvas(env: *JNIEnv, loader: jobject, canvas: jobject, color_argb: i32) void {
    const cvs_cls = loadClass(env, loader, "org/jetbrains/skia/Canvas") orelse return;
    defer if (env.*.DeleteLocalRef) |del| del(env, cvs_cls);

    const clear_mid = env.*.GetMethodID.?(env, cvs_cls, "clear", "(I)Lorg/jetbrains/skia/Canvas;");
    if (clear_mid) |clmid| {
        const cl_ret = env.*.CallObjectMethod.?(env, canvas, clmid, color_argb);
        if (cl_ret != null and env.*.DeleteLocalRef != null) env.*.DeleteLocalRef.?(env, cl_ret);
    } else {
        checkClearException(env);
    }
}

fn makeRectLTRB(env: *JNIEnv, loader: jobject, l: f32, t: f32, r: f32, b: f32) jobject {
    const r_cls = loadClass(env, loader, "org/jetbrains/skia/Rect") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, r_cls);

    const comp_fid = env.*.GetStaticFieldID.?(env, r_cls, "Companion", "Lorg/jetbrains/skia/Rect$Companion;") orelse return null;
    const rc_obj = env.*.GetStaticObjectField.?(env, r_cls, comp_fid);
    if (rc_obj == null) return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, rc_obj.?);

    const rc_cls = loadClass(env, loader, "org/jetbrains/skia/Rect$Companion") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, rc_cls);

    const make_ltrb_mid = env.*.GetMethodID.?(env, rc_cls, "makeLTRB", "(FFFF)Lorg/jetbrains/skia/Rect;") orelse return null;
    return env.*.CallObjectMethod.?(env, rc_obj.?, make_ltrb_mid, @as(jfloat, l), @as(jfloat, t), @as(jfloat, r), @as(jfloat, b));
}

fn makeRectWH(env: *JNIEnv, loader: jobject, w: f32, h: f32) jobject {
    const r_cls = loadClass(env, loader, "org/jetbrains/skia/Rect") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, r_cls);

    const comp_fid = env.*.GetStaticFieldID.?(env, r_cls, "Companion", "Lorg/jetbrains/skia/Rect$Companion;") orelse return null;
    const rc_obj = env.*.GetStaticObjectField.?(env, r_cls, comp_fid);
    if (rc_obj == null) return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, rc_obj.?);

    const rc_cls = loadClass(env, loader, "org/jetbrains/skia/Rect$Companion") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, rc_cls);

    const make_wh_mid = env.*.GetMethodID.?(env, rc_cls, "makeWH", "(FF)Lorg/jetbrains/skia/Rect;") orelse return null;
    return env.*.CallObjectMethod.?(env, rc_obj.?, make_wh_mid, @as(jfloat, w), @as(jfloat, h));
}

fn drawImageRect(env: *JNIEnv, loader: jobject, canvas: jobject, image: jobject, src_rect: jobject, dst_rect: jobject) void {
    const cvs_cls = loadClass(env, loader, "org/jetbrains/skia/Canvas") orelse return;
    defer if (env.*.DeleteLocalRef) |del| del(env, cvs_cls);

    const draw_mid = env.*.GetMethodID.?(
        env,
        cvs_cls,
        "drawImageRect",
        "(Lorg/jetbrains/skia/Image;Lorg/jetbrains/skia/Rect;Lorg/jetbrains/skia/Rect;)Lorg/jetbrains/skia/Canvas;",
    ) orelse return;

    const cvs_ret = env.*.CallObjectMethod.?(env, canvas, draw_mid, image, src_rect, dst_rect);
    if (cvs_ret != null and env.*.DeleteLocalRef != null) env.*.DeleteLocalRef.?(env, cvs_ret);
}

fn makeSurfaceSnapshot(env: *JNIEnv, loader: jobject, surface: jobject) jobject {
    const s_cls = loadClass(env, loader, "org/jetbrains/skia/Surface") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, s_cls);

    const make_snapshot_mid = env.*.GetMethodID.?(env, s_cls, "makeImageSnapshot", "()Lorg/jetbrains/skia/Image;") orelse return null;
    return env.*.CallObjectMethod.?(env, surface, make_snapshot_mid);
}

fn encodeImageToPngBytes(env: *JNIEnv, loader: jobject, image: jobject, quality: i32) jobject {
    const img_cls = loadClass(env, loader, "org/jetbrains/skia/Image") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, img_cls);

    const enc_fmt_cls = loadClass(env, loader, "org/jetbrains/skia/EncodedImageFormat") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, enc_fmt_cls);

    const png_fid = env.*.GetStaticFieldID.?(env, enc_fmt_cls, "PNG", "Lorg/jetbrains/skia/EncodedImageFormat;") orelse return null;
    const png_fmt = env.*.GetStaticObjectField.?(env, enc_fmt_cls, png_fid);
    if (png_fmt == null) return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, png_fmt.?);

    const encode_mid = env.*.GetMethodID.?(
        env,
        img_cls,
        "encodeToData",
        "(Lorg/jetbrains/skia/EncodedImageFormat;I)Lorg/jetbrains/skia/Data;",
    ) orelse return null;

    const data_obj = env.*.CallObjectMethod.?(env, image, encode_mid, png_fmt.?, @as(jint, quality));
    if (data_obj == null) return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, data_obj);

    const data_cls = loadClass(env, loader, "org/jetbrains/skia/Data") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, data_cls);

    const get_bytes_mid = env.*.GetMethodID.?(env, data_cls, "getBytes", "()[B") orelse return null;
    return env.*.CallObjectMethod.?(env, data_obj, get_bytes_mid);
}

pub fn getChatBackgroundColor(env: *JNIEnv) i32 {
    const theme_mgr_cls = JniAccessor.findClass(env, "com/mandagram/ui/theme/ThemeManager") orelse return @bitCast(@as(u32, 0xFF100D0B));
    defer if (env.*.DeleteLocalRef) |del| del(env, theme_mgr_cls);

    const inst_fid = env.*.GetStaticFieldID.?(
        env,
        theme_mgr_cls,
        "INSTANCE",
        "Lcom/mandagram/ui/theme/ThemeManager;",
    ) orelse {
        checkClearException(env);
        return @bitCast(@as(u32, 0xFF100D0B));
    };

    const inst = env.*.GetStaticObjectField.?(env, theme_mgr_cls, inst_fid);
    if (inst == null) {
        checkClearException(env);
        return @bitCast(@as(u32, 0xFF100D0B));
    }
    defer if (env.*.DeleteLocalRef) |del| del(env, inst.?);

    const is_dark_mid = env.*.GetMethodID.?(
        env,
        theme_mgr_cls,
        "isDark",
        "()Z",
    ) orelse {
        checkClearException(env);
        return @bitCast(@as(u32, 0xFF100D0B));
    };

    const is_dark = env.*.CallBooleanMethod.?(env, inst.?, is_dark_mid) != 0;
    checkClearException(env);

    if (!is_dark) {
        return @bitCast(@as(u32, 0xFFFDF8F6)); // Светлая тема
    }

    const seed_mid = env.*.GetMethodID.?(env, theme_mgr_cls, "getSeedColor-0d7_KjU", "()J");
    if (seed_mid) |smid| {
        const seed = env.*.CallLongMethod.?(env, inst.?, smid);
        checkClearException(env);
        const monet_cls = JniAccessor.findClass(env, "com/mandagram/ui/theme/MonetSeed");
        if (monet_cls) |mcls| {
            defer if (env.*.DeleteLocalRef) |del| del(env, mcls);
            const pist_fid = env.*.GetStaticFieldID.?(env, mcls, "PISTACHIO", "Lcom/mandagram/ui/theme/MonetSeed;");
            if (pist_fid) |pfid| {
                const pist = env.*.GetStaticObjectField.?(env, mcls, pfid);
                if (pist) |pobj| {
                    defer if (env.*.DeleteLocalRef) |del| del(env, pobj);
                    const color_mid = env.*.GetMethodID.?(env, mcls, "getColor-0d7_KjU", "()J");
                    if (color_mid) |cmid| {
                        const pist_color = env.*.CallLongMethod.?(env, pobj, cmid);
                        checkClearException(env);
                        if (seed == pist_color) {
                            return @bitCast(@as(u32, 0xFF0F110D)); // Тёмный фон Pistachio
                        }
                    }
                }
            }
        }
    }
    checkClearException(env);
    return @bitCast(@as(u32, 0xFF100D0B)); // Тёмная тема по умолчанию
}

fn renderCroppedBubbleImage(
    env: *JNIEnv,
    loader: jobject,
    full_img: jobject,
    src_l: usize,
    src_t: usize,
    src_r: usize,
    src_b: usize,
    dst_x: usize,
    dst_y: usize,
    canvas_w: usize,
    canvas_h: usize,
    bg_color: i32,
) jobject {
    const surface = createRasterSurface(env, loader, canvas_w, canvas_h) orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, surface);

    const canvas = getSurfaceCanvas(env, loader, surface) orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, canvas);

    clearCanvas(env, loader, canvas, bg_color);

    const src_rect = makeRectLTRB(env, loader, @floatFromInt(src_l), @floatFromInt(src_t), @floatFromInt(src_r), @floatFromInt(src_b)) orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, src_rect);

    const content_w = src_r - src_l;
    const content_h = src_b - src_t;

    const dst_rect = makeRectLTRB(
        env,
        loader,
        @floatFromInt(dst_x),
        @floatFromInt(dst_y),
        @floatFromInt(dst_x + content_w),
        @floatFromInt(dst_y + content_h),
    ) orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, dst_rect);

    drawImageRect(env, loader, canvas, full_img, src_rect, dst_rect);

    const snapshot = makeSurfaceSnapshot(env, loader, surface) orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, snapshot);

    return encodeImageToPngBytes(env, loader, snapshot, 100);
}

// -----------------------------------------------------------------------------
// Рендерер Compose: Отрисовка MandaGramTheme -> MessageBubble
// -----------------------------------------------------------------------------

const RenderState = struct {
    msg_item: jobject = null,
    is_group: bool = false,
    is_channel: bool = false,
    pass: u32 = 0,
    self_lambda: jobject = null,
};

fn renderComposable(composer_seg: jobject, user_data: usize) callconv(.c) void {
    const env = plugin_api.getJniEnv() orelse return;
    const real_composer = plugin_api.toJniObject(env, composer_seg);
    if (real_composer == null) return;

    const state: *RenderState = @ptrFromInt(user_data);
    if (state.pass == 0) {
        state.pass = 1;
        defer state.pass = 0;

        const theme_kt = loadClass(env, null, "com/mandagram/ui/theme/ThemeKt") orelse return;
        defer if (env.*.DeleteLocalRef) |del| del(env, theme_kt);
        const theme_mid = env.*.GetStaticMethodID.?(
            env,
            theme_kt,
            "MandaGramTheme",
            "(Lkotlin/jvm/functions/Function2;Landroidx/compose/runtime/Composer;I)V",
        ) orelse {
            checkClearException(env);
            return;
        };

        env.*.CallStaticVoidMethod.?(env, theme_kt, theme_mid, state.self_lambda, real_composer, @as(jint, 0));
        checkClearException(env);
    } else {
        const bubble_kt = loadClass(env, null, "com/mandagram/ui/chat/MessageBubbleKt") orelse return;
        defer if (env.*.DeleteLocalRef) |del| del(env, bubble_kt);
        const bubble_mid = env.*.GetStaticMethodID.?(
            env,
            bubble_kt,
            "MessageBubble",
            "(Lcom/mandagram/models/MessageItem;ZZZZJLkotlin/jvm/functions/Function1;Lkotlin/jvm/functions/Function1;Lkotlin/jvm/functions/Function2;Lkotlin/jvm/functions/Function1;Lkotlin/jvm/functions/Function1;Lkotlin/jvm/functions/Function1;Lkotlin/jvm/functions/Function2;Lkotlin/jvm/functions/Function0;Ljava/lang/String;Landroidx/compose/runtime/Composer;III)V",
        ) orelse {
            checkClearException(env);
            return;
        };

        env.*.CallStaticVoidMethod.?(
            env,
            bubble_kt,
            bubble_mid,
            state.msg_item,
            @as(jboolean, if (state.is_group) 1 else 0), // showAvatar
            @as(jboolean, 1), // isFirst
            @as(jboolean, 1), // isLast
            @as(jboolean, if (state.is_channel) 1 else 0), // isChannelPost
            @as(jlong, 0), // selection
            @as(jobject, null), // onAvatarClick
            @as(jobject, null), // onReplyClick
            @as(jobject, null), // onMediaClick
            @as(jobject, null), // onLinkClick
            @as(jobject, null), // onUserClick
            @as(jobject, null), // onChannelClick
            @as(jobject, null), // onHashtagClick
            @as(jobject, null), // onQuoteClick
            @as(jobject, null), // searchQuery
            real_composer,
            @as(jint, 54), // $changed
            @as(jint, 0), // $changed1
            @as(jint, 0x7FC0), // $default
        );
        checkClearException(env);
    }
}

// -----------------------------------------------------------------------------
// Рендеринг MessageItem в PNG файл на диске через Jetpack Compose и Skia
// -----------------------------------------------------------------------------

fn renderMessageItemToFile(env: *JNIEnv, msg_item: jobject, out_path_buf: []u8) ?[:0]const u8 {
    const api = global_api orelse return null;
    if (msg_item == null) return null;

    if (env.*.PushLocalFrame) |push| {
        if (push(env, 64) != 0) return null;
    }
    defer {
        if (env.*.PopLocalFrame) |pop| {
            _ = pop(env, null);
        }
    }

    const loader = getClassLoaderFromObject(env, msg_item);
    defer if (loader != null) {
        if (env.*.DeleteLocalRef) |del| del(env, loader.?);
    };

    const item_cls = JniAccessor.getObjectClass(env, msg_item) orelse return null;
    const is_outgoing_mid = env.*.GetMethodID.?(env, item_cls, "isOutgoing", "()Z") orelse return null;
    const is_outgoing = env.*.CallBooleanMethod.?(env, msg_item, is_outgoing_mid) != 0;

    const is_channel_mid = env.*.GetMethodID.?(env, item_cls, "isChannelPost", "()Z") orelse return null;
    const is_channel = env.*.CallBooleanMethod.?(env, msg_item, is_channel_mid) != 0;

    var state = RenderState{
        .msg_item = msg_item,
        .is_group = (!is_outgoing and !is_channel),
        .is_channel = is_channel,
        .pass = 0,
        .self_lambda = null,
    };

    // 1. Создаём Composable-лямбду через ComposeInterop
    const interop_cls = loadClass(env, loader, "com/mandagram/plugin/bridge/ComposeInterop") orelse {
        logErrFmt("[renderMessageItemToFile] Failed to find ComposeInterop", .{});
        return null;
    };
    defer if (env.*.DeleteLocalRef) |del| del(env, interop_cls);

    const create_mid = env.*.GetStaticMethodID.?(
        env,
        interop_cls,
        "createComposableLambda",
        "(JJ)Ljava/lang/Object;",
    ) orelse {
        logErrFmt("[renderMessageItemToFile] Failed to find createComposableLambda", .{});
        checkClearException(env);
        return null;
    };

    const cb_ptr: jlong = @intCast(@intFromPtr(&renderComposable));
    const user_data: jlong = @intCast(@intFromPtr(&state));
    const lambda = env.*.CallStaticObjectMethod.?(env, interop_cls, create_mid, cb_ptr, user_data);
    if (lambda == null) {
        logErrFmt("[renderMessageItemToFile] createComposableLambda returned null", .{});
        checkClearException(env);
        return null;
    }
    defer if (env.*.DeleteLocalRef) |del| del(env, lambda);
    state.self_lambda = lambda;

    // 2. Создаём Density (1.0) и EmptyCoroutineContext
    const density_kt = loadClass(env, loader, "androidx/compose/ui/unit/DensityKt") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, density_kt);
    const density_mid = env.*.GetStaticMethodID.?(
        env,
        density_kt,
        "Density",
        "(FF)Landroidx/compose/ui/unit/Density;",
    ) orelse return null;
    const density_obj = env.*.CallStaticObjectMethod.?(env, density_kt, density_mid, @as(jfloat, 1.0), @as(jfloat, 1.0));
    defer if (env.*.DeleteLocalRef) |del| del(env, density_obj);

    const empty_ctx_cls = loadClass(env, loader, "kotlin/coroutines/EmptyCoroutineContext") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, empty_ctx_cls);
    const empty_ctx_fid = env.*.GetStaticFieldID.?(
        env,
        empty_ctx_cls,
        "INSTANCE",
        "Lkotlin/coroutines/EmptyCoroutineContext;",
    ) orelse return null;
    const empty_ctx = env.*.GetStaticObjectField.?(env, empty_ctx_cls, empty_ctx_fid);
    defer if (env.*.DeleteLocalRef) |del| del(env, empty_ctx);

    // 3. Создаём ImageComposeScene для Headless-рендеринга без открытия окна
    const scene_cls = loadClass(env, loader, "androidx/compose/ui/ImageComposeScene") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, scene_cls);
    const scene_init_mid = env.*.GetMethodID.?(
        env,
        scene_cls,
        "<init>",
        "(IILandroidx/compose/ui/unit/Density;Lkotlin/coroutines/CoroutineContext;Lkotlin/jvm/functions/Function2;)V",
    ) orelse return null;

    var scene_args = [_]jvalue{
        .{ .i = 650 },
        .{ .i = 1500 },
        .{ .l = density_obj },
        .{ .l = empty_ctx },
        .{ .l = lambda },
    };
    const scene = env.*.NewObjectA.?(env, scene_cls, scene_init_mid, &scene_args);
    if (scene == null) {
        logErrFmt("[renderMessageItemToFile] Failed to instantiate ImageComposeScene", .{});
        checkClearException(env);
        return null;
    }
    defer if (env.*.DeleteLocalRef) |del| del(env, scene);

    const close_mid = env.*.GetMethodID.?(env, scene_cls, "close", "()V") orelse return null;
    defer env.*.CallVoidMethod.?(env, scene, close_mid);

    // Вызываем рендеринг кадра Compose в Skia Image
    const render_mid = env.*.GetMethodID.?(env, scene_cls, "render", "(J)Lorg/jetbrains/skia/Image;") orelse return null;
    const full_img = env.*.CallObjectMethod.?(env, scene, render_mid, @as(jlong, 0));
    if (full_img == null) {
        logErrFmt("[renderMessageItemToFile] scene.render returned null", .{});
        checkClearException(env);
        return null;
    }
    defer if (env.*.DeleteLocalRef) |del| del(env, full_img);

    // 4. Сканирование нативной памяти Skia Pixmap для точного поиска границ пузыря сообщения
    const img_cls = loadClass(env, loader, "org/jetbrains/skia/Image") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, img_cls);

    const peek_mid = env.*.GetMethodID.?(env, img_cls, "peekPixels", "()Lorg/jetbrains/skia/Pixmap;");
    const pixmap = if (peek_mid) |pmid| env.*.CallObjectMethod.?(env, full_img, pmid) else null;
    defer if (pixmap != null and env.*.DeleteLocalRef != null) env.*.DeleteLocalRef.?(env, pixmap);

    const chat_bg = getChatBackgroundColor(env);
    var final_bytes_obj: jobject = null;

    if (pixmap != null) {
        const pixmap_cls = loadClass(env, loader, "org/jetbrains/skia/Pixmap");
        if (pixmap_cls) |px_cls| {
            defer if (env.*.DeleteLocalRef) |del| del(env, px_cls);
            const get_addr_mid = env.*.GetMethodID.?(env, px_cls, "getAddr", "()J");
            const get_row_bytes_mid = env.*.GetMethodID.?(env, px_cls, "getRowBytes", "()I");

            if (get_addr_mid != null and get_row_bytes_mid != null) {
                const addr = env.*.CallLongMethod.?(env, pixmap, get_addr_mid.?);
                const row_bytes_val = env.*.CallIntMethod.?(env, pixmap, get_row_bytes_mid.?);
                if (addr != 0 and row_bytes_val > 0) {
                    const w: usize = 650;
                    const h: usize = 1500;
                    const row_bytes: usize = @intCast(row_bytes_val);
                    const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(addr)));

                    var minY: usize = h;
                    var maxY: usize = 0;
                    var found_any = false;

                    var y: usize = 0;
                    while (y < h) : (y += 1) {
                        const row_offset = y * row_bytes;
                        var x: usize = 0;
                        while (x < w) : (x += 1) {
                            if (ptr[row_offset + x * 4 + 3] > 0) {
                                minY = y;
                                found_any = true;
                                break;
                            }
                        }
                        if (found_any) break;
                    }

                    if (found_any) {
                        y = h;
                        while (y > minY) {
                            y -= 1;
                            const row_offset = y * row_bytes;
                            var x: usize = 0;
                            while (x < w) : (x += 1) {
                                if (ptr[row_offset + x * 4 + 3] > 0) {
                                    maxY = y;
                                    break;
                                }
                            }
                            if (maxY != 0) break;
                        }

                        var minX: usize = w;
                        var maxX: usize = 0;
                        y = minY;
                        while (y <= maxY) : (y += 1) {
                            const row_offset = y * row_bytes;
                            var x: usize = 0;
                            while (x < minX) : (x += 1) {
                                if (ptr[row_offset + x * 4 + 3] > 0) {
                                    minX = x;
                                    break;
                                }
                            }
                            x = w;
                            while (x > maxX) {
                                x -= 1;
                                if (ptr[row_offset + x * 4 + 3] > 0) {
                                    maxX = x;
                                    break;
                                }
                            }
                        }

                        if (minX <= maxX and minY <= maxY) {
                            const pad_x: usize = 8;
                            const pad_top: usize = 9;
                            const pad_bottom: usize = 9;

                            const src_l = minX;
                            const src_t = minY;
                            const src_r = maxX + 1;
                            const src_b = maxY + 1;

                            const content_w = src_r - src_l;
                            const content_h = src_b - src_t;

                            const canvas_w = content_w + pad_x * 2;
                            const canvas_h = content_h + pad_top + pad_bottom;

                            final_bytes_obj = renderCroppedBubbleImage(
                                env,
                                loader,
                                full_img,
                                src_l,
                                src_t,
                                src_r,
                                src_b,
                                pad_x,
                                pad_top,
                                canvas_w,
                                canvas_h,
                                chat_bg,
                            );
                        }
                    }
                }
            }
        }
    }

    if (final_bytes_obj == null) {
        final_bytes_obj = encodeImageToPngBytes(env, loader, full_img, 100);
    }

    if (final_bytes_obj == null) {
        logErrFmt("[renderMessageItemToFile] Failed to encode PNG bytes", .{});
        return null;
    }
    defer if (env.*.DeleteLocalRef) |del| del(env, final_bytes_obj);

    const len = env.*.GetArrayLength.?(env, final_bytes_obj);
    if (len <= 0) return null;

    const ulen: usize = @intCast(len);

    if (env.*.GetByteArrayRegion) |getRegion| {
        var stack_buf: [65536]i8 = undefined;
        if (ulen <= stack_buf.len) {
            getRegion(env, final_bytes_obj, 0, len, &stack_buf);
            const raw_ptr: [*]const u8 = @ptrCast(&stack_buf);
            return savePngBytesToFile(api, raw_ptr[0..ulen], out_path_buf);
        }
    }

    if (env.*.GetByteArrayElements) |getElements| {
        const elements = getElements(env, final_bytes_obj, null);
        if (elements != null) {
            defer if (env.*.ReleaseByteArrayElements) |rel| rel(env, final_bytes_obj, elements.?, 0);
            const raw_ptr: [*]const u8 = @ptrCast(elements.?);
            return savePngBytesToFile(api, raw_ptr[0..ulen], out_path_buf);
        }
    }

    logErrFmt("[renderMessageItemToFile] Failed to read jbyteArray", .{});
    return null;
}

// -----------------------------------------------------------------------------
// Перехватчик 1: Клик "Ответить" на сообщении (ChatComposerActions#beginReply)
// -----------------------------------------------------------------------------

fn on_before_begin_reply(param: *HookParam) callconv(.c) void {
    if (!is_active.load(.seq_cst)) return;
    const env = param.getEnv() orelse return;

    const raw_item = param.args[0] orelse return;
    const msg_item = plugin_api.toJniObject(env, raw_item);
    if (msg_item == null) {
        logErrFmt("[beginReply] toJniObject returned null for raw_item", .{});
        return;
    }

    const item_cls = JniAccessor.getObjectClass(env, msg_item) orelse return;
    defer if (env.*.DeleteLocalRef) |del| del(env, item_cls);

    const get_id_mid = env.*.GetMethodID.?(env, item_cls, "getId", "()J") orelse return;
    const msg_id = env.*.CallLongMethod.?(env, msg_item, get_id_mid);
    if (msg_id == 0) return;

    const get_chat_id_mid = env.*.GetMethodID.?(env, item_cls, "getChatId", "()J");
    const chat_id = if (get_chat_id_mid) |mid| env.*.CallLongMethod.?(env, msg_item, mid) else 0;

    quote_mutex.lock();
    pending_quote.msg_id = msg_id;
    pending_quote.chat_id = chat_id;
    pending_quote.captured_path_len = 0;

    if (cached_message_item) |old_ref| {
        if (env.*.DeleteGlobalRef) |del| del(env, old_ref);
    }
    cached_message_item = if (env.*.NewGlobalRef) |new_g| new_g(env, msg_item) else null;
    quote_mutex.unlock();

    logFmt("[beginReply] Intercepted reply to target {d}, pre-rendering bubble...", .{msg_id});

    var render_buf: [512]u8 = undefined;
    if (renderMessageItemToFile(env, msg_item, &render_buf)) |rendered_path| {
        quote_mutex.lock();
        if (pending_quote.msg_id == msg_id) {
            const copy_len = @min(rendered_path.len, pending_quote.captured_path_buf.len - 1);
            @memcpy(pending_quote.captured_path_buf[0..copy_len], rendered_path[0..copy_len]);
            pending_quote.captured_path_buf[copy_len] = 0;
            pending_quote.captured_path_len = copy_len;
            logFmt("[beginReply] Pre-rendered bubble ready: {s}", .{rendered_path});
        }
        quote_mutex.unlock();
    }
}

// -----------------------------------------------------------------------------
// Перехватчик 2: Нажатие кнопки "Отправить" (ChatComposerActions#sendDraft)
// -----------------------------------------------------------------------------

fn on_before_send_draft(param: *HookParam) callconv(.c) void {
    if (!is_active.load(.seq_cst)) return;
    const env = param.getEnv() orelse return;

    const raw_this = param.this_ptr orelse return;
    const this_obj = plugin_api.toJniObject(env, raw_this);
    if (this_obj == null) {
        logErrFmt("[sendDraft] toJniObject returned null for this_obj", .{});
        return;
    }

    const actions_cls = JniAccessor.getObjectClass(env, this_obj) orelse return;
    defer if (env.*.DeleteLocalRef) |del| del(env, actions_cls);

    const entry_fid = env.*.GetFieldID.?(
        env,
        actions_cls,
        "entry",
        "Lcom/mandagram/ui/chat/ComposerDraftEntry;",
    ) orelse {
        checkClearException(env);
        return;
    };

    const entry_obj = env.*.GetObjectField.?(env, this_obj, entry_fid);
    if (entry_obj == null) {
        checkClearException(env);
        return;
    }
    defer if (env.*.DeleteLocalRef) |del| del(env, entry_obj.?);

    const entry_cls = JniAccessor.getObjectClass(env, entry_obj.?) orelse return;
    defer if (env.*.DeleteLocalRef) |del| del(env, entry_cls);

    // Вызываем Kotlin getter `getReply()` для проверки активного ответа
    const reply_mid = env.*.GetMethodID.?(
        env,
        entry_cls,
        "getReply",
        "()Lcom/mandagram/models/MessageItem;",
    ) orelse {
        checkClearException(env);
        return;
    };

    const reply_item = env.*.CallObjectMethod.?(env, entry_obj.?, reply_mid);
    if (reply_item == null) {
        // Пользователь отменил ответ (нажал крестик) — сбрасываем цитату
        quote_mutex.lock();
        pending_quote = .{};
        if (cached_message_item) |gref| {
            if (env.*.DeleteGlobalRef) |del| del(env, gref);
            cached_message_item = null;
        }
        quote_mutex.unlock();
        return;
    }
    defer if (env.*.DeleteLocalRef) |del| del(env, reply_item.?);

    const reply_cls = JniAccessor.getObjectClass(env, reply_item.?) orelse return;
    defer if (env.*.DeleteLocalRef) |del| del(env, reply_cls);

    const get_id_mid = env.*.GetMethodID.?(env, reply_cls, "getId", "()J") orelse return;
    const reply_id = env.*.CallLongMethod.?(env, reply_item.?, get_id_mid);

    quote_mutex.lock();
    const need_render = (pending_quote.msg_id != reply_id or pending_quote.captured_path_len == 0);
    quote_mutex.unlock();

    if (need_render) {
        var render_buf: [512]u8 = undefined;
        if (renderMessageItemToFile(env, reply_item.?, &render_buf)) |rendered_path| {
            quote_mutex.lock();
            pending_quote.msg_id = reply_id;
            const copy_len = @min(rendered_path.len, pending_quote.captured_path_buf.len - 1);
            @memcpy(pending_quote.captured_path_buf[0..copy_len], rendered_path[0..copy_len]);
            pending_quote.captured_path_buf[copy_len] = 0;
            pending_quote.captured_path_len = copy_len;
            logFmt("[sendDraft] Rendered bubble ready: {s}", .{rendered_path});
            quote_mutex.unlock();
        }
    }
}

// -----------------------------------------------------------------------------
// Перехватчик 3: Модификация исходящего сообщения (HookRegistry.filterOutgoingMessage)
// -----------------------------------------------------------------------------

var outgoing_json_buf: [16384]u8 = undefined;

fn on_before_send_message(
    chat_id: i64,
    text_ptr: [*:0]const u8,
    user_data: usize,
) callconv(.c) ?[*:0]const u8 {
    _ = user_data;
    if (!is_active.load(.seq_cst)) return text_ptr;

    quote_mutex.lock();
    defer quote_mutex.unlock();

    // Если нет активной цитаты или чат не совпадает — отправляем обычный текст
    if (pending_quote.msg_id == 0) return text_ptr;
    if (pending_quote.chat_id != 0 and pending_quote.chat_id != chat_id) return text_ptr;
    if (disable_in_discussions and pending_quote.is_discussion) return text_ptr;

    // Проверяем наличие отрендеренной фото-карточки
    if (pending_quote.captured_path_len == 0 and cached_message_item != null) {
        const env = plugin_api.getJniEnv();
        if (env) |e| {
            var render_buf: [512]u8 = undefined;
            if (renderMessageItemToFile(e, cached_message_item.?, &render_buf)) |p| {
                const copy_len = @min(p.len, pending_quote.captured_path_buf.len - 1);
                @memcpy(pending_quote.captured_path_buf[0..copy_len], p[0..copy_len]);
                pending_quote.captured_path_buf[copy_len] = 0;
                pending_quote.captured_path_len = copy_len;
            }
        }
    }

    if (pending_quote.captured_path_len == 0) return text_ptr;

    const photo_path = pending_quote.captured_path_buf[0..pending_quote.captured_path_len];
    const user_caption = std.mem.span(text_ptr);

    var escaped_caption_buf: [4096]u8 = undefined;
    const escaped_caption = escapeJson(user_caption, &escaped_caption_buf);

    var escaped_path_buf: [512]u8 = undefined;
    const escaped_path = escapeJson(photo_path, &escaped_path_buf);

    const json = std.fmt.bufPrintZ(
        &outgoing_json_buf,
        \\{{"@type":"inputMessagePhoto","photo":{{"@type":"inputPhoto","photo":{{"@type":"inputFileLocal","path":"{s}"}}}},"caption":{{"@type":"formattedText","text":"{s}","entities":[]}}}}
    ,
        .{
            escaped_path,
            escaped_caption,
        },
    ) catch return text_ptr;

    logFmt("[send] Transformed outgoing reply into authentic Compose bubble photo quote!", .{});

    // Очищаем состояние после захвата
    pending_quote = .{};
    if (cached_message_item) |gref| {
        const env = plugin_api.getJniEnv();
        if (env) |e| {
            if (e.*.DeleteGlobalRef) |del| del(e, gref);
        }
        cached_message_item = null;
    }

    return json.ptr;
}

// -----------------------------------------------------------------------------
// Пользовательские действия и Жизненный цикл плагина
// -----------------------------------------------------------------------------

fn on_toggle_setting_click(chat_id: i64, user_data: usize) callconv(.c) void {
    _ = chat_id;
    _ = user_data;
    disable_in_discussions = !disable_in_discussions;
    saveSettings();
    if (disable_in_discussions) {
        logFmt("[Settings] Quote in discussions is now DISABLED", .{});
    } else {
        logFmt("[Settings] Quote in discussions is now ENABLED", .{});
    }
}

/// Точка входа инициализации плагина MandaGram (mandagram_plugin_init)
pub export fn mandagram_plugin_init(api: *const PluginApi) callconv(.c) bool {
    global_api = api;
    is_active.store(true, .seq_cst);
    api.log_info("KvoteReply", "Initializing KvoteReply plugin v2.0.0 (Compose Headless Skia)");

    loadSettings(api);

    const env = plugin_api.getJniEnv();
    if (env) |e| {
        _ = plugin_api.getAppClassLoader(e);
    }

    // 1. Хук на выбор сообщения для ответа в UI (фоновый пре-рендеринг карточки)
    _ = api.register_hook(
        "com/mandagram/ui/chat/ChatComposerActions",
        "beginReply",
        "(Lcom/mandagram/models/MessageItem;)V",
        on_before_begin_reply,
        null,
    );

    // 2. Хук на нажатие кнопки отправки в поле ввода
    _ = api.register_hook(
        "com/mandagram/ui/chat/ChatComposerActions",
        "sendDraft",
        "()V",
        on_before_send_draft,
        null,
    );

    // 3. Хук исходящих сообщений через HookRegistry
    if (api.register_message_send_hook) |reg_send| {
        _ = reg_send(on_before_send_message, null, 0);
    }

    // 4. Регистрация пункта в контекстном меню чата
    if (api.register_chat_action) |reg_action| {
        _ = reg_action("toggle_discussions", "KvoteReply: Toggle Discussion Quotes", on_toggle_setting_click, 0);
    }

    return true;
}

/// Точка входа выгрузки плагина (mandagram_plugin_unload)
pub export fn mandagram_plugin_unload() callconv(.c) void {
    is_active.store(false, .seq_cst);
    if (global_api) |api| {
        api.log_info("KvoteReply", "Unloading KvoteReply plugin v2.0.0");
    }

    quote_mutex.lock();
    pending_quote = .{};
    if (cached_message_item) |gref| {
        const env = plugin_api.getJniEnv();
        if (env) |e| {
            if (e.*.DeleteGlobalRef) |del| del(e, gref);
        }
        cached_message_item = null;
    }
    quote_mutex.unlock();
}

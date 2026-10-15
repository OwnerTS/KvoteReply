//! ============================================================================
//! KvoteReply v2.0.0 — Pure FFI Native Quote Renderer Plugin for MandaGram
//!
//! Данный плагин перехватывает исходящие ответы на сообщения в Telegram и
//! превращает их в фото-цитаты с аутентичным внешним видом карточек сообщений:
//! - Полная совместимость с новой чистой FFI плагин-системой MandaGram (53 слота,
//!   40-байтный HookParam layout, zero JNI overhead).
//! - Автономный нативный рендерер карточек цитат с типографикой (ASCII + Cyrillic),
//!   аватаром с инициалами автора и цветовыми акцентами.
//! - Встроенный PNG-энкодер со сжатием Deflate без внешних зависимостей.
//! - Интеграция с TDLib через execute_tdlib_query для отправки InputMessagePhoto
//!   и InputTextQuote.
//! ============================================================================

const std = @import("std");
const plugin_api = @import("include/mandagram_plugin.zig");
const renderer = @import("renderer.zig");

// Импорт базовых типов Plugin API
const HookParam = plugin_api.HookParam;
const PluginApi = plugin_api.PluginApi;
const jobject = plugin_api.jobject;

// -----------------------------------------------------------------------------
// Глобальное состояние плагина
// -----------------------------------------------------------------------------

/// Указатель на интерфейс ядра MandaGram Plugin API
var global_api: ?*const PluginApi = null;

/// Атомарный флаг активности плагина
var is_active = std.atomic.Value(bool).init(true);

/// Пользовательская настройка: отключать ли авто-фотоцитаты в топиках форумов и обсуждениях
var disable_in_discussions: bool = false;

/// ID последнего отправленного через плагин сообщения для предотвращения двойной отправки
var last_intercepted_reply_id: i64 = 0;

/// Метаданные плагина, экспортируемые ядру MandaGram
pub const METADATA = plugin_api.PluginMetadata{
    .name = "KvoteReply",
    .version = "2.0.0",
    .author = "OwnerTS",
    .description = "Pixel-perfect authentic message bubble photo quote replies for MandaGram (Pure FFI, Pure Zig).",
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
    sender_name: [256]u8 = [_]u8{0} ** 256,
    sender_name_len: usize = 0,
    text: [4096]u8 = [_]u8{0} ** 4096,
    text_len: usize = 0,
    time: [64]u8 = [_]u8{0} ** 64,
    time_len: usize = 0,
    initials: [32]u8 = [_]u8{0} ** 32,
    initials_len: usize = 0,
    is_outgoing: bool = false,
    captured_path_buf: [512]u8 = [_]u8{0} ** 512,
    captured_path_len: usize = 0,
};

/// Мьютекс для защиты конкурентного доступа к состоянию ответа
var quote_mutex = std.Thread.Mutex{};

/// Активное состояние ответа
var pending_quote = PendingQuoteState{};

// -----------------------------------------------------------------------------
// Вспомогательные функции логирования и строковых операций
// -----------------------------------------------------------------------------

pub fn logFmt(comptime fmt: []const u8, args: anytype) void {
    const api = global_api orelse return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    api.log_info("KvoteReply", msg);
}

pub fn logErrFmt(comptime fmt: []const u8, args: anytype) void {
    const api = global_api orelse return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    api.log_error("KvoteReply", msg);
}

/// Безопасно обрезает строку UTF-8 по границе кодовых точек (символов)
pub fn utf8Truncate(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var len = max_bytes;
    while (len > 0 and (text[len] & 0xC0) == 0x80) {
        len -= 1;
    }
    return text[0..len];
}

/// Экранирует строку для безопасной вставки в JSON TDLib
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

// -----------------------------------------------------------------------------
// Рендеринг цитаты в PNG-файл
// -----------------------------------------------------------------------------

fn preRenderQuote(api: *const PluginApi, state: *PendingQuoteState) ?[:0]const u8 {
    var dir_buf: [512]u8 = undefined;
    const cache_dir = getQuotesCacheDir(api, &dir_buf) orelse return null;
    cleanupCacheDir(cache_dir, 8);

    const name_slice = state.sender_name[0..state.sender_name_len];
    const text_slice = state.text[0..state.text_len];
    const time_slice = state.time[0..state.time_len];
    const init_slice = state.initials[0..state.initials_len];

    var path_buf: [512]u8 = undefined;
    if (renderer.saveQuoteCardToFile(
        std.heap.page_allocator,
        cache_dir,
        name_slice,
        text_slice,
        time_slice,
        init_slice,
        state.is_outgoing,
        &path_buf,
    )) |saved_path| {
        const copy_len = @min(saved_path.len, state.captured_path_buf.len - 1);
        @memcpy(state.captured_path_buf[0..copy_len], saved_path[0..copy_len]);
        state.captured_path_buf[copy_len] = 0;
        state.captured_path_len = copy_len;
        return state.captured_path_buf[0..copy_len :0];
    }
    return null;
}

// -----------------------------------------------------------------------------
// Перехватчик 1: Клик "Ответить" на сообщении (ChatComposerActions#beginReply)
// -----------------------------------------------------------------------------

fn on_before_begin_reply(param: *HookParam) callconv(.c) void {
    if (!is_active.load(.seq_cst)) return;
    const api = global_api orelse return;

    if (param.args_count < 1) return;
    const msg_item = param.args[0] orelse return;

    const get_long = api.get_long_field orelse return;
    const get_obj = api.get_object_field orelse return;
    const get_str = api.get_string_utf orelse return;
    const get_bool = api.get_bool_field orelse return;

    const msg_id = get_long(msg_item, "id");
    if (msg_id == 0) return;

    quote_mutex.lock();
    pending_quote.msg_id = msg_id;
    pending_quote.chat_id = get_long(msg_item, "chatId");
    pending_quote.is_outgoing = get_bool(msg_item, "isOutgoing");

    // Check if forum topic / discussion
    const topic_obj = get_obj(msg_item, "forumTopicId");
    pending_quote.is_discussion = (topic_obj != null);

    // Extract Sender Name
    if (get_obj(msg_item, "senderName")) |jname| {
        const len = get_str(jname, &pending_quote.sender_name, pending_quote.sender_name.len);
        pending_quote.sender_name_len = if (len > 0) @intCast(len) else 0;
    } else {
        pending_quote.sender_name_len = 0;
    }

    // Extract Message Text (fallback to documentFileName)
    var text_len: i32 = 0;
    if (get_obj(msg_item, "text")) |jtext| {
        text_len = get_str(jtext, &pending_quote.text, pending_quote.text.len);
    }
    if (text_len <= 0) {
        if (get_obj(msg_item, "documentFileName")) |jdoc| {
            text_len = get_str(jdoc, &pending_quote.text, pending_quote.text.len);
        }
    }
    pending_quote.text_len = if (text_len > 0) @intCast(text_len) else 0;

    // Extract Formatted Time
    if (get_obj(msg_item, "formattedTime")) |jtime| {
        const len = get_str(jtime, &pending_quote.time, pending_quote.time.len);
        pending_quote.time_len = if (len > 0) @intCast(len) else 0;
    } else {
        pending_quote.time_len = 0;
    }

    // Extract Sender Initials
    if (get_obj(msg_item, "senderInitials")) |jinit| {
        const len = get_str(jinit, &pending_quote.initials, pending_quote.initials.len);
        pending_quote.initials_len = if (len > 0) @intCast(len) else 0;
    } else {
        pending_quote.initials_len = 0;
    }

    pending_quote.captured_path_len = 0;

    // Trigger pre-rendering of quote bubble image in background
    if (preRenderQuote(api, &pending_quote)) |rendered_path| {
        logFmt("[beginReply] Pre-rendered quote card ready: {s}", .{rendered_path});
    }
    quote_mutex.unlock();
}

// -----------------------------------------------------------------------------
// Перехватчик 2: Нажатие кнопки "Отправить" (ChatComposerActions#sendDraft)
// -----------------------------------------------------------------------------

fn on_before_send_draft(param: *HookParam) callconv(.c) void {
    if (!is_active.load(.seq_cst)) return;
    const api = global_api orelse return;

    const this_obj = param.this_ptr orelse return;
    const get_obj = api.get_object_field orelse return;
    const get_long = api.get_long_field orelse return;

    const entry_obj = get_obj(this_obj, "entry") orelse return;
    const reply_item = get_obj(entry_obj, "reply");
    if (reply_item == null) {
        quote_mutex.lock();
        pending_quote = .{};
        quote_mutex.unlock();
        return;
    }
    const reply_id = get_long(reply_item.?, "id");
    if (reply_id == 0) {
        quote_mutex.lock();
        pending_quote = .{};
        quote_mutex.unlock();
        return;
    }

    quote_mutex.lock();
    const need_render = (pending_quote.msg_id != reply_id or pending_quote.captured_path_len == 0);
    if (need_render) {
        pending_quote.msg_id = reply_id;
        _ = preRenderQuote(api, &pending_quote);
    }
    quote_mutex.unlock();
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
    if (pending_quote.captured_path_len == 0) {
        if (global_api) |api| {
            if (preRenderQuote(api, &pending_quote)) |p| {
                const copy_len = @min(p.len, pending_quote.captured_path_buf.len);
                @memcpy(pending_quote.captured_path_buf[0..copy_len], p[0..copy_len]);
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

    logFmt("[send] Transformed outgoing reply into authentic photo quote card!", .{});

    // Сбрасываем pending_quote после успешного захвата
    pending_quote = .{};

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
    api.log_info("KvoteReply", "Initializing KvoteReply plugin v2.0.0 (Pure FFI, Pure Zig)");

    loadSettings(api);

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
    last_intercepted_reply_id = 0;
    quote_mutex.unlock();
}

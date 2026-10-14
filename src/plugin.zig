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

/// Указатель на интерфейс ядра MandaGram Plugin API (логирование, пути к кэшу, хуки)
var global_api: ?*const PluginApi = null;

/// Кэшированный указатель на виртуальную машину Java (JavaVM).
/// Сохраняется при первом вызове любого JNI-хука. Необходим для того, чтобы в функции
/// mandagram_plugin_unload() (где JNIEnv не передаётся напрямую) получить JNIEnv
/// текущего потока и безопасно удалить глобальные ссылки (DeleteGlobalRef).
var global_jvm: ?*JavaVM = null;

/// Атомарный флаг активности плагина.
/// Позволяет мгновенно отключить всю логику плагина при выгрузке без race conditions.
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

/// Состояние подготавливаемой цитаты.
/// Хранит данные между хуком клика "Ответить" и фактической отправкой сообщения.
const PendingQuoteState = struct {
    /// ID целевого сообщения в Telegram (TDLib messageId)
    msg_id: i64 = 0,
    /// Буфер для текста цитируемого сообщения (используется для формирования TDLib InputTextQuote)
    text_buf: [4096]u8 = [_]u8{0} ** 4096,
    text_len: usize = 0,
    /// Абсолютный путь к предварительно сгенерированному PNG-файлу с изображением пузыря
    captured_path_buf: [512]u8 = [_]u8{0} ** 512,
    captured_path_len: usize = 0,
};

/// Мьютекс для защиты конкурентного доступа к состоянию ответа.
/// События интерфейса (AWT-EventQueue) и сетевые колбэки (TDLib) могут вызываться в разных потоках.
var quote_mutex = std.Thread.Mutex{};

/// Активное состояние ответа
var pending_quote = PendingQuoteState{};

/// Кэшированная глобальная JNI-ссылка на объект MessageItem.
/// Защищает Kotlin-объект сообщения от сбора мусора (GC) между этапом клика и отправкой.
var cached_message_item: ?jobject = null;

// -----------------------------------------------------------------------------
// Вспомогательные функции логирования и проверки исключений JNI
// -----------------------------------------------------------------------------

/// Форматированный вывод информационного лога в консоль MandaGram
fn logFmt(comptime fmt: []const u8, args: anytype) void {
    const api = global_api orelse return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    api.log_info("KvoteReply", msg);
}

/// Форматированный вывод лога ошибки в консоль MandaGram
fn logErrFmt(comptime fmt: []const u8, args: anytype) void {
    const api = global_api orelse return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    api.log_error("KvoteReply", msg);
}

/// Проверяет, возникло ли в JVM исключение (exception).
/// Если возникло — печатает stack trace в консоль и очищает флаг исключения (ExceptionClear),
/// чтобы последующие JNI-вызовы в этом потоке не падали аварийно.
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

/// Кэширует JavaVM из переданного окружения JNIEnv, если она ещё не была сохранена.
/// Позволяет в любой момент (включая mandagram_plugin_unload) восстановить JNIEnv.
fn ensureJvmCached(env: *JNIEnv) void {
    if (global_jvm == null) {
        if (env.*.GetJavaVM) |get_vm| {
            _ = get_vm(env, &global_jvm);
        }
    }
}

/// Безопасно обрезает строку UTF-8 по границе кодовых точек (символов),
/// чтобы не расщепить многобайтовый UTF-8 символ или эмодзи.
pub fn utf8Truncate(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var len = max_bytes;
    while (len > 0 and (text[len] & 0xC0) == 0x80) {
        len -= 1;
    }
    return text[0..len];
}

// -----------------------------------------------------------------------------
// Сохранение и загрузка настроек плагина
// -----------------------------------------------------------------------------

/// Загружает настройки плагина из файла <storage_dir>/settings.txt
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

/// Сохраняет настройки плагина в файл <storage_dir>/settings.txt
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
// Конструкторы структур данных TDLib (it.tdlight.jni.TdApi)
// -----------------------------------------------------------------------------

/// Создаёт TDLib-объект FormattedText с пустым массивом TextEntity
fn createFormattedText(env: *JNIEnv, text_slice: []const u8) jobject {
    const fmt_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$FormattedText") orelse return null;
    const text_entity_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$TextEntity") orelse return null;

    const safe_slice = utf8Truncate(text_slice, 1024);
    var z_buf: [1025]u8 = undefined;
    @memcpy(z_buf[0..safe_slice.len], safe_slice);
    z_buf[safe_slice.len] = 0;

    const j_str = JniAccessor.newStringUtf(env, z_buf[0..safe_slice.len :0]) orelse return null;

    const empty_entities = if (env.*.NewObjectArray) |new_arr|
        new_arr(env, 0, text_entity_cls, null)
    else
        return null;

    const fmt_ctor = env.*.GetMethodID.?(
        env,
        fmt_cls,
        "<init>",
        "(Ljava/lang/String;[Lit/tdlight/jni/TdApi$TextEntity;)V",
    ) orelse return null;

    const fmt_args = [_]jvalue{
        .{ .l = j_str },
        .{ .l = empty_entities },
    };

    return if (env.*.NewObjectA) |new_a|
        new_a(env, fmt_cls, fmt_ctor, &fmt_args)
    else
        null;
}

/// Проверяет, валиден ли FormattedText для создания цитаты (не пустой и до 1024 символов)
fn isFormattedTextValidForQuote(env: *JNIEnv, fmt_obj: jobject) bool {
    if (fmt_obj == null) return false;
    const fmt_cls = JniAccessor.getObjectClass(env, fmt_obj) orelse return false;
    const text_fid = env.*.GetFieldID.?(env, fmt_cls, "text", "Ljava/lang/String;");
    if (text_fid == null) {
        checkClearException(env);
        return false;
    }
    const j_str = env.*.GetObjectField.?(env, fmt_obj, text_fid.?);
    if (j_str == null) return false;
    const str_cls = JniAccessor.getObjectClass(env, j_str) orelse return false;
    const len_mid = env.*.GetMethodID.?(env, str_cls, "length", "()I");
    if (len_mid == null) {
        checkClearException(env);
        return false;
    }
    const len = env.*.CallIntMethod.?(env, j_str, len_mid.?);
    return (len > 0 and len <= 1024);
}

/// Извлекает строковое значение из FormattedText в предоставленный буфер
fn getFormattedTextString(env: *JNIEnv, fmt_obj: jobject, out_buf: []u8) ?[]const u8 {
    if (fmt_obj == null) return null;
    const fmt_cls = JniAccessor.getObjectClass(env, fmt_obj) orelse return null;
    const text_fid = env.*.GetFieldID.?(env, fmt_cls, "text", "Ljava/lang/String;");
    if (text_fid == null) {
        checkClearException(env);
        return null;
    }
    const j_str = env.*.GetObjectField.?(env, fmt_obj, text_fid.?);
    if (j_str == null) return null;

    const chars = JniAccessor.getStringUtfChars(env, j_str) orelse return null;
    defer JniAccessor.releaseStringUtfChars(env, j_str, chars);
    const span = std.mem.span(chars);
    const safe_slice = utf8Truncate(span, out_buf.len);
    @memcpy(out_buf[0..safe_slice.len], safe_slice);
    return out_buf[0..safe_slice.len];
}

/// Создаёт TDLib-объект InputTextQuote для прикрепления блока цитаты к сообщению
fn createInputTextQuote(env: *JNIEnv, fmt_obj: jobject) jobject {
    const q_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputTextQuote") orelse return null;
    const q_ctor = env.*.GetMethodID.?(
        env,
        q_cls,
        "<init>",
        "(Lit/tdlight/jni/TdApi$FormattedText;I)V",
    ) orelse return null;
    const q_args = [_]jvalue{
        .{ .l = fmt_obj },
        .{ .i = 0 },
    };
    return if (env.*.NewObjectA) |new_a|
        new_a(env, q_cls, q_ctor, &q_args)
    else
        null;
}

/// Создаёт TDLib-объект InputMessageReplyToMessage с цитатой
fn createInputMessageReplyToMessage(env: *JNIEnv, msg_id: i64, quote_obj: jobject) jobject {
    const reply_msg_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputMessageReplyToMessage") orelse return null;
    const reply_ctor = env.*.GetMethodID.?(
        env,
        reply_msg_cls,
        "<init>",
        "(JLit/tdlight/jni/TdApi$InputTextQuote;ILjava/lang/String;)V",
    ) orelse return null;

    const empty_poll_id = JniAccessor.newStringUtf(env, "");
    const reply_args = [_]jvalue{
        .{ .j = msg_id },
        .{ .l = quote_obj },
        .{ .i = 0 },
        .{ .l = empty_poll_id },
    };

    return if (env.*.NewObjectA) |new_a|
        new_a(env, reply_msg_cls, reply_ctor, &reply_args)
    else
        null;
}

/// Создаёт TDLib-объект InputMessagePhoto для отправки локального PNG файла
fn createInputMessagePhoto(env: *JNIEnv, photo_path_z: [*:0]const u8, caption_obj: jobject) jobject {
    // 1. TdApi$InputFileLocal(path)
    const file_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputFileLocal") orelse return null;
    const file_ctor = env.*.GetMethodID.?(env, file_cls, "<init>", "(Ljava/lang/String;)V") orelse return null;

    const j_path_str = JniAccessor.newStringUtf(env, photo_path_z) orelse return null;
    const file_args = [_]jvalue{.{ .l = j_path_str }};
    const input_file = if (env.*.NewObjectA) |new_a|
        new_a(env, file_cls, file_ctor, &file_args)
    else
        return null;
    if (input_file == null) return null;

    // 2. TdApi$InputPhoto()
    const photo_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputPhoto") orelse return null;
    const photo_ctor = env.*.GetMethodID.?(env, photo_cls, "<init>", "()V") orelse return null;
    const empty_args = [_]jvalue{};
    const input_photo = if (env.*.NewObjectA) |new_a|
        new_a(env, photo_cls, photo_ctor, &empty_args)
    else
        return null;
    if (input_photo == null) return null;

    JniAccessor.setObjectField(env, input_photo, "photo", "Lit/tdlight/jni/TdApi$InputFile;", input_file);

    // 3. TdApi$InputMessagePhoto()
    const msg_photo_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputMessagePhoto") orelse return null;
    const msg_photo_ctor = env.*.GetMethodID.?(env, msg_photo_cls, "<init>", "()V") orelse return null;
    const msg_photo = if (env.*.NewObjectA) |new_a|
        new_a(env, msg_photo_cls, msg_photo_ctor, &empty_args)
    else
        return null;
    if (msg_photo == null) return null;

    JniAccessor.setObjectField(env, msg_photo, "photo", "Lit/tdlight/jni/TdApi$InputPhoto;", input_photo);
    const final_caption: jobject = if (caption_obj != null) caption_obj else createFormattedText(env, "");
    if (final_caption != null) {
        JniAccessor.setObjectField(env, msg_photo, "caption", "Lit/tdlight/jni/TdApi$FormattedText;", final_caption);
    }

    return msg_photo;
}

/// Получает оригинальный FormattedText сообщения через ConversationController
fn getRawFormattedText(env: *JNIEnv, chat_id: i64, msg_id: i64) jobject {
    const conv_ctrl_cls = JniAccessor.findClass(env, "com/mandagram/ui/conversation/ConversationController") orelse return null;
    const inst_fid = env.*.GetStaticFieldID.?(
        env,
        conv_ctrl_cls,
        "INSTANCE",
        "Lcom/mandagram/ui/conversation/ConversationController;",
    ) orelse return null;
    const conv_ctrl = env.*.GetStaticObjectField.?(env, conv_ctrl_cls, inst_fid) orelse return null;

    const get_raw_mid = env.*.GetMethodID.?(
        env,
        conv_ctrl_cls,
        "getRawMessage",
        "(JJ)Lit/tdlight/jni/TdApi$Message;",
    ) orelse return null;

    const raw_msg = env.*.CallObjectMethod.?(env, conv_ctrl, get_raw_mid, msg_id, chat_id);
    if (raw_msg == null) return null;

    const raw_cls = JniAccessor.getObjectClass(env, raw_msg) orelse return null;
    const content_fid = env.*.GetFieldID.?(
        env,
        raw_cls,
        "content",
        "Lit/tdlight/jni/TdApi$MessageContent;",
    ) orelse {
        checkClearException(env);
        return null;
    };

    const content_obj = env.*.GetObjectField.?(env, raw_msg, content_fid);
    if (content_obj == null) return null;
    const content_cls = JniAccessor.getObjectClass(env, content_obj) orelse return null;

    const msg_text_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$MessageText");
    if (msg_text_cls != null and env.*.IsInstanceOf.?(env, content_obj, msg_text_cls.?) != 0) {
        const text_fid = env.*.GetFieldID.?(env, content_cls, "text", "Lit/tdlight/jni/TdApi$FormattedText;");
        if (text_fid != null) {
            return env.*.GetObjectField.?(env, content_obj, text_fid.?);
        }
    }

    const caption_fid = env.*.GetFieldID.?(env, content_cls, "caption", "Lit/tdlight/jni/TdApi$FormattedText;");
    if (caption_fid != null) {
        return env.*.GetObjectField.?(env, content_obj, caption_fid.?);
    }
    checkClearException(env);
    return null;
}

/// Проверяет, является ли чат топиком форума или веткой комментариев канала
fn isDiscussionGroup(env: *JNIEnv, chat_id: i64) bool {
    const service_cls = JniAccessor.findClass(env, "com/mandagram/network/TelegramService") orelse return false;
    const inst_fid = env.*.GetStaticFieldID.?(
        env,
        service_cls,
        "INSTANCE",
        "Lcom/mandagram/network/TelegramService;",
    ) orelse return false;
    const service_inst = env.*.GetStaticObjectField.?(env, service_cls, inst_fid) orelse return false;

    const get_summary_mid = env.*.GetMethodID.?(
        env,
        service_cls,
        "getChatSummary",
        "(J)Lcom/mandagram/models/ChatSummary;",
    ) orelse {
        checkClearException(env);
        return false;
    };

    const summary = env.*.CallObjectMethod.?(env, service_inst, get_summary_mid, chat_id);
    if (summary == null) return false;

    const summary_cls = JniAccessor.getObjectClass(env, summary) orelse return false;
    const is_replies_mid = env.*.GetMethodID.?(env, summary_cls, "isReplies", "()Z");
    if (is_replies_mid) |mid| {
        if (env.*.CallBooleanMethod.?(env, summary, mid) != 0) return true;
    } else {
        checkClearException(env);
    }

    const is_forum_mid = env.*.GetMethodID.?(env, summary_cls, "isForum", "()Z");
    if (is_forum_mid) |mid| {
        if (env.*.CallBooleanMethod.?(env, summary, mid) != 0) return true;
    } else {
        checkClearException(env);
    }

    return false;
}

// -----------------------------------------------------------------------------
// Вспомогательные функции загрузки классов Java / Kotlin
// -----------------------------------------------------------------------------

/// Извлекает ClassLoader из переданного объекта Java
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

/// Загружает класс через JNI FindClass или явно через переданный ClassLoader
fn loadClass(env: *JNIEnv, loader: jobject, name_slashed: [*:0]const u8) jclass {
    if (env.*.FindClass) |f| {
        const cls = f(env, name_slashed);
        if (cls != null) return cls;
        checkClearException(env);
    }
    const ldr = loader orelse return null;
    var dotted_buf: [256]u8 = undefined;
    var i: usize = 0;
    while (name_slashed[i] != 0 and i < dotted_buf.len - 1) : (i += 1) {
        dotted_buf[i] = if (name_slashed[i] == '/') '.' else name_slashed[i];
    }
    dotted_buf[i] = 0;

    const loader_cls = JniAccessor.getObjectClass(env, ldr) orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, loader_cls);
    const mid = env.*.GetMethodID.?(env, loader_cls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;") orelse {
        checkClearException(env);
        return null;
    };
    const jname = env.*.NewStringUTF.?(env, dotted_buf[0..i :0]);
    defer if (env.*.DeleteLocalRef) |del| del(env, jname);
    const res = env.*.CallObjectMethod.?(env, ldr, mid, jname);
    checkClearException(env);
    return res;
}

// -----------------------------------------------------------------------------
// Рендерер Compose: Отрисовка MandaGramTheme -> MessageBubble
// -----------------------------------------------------------------------------

/// Состояние для двупроходной отрисовки Composable-дерева:
/// Проход 0: Оборачивание в MandaGramTheme { ... }
/// Проход 1: Отрисовка оригинального MessageBubble(...)
const RenderState = struct {
    msg_item: jobject = null,
    is_group: bool = false,
    is_channel: bool = false,
    pass: u32 = 0,
    self_lambda: jobject = null,
};

/// Нативная C-функция, вызываемая рантаймом Compose через ComposeInterop bridge
fn renderComposable(env: *JNIEnv, composer: jobject, user_data: usize) callconv(.c) void {
    const state: *RenderState = @ptrFromInt(user_data);
    if (state.pass == 0) {
        // Проход 0: Запуск темы оформления MandaGramTheme, чтобы MessageBubble
        // получил правильную цветовую палитру (MaterialTheme), типографику и форму пузыря
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

        env.*.CallStaticVoidMethod.?(env, theme_kt, theme_mid, state.self_lambda, composer, @as(jint, 0));
        checkClearException(env);
    } else {
        // Проход 1: Отрисовка оригинального MessageBubble из MandaGram
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
            composer,
            @as(jint, 54), // $changed
            @as(jint, 0), // $changed1
            @as(jint, 0x7FC0), // $default
        );
        checkClearException(env);
    }
}

/// Определяет текущий цвет фона чата в ARGB на основе настроек ThemeManager
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

    // Проверяем выбранный MonetSeed: для PISTACHIO используется специфический оттенок
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

// -----------------------------------------------------------------------------
// Кэширование файлов на диске
// -----------------------------------------------------------------------------

pub const CacheFileEntry = struct {
    name: [128]u8,
    name_len: usize,
    mtime: i128,
};

/// Удаляет устаревшие файлы цитат, оставляя не более max_files самых свежих
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

/// Получает путь к директории кэша для сгенерированных цитат
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

/// Сохраняет сжатые байты PNG во временный файл в директории кэша
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
// Вспомогательные функции для работы со Skia (org.jetbrains.skia)
// Разделяют глубокую вложенность JNI-вызовов на плоские, читаемые операции.
// -----------------------------------------------------------------------------

/// Создаёт растровый Skia Surface заданного размера (width x height) с форматом N32Premul
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

/// Получает объект Canvas из Skia Surface
fn getSurfaceCanvas(env: *JNIEnv, loader: jobject, surface: jobject) jobject {
    const s_cls = loadClass(env, loader, "org/jetbrains/skia/Surface") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, s_cls);

    const get_canvas_mid = env.*.GetMethodID.?(env, s_cls, "getCanvas", "()Lorg/jetbrains/skia/Canvas;") orelse return null;
    return env.*.CallObjectMethod.?(env, surface, get_canvas_mid);
}

/// Заливает Canvas заданным цветом фона.
/// ВАЖНО: В библиотеке Skiko метод Canvas.clear(int) возвращает сам Canvas (цепочечный вызов),
/// поэтому его JNI сигнатура: (I)Lorg/jetbrains/skia/Canvas;
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

/// Создаёт Skia Rect по 4 координатам (Left, Top, Right, Bottom)
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

/// Создаёт Skia Rect по ширине и высоте (от точки 0,0 до w,h)
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

/// Отрисовывает часть исходного Skia Image в целевой холст (drawImageRect)
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

/// Создаёт снимок (Image Snapshot) с отрисованного Surface
fn makeSurfaceSnapshot(env: *JNIEnv, loader: jobject, surface: jobject) jobject {
    const s_cls = loadClass(env, loader, "org/jetbrains/skia/Surface") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, s_cls);

    const make_snapshot_mid = env.*.GetMethodID.?(env, s_cls, "makeImageSnapshot", "()Lorg/jetbrains/skia/Image;") orelse return null;
    return env.*.CallObjectMethod.?(env, surface, make_snapshot_mid);
}

/// Кодирует Skia Image в формат PNG и возвращает массив jbyteArray
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

/// Создаёт новый холст с размерами обрезанного пузыря, заливает его цветом фона чата,
/// копирует туда пузырь и кодирует в PNG.
fn renderCroppedBubbleImage(
    env: *JNIEnv,
    loader: jobject,
    full_img: jobject,
    l: usize,
    t: usize,
    r: usize,
    b: usize,
    w: usize,
    h: usize,
    bg_color: i32,
) jobject {
    // 1. Создаём растровый Surface целевого размера
    const surface = createRasterSurface(env, loader, w, h) orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, surface);

    // 2. Получаем Canvas
    const canvas = getSurfaceCanvas(env, loader, surface) orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, canvas);

    // 3. Заливаем фон холста цветом текущей темы (чтобы не было белых рамок)
    clearCanvas(env, loader, canvas, bg_color);

    // 4. Формируем прямоугольники источника и назначения
    const src_rect = makeRectLTRB(env, loader, @floatFromInt(l), @floatFromInt(t), @floatFromInt(r), @floatFromInt(b)) orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, src_rect);

    const dst_rect = makeRectWH(env, loader, @floatFromInt(w), @floatFromInt(h)) orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, dst_rect);

    // 5. Отрисовываем фрагмент изображения в новый холст
    drawImageRect(env, loader, canvas, full_img, src_rect, dst_rect);

    // 6. Снимаем готовое изображение
    const snapshot = makeSurfaceSnapshot(env, loader, surface) orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, snapshot);

    // 7. Сжимаем в PNG
    return encodeImageToPngBytes(env, loader, snapshot, 100);
}

// -----------------------------------------------------------------------------
// Рендеринг MessageItem в PNG файл на диске
// -----------------------------------------------------------------------------

fn renderMessageItemToFile(env: *JNIEnv, msg_item: jobject, out_path_buf: []u8) ?[:0]const u8 {
    const api = global_api orelse return null;
    if (msg_item == null) return null;

    // PushLocalFrame гарантирует, что все локальные JNI-ссылки внутри этой функции
    // будут автоматически освобождены при выходе, предотвращая переполнение JNI-таблицы.
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

    // 1. Создаём Composable-лямбду через встроенный мост ComposeInterop ядра MandaGram
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

    // 2. Создаём Density (масштабирование интерфейса 1.0) и EmptyCoroutineContext
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

    // 3. Создаём ImageComposeScene для Headless-рендеринга без открытия окна ОС
    const scene_cls = loadClass(env, loader, "androidx/compose/ui/ImageComposeScene") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, scene_cls);
    const scene_init_mid = env.*.GetMethodID.?(
        env,
        scene_cls,
        "<init>",
        "(IILandroidx/compose/ui/unit/Density;Lkotlin/coroutines/CoroutineContext;Lkotlin/jvm/functions/Function2;)V",
    ) orelse return null;

    var scene_args = [_]jvalue{
        .{ .i = 650 }, // Максимальная ширина холста (хватает для любого десктопного сообщения)
        .{ .i = 1500 }, // Максимальная высота холста
        .{ .l = density_obj },
        .{ .l = empty_ctx },
        .{ .l = lambda },
    };
    const scene = env.*.NewObjectA.?(
        env,
        scene_cls,
        scene_init_mid,
        &scene_args,
    );
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

    // 4. Сканирование нативной памяти Skia Pixmap для поиска границ пузыря сообщения.
    // Получаем прямой указатель на байты пикселей в нативной куче (без копирования в Java-массив).
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

                    // Поиск первой непустой строки (minY) сверху вниз
                    var minY: usize = h;
                    var maxY: usize = 0;
                    var found_any = false;

                    var y: usize = 0;
                    while (y < h) : (y += 1) {
                        const row_offset = y * row_bytes;
                        var x: usize = 0;
                        while (x < w) : (x += 1) {
                            if (ptr[row_offset + x * 4 + 3] > 0) { // Проверка альфа-канала (Alpha > 0)
                                minY = y;
                                found_any = true;
                                break;
                            }
                        }
                        if (found_any) break;
                    }

                    if (found_any) {
                        // Поиск последней непустой строки (maxY) снизу вверх
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

                        // Поиск горизонтальных границ (minX и maxX)
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
                            // Добавляем отступ 6px вокруг пузыря для естественного вида
                            const pad: usize = 6;
                            const min_x_padded = if (minX >= pad) minX - pad else 0;
                            const min_y_padded = if (minY >= pad) minY - pad else 0;
                            const max_x_padded = @min(w, maxX + 1 + pad);
                            const max_y_padded = @min(h, maxY + 1 + pad);
                            const crop_w = max_x_padded - min_x_padded;
                            const crop_h = max_y_padded - min_y_padded;

                            // Отрисовка обрезанного изображения в новый Canvas нужного цвета фона
                            final_bytes_obj = renderCroppedBubbleImage(
                                env,
                                loader,
                                full_img,
                                min_x_padded,
                                min_y_padded,
                                max_x_padded,
                                max_y_padded,
                                crop_w,
                                crop_h,
                                chat_bg,
                            );
                        }
                    }
                }
            }
        }
    }

    // Запасной вариант (fallback): если координаты определить не удалось, кодируем всё изображение целиком
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

    // Извлечение байтов из jbyteArray на стек или через прямой доступ
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
// Кэширование текста сообщения из MessageItem
// -----------------------------------------------------------------------------

/// Извлекает текстовую составляющую сообщения для последующего использования в TDLib InputTextQuote.
/// Не извлекает неиспользуемые поля (автор, время, аватар), так как Compose MessageBubble
/// отрисовывает их самостоятельно из самого объекта MessageItem.
fn cacheMessageItemText(
    env: *JNIEnv,
    msg_item: jobject,
    target: *PendingQuoteState,
) void {
    if (env.*.PushLocalFrame) |push| {
        if (push(env, 16) != 0) return;
    }
    defer {
        if (env.*.PopLocalFrame) |pop| {
            _ = pop(env, null);
        }
    }

    const item_cls = JniAccessor.getObjectClass(env, msg_item) orelse return;
    target.msg_id = JniAccessor.getLongField(env, msg_item, "id");
    target.text_len = 0;

    // Пытаемся получить getText(), а если это файл/документ — getDocumentFileName()
    const get_text_mid = env.*.GetMethodID.?(env, item_cls, "getText", "()Ljava/lang/String;");
    var j_text = if (get_text_mid) |mid| env.*.CallObjectMethod.?(env, msg_item, mid) else null;
    if (j_text == null) {
        const get_doc_mid = env.*.GetMethodID.?(env, item_cls, "getDocumentFileName", "()Ljava/lang/String;");
        if (get_doc_mid) |mid| {
            j_text = env.*.CallObjectMethod.?(env, msg_item, mid);
        }
    }
    if (j_text != null) {
        if (JniAccessor.getStringUtfChars(env, j_text.?)) |chars| {
            defer JniAccessor.releaseStringUtfChars(env, j_text.?, chars);
            const slice = utf8Truncate(std.mem.span(chars), target.text_buf.len);
            @memcpy(target.text_buf[0..slice.len], slice);
            target.text_len = slice.len;
        }
    }
}

// -----------------------------------------------------------------------------
// Поиск MessageItem в памяти клиента MandaGram
// -----------------------------------------------------------------------------

/// Ищет объект MessageItem по ID в текущем списке сообщений TelegramService.messages.
/// ВАЖНО: Использует PopLocalFrame(env, found_item) для возврата ссылки в родительский фрейм.
/// Это исключает баг с "висячей ссылкой" (dangling pointer / use-after-free на JNI-ссылке).
fn findMessageItemInTelegramService(env: *JNIEnv, target_id: i64) jobject {
    const push = env.*.PushLocalFrame orelse return null;
    const pop = env.*.PopLocalFrame orelse return null;
    if (push(env, 32) != 0) return null;

    var found_item: jobject = null;
    search: {
        const service_cls = JniAccessor.findClass(env, "com/mandagram/network/TelegramService") orelse break :search;
        const inst_fid = env.*.GetStaticFieldID.?(
            env,
            service_cls,
            "INSTANCE",
            "Lcom/mandagram/network/TelegramService;",
        ) orelse break :search;
        const service_inst = env.*.GetStaticObjectField.?(env, service_cls, inst_fid) orelse break :search;

        const get_messages_mid = env.*.GetMethodID.?(
            env,
            service_cls,
            "getMessages",
            "()Lkotlinx/coroutines/flow/StateFlow;",
        ) orelse break :search;
        const flow_obj = env.*.CallObjectMethod.?(env, service_inst, get_messages_mid) orelse break :search;

        const flow_cls = JniAccessor.getObjectClass(env, flow_obj) orelse break :search;
        const get_val_mid = env.*.GetMethodID.?(
            env,
            flow_cls,
            "getValue",
            "()Ljava/lang/Object;",
        ) orelse break :search;
        const list_obj = env.*.CallObjectMethod.?(env, flow_obj, get_val_mid) orelse break :search;

        const list_cls = JniAccessor.getObjectClass(env, list_obj) orelse break :search;
        const size_mid = env.*.GetMethodID.?(env, list_cls, "size", "()I") orelse break :search;
        const get_mid = env.*.GetMethodID.?(env, list_cls, "get", "(I)Ljava/lang/Object;") orelse break :search;

        const size = env.*.CallIntMethod.?(env, list_obj, size_mid);
        var i: i32 = size - 1;
        const min_i: i32 = if (size > 200) size - 200 else 0;
        while (i >= min_i) : (i -= 1) {
            const item = env.*.CallObjectMethod.?(env, list_obj, get_mid, i);
            if (item != null) {
                const item_id = JniAccessor.getLongField(env, item, "id");
                if (item_id == target_id) {
                    found_item = item;
                    break;
                }
                if (env.*.DeleteLocalRef) |del| del(env, item);
            }
        }
    }

    // PopLocalFrame закрывает текущий фрейм локальных ссылок и возвращает
    // валидную ссылку для found_item в вызывающий родительский фрейм.
    return pop(env, found_item);
}

// -----------------------------------------------------------------------------
// Перехватчик 1: Клик "Ответить" на сообщении (ChatComposerActions#beginReply)
// Заранее рендерит пузырь сообщения в фоне, пока пользователь вводит текст.
// -----------------------------------------------------------------------------

fn on_before_begin_reply(param: *HookParam) callconv(.c) void {
    if (!is_active.load(.seq_cst)) return;
    const env = param.getEnv() orelse return;
    ensureJvmCached(env);

    if (param.args_count < 1) return;
    const msg_item = param.args[0] orelse return;

    const msg_id = JniAccessor.getLongField(env, msg_item, "id");
    if (msg_id == 0) return;

    quote_mutex.lock();
    cacheMessageItemText(env, msg_item, &pending_quote);
    pending_quote.captured_path_len = 0;
    if (cached_message_item) |old_ref| {
        if (env.*.DeleteGlobalRef) |del| del(env, old_ref);
    }
    cached_message_item = if (env.*.NewGlobalRef) |new_g| new_g(env, msg_item) else null;
    const captured_msg_id = pending_quote.msg_id;
    quote_mutex.unlock();

    logFmt("[beginReply] Intercepted reply to target {d}, pre-rendering bubble...", .{captured_msg_id});

    var render_buf: [512]u8 = undefined;
    if (renderMessageItemToFile(env, msg_item, &render_buf)) |rendered_path| {
        quote_mutex.lock();
        if (pending_quote.msg_id == captured_msg_id) {
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
// Если предрендеринг не успел завершиться — дорисовывает перед отправкой.
// -----------------------------------------------------------------------------

fn on_before_send_draft(param: *HookParam) callconv(.c) void {
    if (!is_active.load(.seq_cst)) return;
    const env = param.getEnv() orelse return;
    ensureJvmCached(env);

    const this_obj = param.this_ptr orelse return;

    const actions_cls = JniAccessor.getObjectClass(env, this_obj) orelse return;
    const get_entry_mid = env.*.GetStaticMethodID.?(
        env,
        actions_cls,
        "access$getEntry$p",
        "(Lcom/mandagram/ui/chat/ChatComposerActions;)Lcom/mandagram/ui/chat/ComposerDraftEntry;",
    ) orelse {
        checkClearException(env);
        return;
    };

    const entry_obj = env.*.CallStaticObjectMethod.?(env, actions_cls, get_entry_mid, this_obj);
    if (entry_obj == null) return;

    const entry_cls = JniAccessor.getObjectClass(env, entry_obj) orelse return;
    const get_reply_mid = env.*.GetMethodID.?(
        env,
        entry_cls,
        "getReply",
        "()Lcom/mandagram/models/MessageItem;",
    ) orelse {
        checkClearException(env);
        return;
    };

    const reply_item = env.*.CallObjectMethod.?(env, entry_obj, get_reply_mid);
    if (reply_item == null) return;

    const reply_id = JniAccessor.getLongField(env, reply_item, "id");
    quote_mutex.lock();
    const already_rendered = (pending_quote.msg_id == reply_id and pending_quote.captured_path_len > 0);
    if (!already_rendered) {
        cacheMessageItemText(env, reply_item, &pending_quote);
        if (cached_message_item) |old_ref| {
            if (env.*.DeleteGlobalRef) |del| del(env, old_ref);
        }
        cached_message_item = if (env.*.NewGlobalRef) |new_g| new_g(env, reply_item) else null;
    }
    quote_mutex.unlock();

    if (!already_rendered) {
        var render_buf: [512]u8 = undefined;
        if (renderMessageItemToFile(env, reply_item, &render_buf)) |rendered_path| {
            quote_mutex.lock();
            if (pending_quote.msg_id == reply_id) {
                const copy_len = @min(rendered_path.len, pending_quote.captured_path_buf.len - 1);
                @memcpy(pending_quote.captured_path_buf[0..copy_len], rendered_path[0..copy_len]);
                pending_quote.captured_path_buf[copy_len] = 0;
                pending_quote.captured_path_len = copy_len;
            }
            quote_mutex.unlock();
        }
    }
}

// -----------------------------------------------------------------------------
// Перехватчики 3 и 4: Модификация исходящего TDLib SendMessage запроса
// Превращает текстовое сообщение с ответом в фотографию с цитатой и подписью.
// -----------------------------------------------------------------------------

fn handle_send_function(env: *JNIEnv, source_hook: [*:0]const u8, func_obj: jobject) void {
    if (!is_active.load(.seq_cst)) return;
    if (func_obj == null) return;
    ensureJvmCached(env);

    const send_msg_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$SendMessage");
    const is_send_msg = (send_msg_cls != null and env.*.IsInstanceOf.?(env, func_obj, send_msg_cls.?) != 0);
    if (!is_send_msg) return;

    const chat_id = JniAccessor.getLongField(env, func_obj, "chatId");
    if (disable_in_discussions and chat_id != 0 and isDiscussionGroup(env, chat_id)) {
        return;
    }

    const reply_to = JniAccessor.getObjectField(env, func_obj, "replyTo", "Lit/tdlight/jni/TdApi$InputMessageReplyTo;");
    if (reply_to == null) return;

    const reply_msg_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputMessageReplyToMessage") orelse return;
    if (env.*.IsInstanceOf.?(env, reply_to, reply_msg_cls) == 0) return;

    const msg_id = JniAccessor.getLongField(env, reply_to, "messageId");
    if (msg_id == 0) return;

    const input_content = JniAccessor.getObjectField(env, func_obj, "inputMessageContent", "Lit/tdlight/jni/TdApi$InputMessageContent;");
    if (input_content == null) return;

    // Не заменяем, если пользователь уже сам отправляет фото
    const msg_photo_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputMessagePhoto");
    if (msg_photo_cls != null and env.*.IsInstanceOf.?(env, input_content, msg_photo_cls.?) != 0) return;

    const msg_text_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputMessageText");
    const is_text = (msg_text_cls != null and env.*.IsInstanceOf.?(env, input_content, msg_text_cls.?) != 0);
    if (!is_text) return;

    // Исходный набранный пользователем текст становится подписью (caption) к фото-цитате
    const outgoing_caption = JniAccessor.getObjectField(env, input_content, "text", "Lit/tdlight/jni/TdApi$FormattedText;");

    var text_buf: [4096]u8 = undefined;
    var text_slice: []const u8 = "";

    quote_mutex.lock();
    if (pending_quote.msg_id != msg_id or pending_quote.text_len == 0) {
        if (findMessageItemInTelegramService(env, msg_id)) |found| {
            cacheMessageItemText(env, found, &pending_quote);
            if (cached_message_item) |old_ref| {
                if (env.*.DeleteGlobalRef) |del| del(env, old_ref);
            }
            cached_message_item = if (env.*.NewGlobalRef) |new_g| new_g(env, found) else null;
            if (env.*.DeleteLocalRef) |del| del(env, found);
        }
    }

    if (pending_quote.msg_id == msg_id and pending_quote.text_len > 0) {
        const t_len = @min(pending_quote.text_len, text_buf.len);
        @memcpy(text_buf[0..t_len], pending_quote.text_buf[0..t_len]);
        text_slice = text_buf[0..t_len];
    }
    quote_mutex.unlock();

    if (text_slice.len == 0) {
        if (getRawFormattedText(env, chat_id, msg_id)) |raw_fmt| {
            if (getFormattedTextString(env, raw_fmt, &text_buf)) |t| {
                text_slice = t;
            }
        }
    }
    if (text_slice.len == 0) text_slice = "💬 [Сообщение]";

    var captured_buf: [512]u8 = undefined;
    var photo_path: ?[:0]const u8 = null;

    quote_mutex.lock();
    if (pending_quote.msg_id == msg_id and pending_quote.captured_path_len > 0) {
        const c_len = pending_quote.captured_path_len;
        @memcpy(captured_buf[0..c_len], pending_quote.captured_path_buf[0..c_len]);
        captured_buf[c_len] = 0;
        photo_path = captured_buf[0..c_len :0];
    }
    const item_ref = cached_message_item;
    quote_mutex.unlock();

    if (photo_path == null) {
        var target_item: ?jobject = null;
        var needs_local_cleanup = false;
        if (item_ref) |ref| {
            const cur_id = JniAccessor.getLongField(env, ref, "id");
            if (cur_id == msg_id) target_item = ref;
        }
        if (target_item == null) {
            target_item = findMessageItemInTelegramService(env, msg_id);
            needs_local_cleanup = true;
        }
        if (target_item) |item| {
            photo_path = renderMessageItemToFile(env, item, &captured_buf);
            if (needs_local_cleanup and env.*.DeleteLocalRef != null) {
                env.*.DeleteLocalRef.?(env, item);
            }
        }
    }

    const final_photo = photo_path orelse {
        logErrFmt("[{s}] Failed to obtain rendered quote image", .{source_hook});
        return;
    };

    // Создаём объект InputMessagePhoto и подменяем inputMessageContent
    const input_photo_msg = createInputMessagePhoto(env, final_photo, outgoing_caption);
    if (input_photo_msg == null) return;

    JniAccessor.setObjectField(env, func_obj, "inputMessageContent", "Lit/tdlight/jni/TdApi$InputMessageContent;", input_photo_msg.?);
    logFmt("[{s}] Success: outgoing reply transformed into authentic Compose quote photo!", .{source_hook});

    // Добавляем к ответу нативный блок цитаты Telegram (InputTextQuote)
    var fmt_obj: ?jobject = getRawFormattedText(env, chat_id, msg_id);
    if (fmt_obj == null or !isFormattedTextValidForQuote(env, fmt_obj.?)) {
        fmt_obj = createFormattedText(env, text_slice);
    }
    if (fmt_obj) |fo| {
        if (createInputTextQuote(env, fo)) |in_quote| {
            if (createInputMessageReplyToMessage(env, msg_id, in_quote)) |new_rep| {
                JniAccessor.setObjectField(env, func_obj, "replyTo", "Lit/tdlight/jni/TdApi$InputMessageReplyTo;", new_rep);
            }
        }
    }
}

/// Хук для сетевого вызова TdLibSession#requestForSession
fn on_before_request_for_session(param: *HookParam) callconv(.c) void {
    if (!is_active.load(.seq_cst)) return;
    const env = param.getEnv() orelse return;
    ensureJvmCached(env);

    var i: u32 = 0;
    while (i < param.args_count) : (i += 1) {
        if (param.args[i]) |arg| {
            handle_send_function(env, "requestForSession", arg);
        }
    }
}

/// Хук для сетевого вызова SimpleTelegramClient#send
fn on_before_client_send(param: *HookParam) callconv(.c) void {
    if (!is_active.load(.seq_cst)) return;
    const env = param.getEnv() orelse return;
    ensureJvmCached(env);

    var i: u32 = 0;
    while (i < param.args_count) : (i += 1) {
        if (param.args[i]) |arg| {
            handle_send_function(env, "client.send", arg);
        }
    }
}

// -----------------------------------------------------------------------------
// Пользовательские действия и Жизненный цикл плагина
// -----------------------------------------------------------------------------

/// Обработчик переключения настройки "Отправлять цитаты в обсуждениях"
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

/// Точка входа инициализации плагина MandaGram (mandagram_plugin_init).
/// Регистрирует перехватчики (хуки) методов JVM через ByteBuddy / MandaGram HookEngine.
pub export fn mandagram_plugin_init(api: *const PluginApi) callconv(.c) bool {
    global_api = api;
    is_active.store(true, .seq_cst);
    api.log_info("KvoteReply", "Initializing KvoteReply plugin v2.0.0 (Pure Zig, Headless Skia)");

    loadSettings(api);

    // 1. Хук на выбор сообщения для ответа в UI
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

    // 3. Хук на отправку пакета запроса в сессии TDLib
    _ = api.register_hook(
        "com/mandagram/network/engine/TdLibSession",
        "requestForSession",
        null,
        on_before_request_for_session,
        null,
    );

    // 4. Запасной хук на прямой вызов клиента tdlight-java
    _ = api.register_hook(
        "it/tdlight/client/SimpleTelegramClient",
        "send",
        null,
        on_before_client_send,
        null,
    );

    // 5. Регистрация пункта в контекстном меню чата
    if (api.register_chat_action) |reg_action| {
        _ = reg_action("toggle_discussions", "KvoteReply: Toggle Discussion Quotes", on_toggle_setting_click, 0);
    }

    return true;
}

/// Точка входа выгрузки плагина (mandagram_plugin_unload).
/// Корректно освобождает глобальные JNI-ссылки через кэшированный JavaVM pointer,
/// очищает состояние и предотвращает утечки памяти в куче JVM.
pub export fn mandagram_plugin_unload() callconv(.c) void {
    is_active.store(false, .seq_cst);
    if (global_api) |api| {
        api.log_info("KvoteReply", "Unloading KvoteReply plugin v2.0.0");
    }

    quote_mutex.lock();
    // ОСВОБОЖДЕНИЕ ГЛОБАЛЬНОЙ ССЫЛКИ JNI:
    // Простого присваивания cached_message_item = null недостаточно!
    // Без вызова DeleteGlobalRef объект MessageItem останется в JVM heap навсегда (GC root leak).
    if (cached_message_item) |item| {
        if (global_jvm) |jvm| {
            var raw_env: ?*anyopaque = null;
            if (jvm.getEnv(&raw_env, plugin_api.JNI_VERSION_1_6) == 0) {
                if (raw_env) |penv| {
                    const env: *JNIEnv = @ptrCast(@alignCast(penv));
                    if (env.*.DeleteGlobalRef) |del| {
                        del(env, item);
                    }
                }
            }
        }
        cached_message_item = null;
    }
    pending_quote = .{};
    quote_mutex.unlock();
}

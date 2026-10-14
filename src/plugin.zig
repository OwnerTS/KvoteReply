const std = @import("std");
const plugin_api = @import("include/mandagram_plugin.zig");
const accessor = @import("include/jni_accessor.zig");
const HookParam = plugin_api.HookParam;
const PluginApi = plugin_api.PluginApi;
const JniAccessor = accessor.JniAccessor;
const JNIEnv = plugin_api.JNIEnv;
const jobject = plugin_api.jobject;
const jclass = plugin_api.jclass;
const jvalue = plugin_api.jvalue;
const jint = plugin_api.jint;
const jlong = plugin_api.jlong;
const jboolean = plugin_api.jboolean;
const jfloat = plugin_api.jfloat;

var global_api: ?*const PluginApi = null;
var is_active = std.atomic.Value(bool).init(true);
var disable_in_discussions: bool = false;

pub const METADATA = plugin_api.PluginMetadata{
    .name = "KvoteReply",
    .version = "1.0.0",
    .author = "OwnerTS",
    .description = "Pixel-perfect authentic Compose message bubble photo quote replies for MandaGram.",
};

pub export fn mandagram_plugin_metadata() callconv(.c) ?*const plugin_api.PluginMetadata {
    return &METADATA;
}

const PendingQuoteState = struct {
    msg_id: i64 = 0,
    sender_id: i64 = 0,
    author_buf: [256]u8 = [_]u8{0} ** 256,
    author_len: usize = 0,
    text_buf: [4096]u8 = [_]u8{0} ** 4096,
    text_len: usize = 0,
    time_buf: [32]u8 = [_]u8{0} ** 32,
    time_len: usize = 0,
    avatar_buf: [512]u8 = [_]u8{0} ** 512,
    avatar_len: usize = 0,
    initials_buf: [16]u8 = [_]u8{0} ** 16,
    initials_len: usize = 0,
    captured_path_buf: [512]u8 = [_]u8{0} ** 512,
    captured_path_len: usize = 0,
};

var quote_mutex = std.Thread.Mutex{};
var pending_quote = PendingQuoteState{};
var cached_message_item: ?jobject = null;

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

// -----------------------------------------------------------------------------
// Settings Persistence
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
// TDLib Object Constructors
// -----------------------------------------------------------------------------

fn createFormattedText(env: *JNIEnv, text_slice: []const u8) ?jobject {
    const fmt_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$FormattedText") orelse return null;
    const text_entity_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$TextEntity") orelse return null;

    const safe_slice = utf8Truncate(text_slice, 1024);
    var z_buf: [1025]u8 = undefined;
    @memcpy(z_buf[0..safe_slice.len], safe_slice);
    z_buf[safe_slice.len] = 0;

    const j_str = JniAccessor.newStringUtf(env, z_buf[0..safe_slice.len :0]) orelse return null;

    const empty_entities = if (env.*.NewObjectArray) |new_arr|
        new_arr(env, 0, text_entity_cls, null)
    else return null;

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
    else null;
}

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

fn createInputTextQuote(env: *JNIEnv, fmt_obj: jobject) ?jobject {
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
    else null;
}

fn createInputMessageReplyToMessage(env: *JNIEnv, msg_id: i64, quote_obj: jobject) ?jobject {
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
    else null;
}

fn createInputMessagePhoto(env: *JNIEnv, photo_path_z: [*:0]const u8, caption_obj: ?jobject) ?jobject {
    const file_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputFileLocal") orelse return null;
    const file_ctor = env.*.GetMethodID.?(env, file_cls, "<init>", "(Ljava/lang/String;)V") orelse return null;

    const j_path_str = JniAccessor.newStringUtf(env, photo_path_z) orelse return null;
    const file_args = [_]jvalue{ .{ .l = j_path_str } };
    const input_file = if (env.*.NewObjectA) |new_a|
        new_a(env, file_cls, file_ctor, &file_args)
    else return null;
    if (input_file == null) return null;

    const photo_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputPhoto") orelse return null;
    const photo_ctor = env.*.GetMethodID.?(env, photo_cls, "<init>", "()V") orelse return null;
    const empty_args = [_]jvalue{};
    const input_photo = if (env.*.NewObjectA) |new_a|
        new_a(env, photo_cls, photo_ctor, &empty_args)
    else return null;
    if (input_photo == null) return null;

    JniAccessor.setObjectField(env, input_photo, "photo", "Lit/tdlight/jni/TdApi$InputFile;", input_file);

    // 3. TdApi$InputMessagePhoto()
    const msg_photo_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputMessagePhoto") orelse return null;
    const msg_photo_ctor = env.*.GetMethodID.?(env, msg_photo_cls, "<init>", "()V") orelse return null;
    const msg_photo = if (env.*.NewObjectA) |new_a|
        new_a(env, msg_photo_cls, msg_photo_ctor, &empty_args)
    else return null;
    if (msg_photo == null) return null;

    JniAccessor.setObjectField(env, msg_photo, "photo", "Lit/tdlight/jni/TdApi$InputPhoto;", input_photo);
    const final_caption: jobject = caption_obj orelse createFormattedText(env, "") orelse null;
    if (final_caption != null) {
        JniAccessor.setObjectField(env, msg_photo, "caption", "Lit/tdlight/jni/TdApi$FormattedText;", final_caption);
    }

    return msg_photo;
}

fn getRawFormattedText(env: *JNIEnv, chat_id: i64, msg_id: i64) ?jobject {
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
// Isolated Headless Compose Renderer (ImageComposeScene -> In-Memory PNG)
// -----------------------------------------------------------------------------
fn getClassLoaderFromObject(env: *JNIEnv, obj: jobject) ?jobject {
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

const RenderState = struct {
    msg_item: jobject = null,
    is_group: bool = false,
    is_channel: bool = false,
    pass: u32 = 0,
    self_lambda: jobject = null,
};

fn renderComposable(env: *JNIEnv, composer: jobject, user_data: usize) callconv(.c) void {
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

        env.*.CallStaticVoidMethod.?(env, theme_kt, theme_mid, state.self_lambda, composer, @as(jint, 0));
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
            @as(jboolean, if (state.is_group) 1 else 0),
            @as(jboolean, 1),
            @as(jboolean, 1),
            @as(jboolean, if (state.is_channel) 1 else 0),
            @as(jlong, 0),
            @as(jobject, null),
            @as(jobject, null),
            @as(jobject, null),
            @as(jobject, null),
            @as(jobject, null),
            @as(jobject, null),
            @as(jobject, null),
            @as(jobject, null),
            @as(jobject, null),
            composer,
            @as(jint, 54),
            @as(jint, 0),
            @as(jint, 0x7FC0),
        );
        checkClearException(env);
    }
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
        return @bitCast(@as(u32, 0xFFFDF8F6));
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
                            return @bitCast(@as(u32, 0xFF0F110D));
                        }
                    }
                }
            }
        }
    }
    checkClearException(env);
    return @bitCast(@as(u32, 0xFF100D0B));
}

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

    // 1. Create composable lambda
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

    // 2. Prepare Density and CoroutineContext
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

    // 3. Construct ImageComposeScene
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

    const render_mid = env.*.GetMethodID.?(env, scene_cls, "render", "(J)Lorg/jetbrains/skia/Image;") orelse return null;
    const full_img = env.*.CallObjectMethod.?(env, scene, render_mid, @as(jlong, 0));
    if (full_img == null) {
        logErrFmt("[renderMessageItemToFile] scene.render returned null", .{});
        checkClearException(env);
        return null;
    }
    defer if (env.*.DeleteLocalRef) |del| del(env, full_img);

    // 4. Bounding box pixel scan on native Skia memory
    const img_cls = loadClass(env, loader, "org/jetbrains/skia/Image") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, img_cls);

    const enc_fmt_cls = loadClass(env, loader, "org/jetbrains/skia/EncodedImageFormat") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, enc_fmt_cls);
    const png_fid = env.*.GetStaticFieldID.?(env, enc_fmt_cls, "PNG", "Lorg/jetbrains/skia/EncodedImageFormat;") orelse return null;
    const png_fmt = env.*.GetStaticObjectField.?(env, enc_fmt_cls, png_fid);
    defer if (env.*.DeleteLocalRef) |del| del(env, png_fmt);

    const encode_mid = env.*.GetMethodID.?(
        env,
        img_cls,
        "encodeToData",
        "(Lorg/jetbrains/skia/EncodedImageFormat;I)Lorg/jetbrains/skia/Data;",
    ) orelse return null;

    const data_cls = loadClass(env, loader, "org/jetbrains/skia/Data") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, data_cls);
    const get_bytes_mid = env.*.GetMethodID.?(env, data_cls, "getBytes", "()[B") orelse return null;

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
                            const pad: usize = 6;
                            const min_x_padded = if (minX >= pad) minX - pad else 0;
                            const min_y_padded = if (minY >= pad) minY - pad else 0;
                            const max_x_padded = @min(w, maxX + 1 + pad);
                            const max_y_padded = @min(h, maxY + 1 + pad);
                            const crop_w = max_x_padded - min_x_padded;
                            const crop_h = max_y_padded - min_y_padded;

                            const surf_cls = loadClass(env, loader, "org/jetbrains/skia/Surface");
                            if (surf_cls) |s_cls| {
                                defer if (env.*.DeleteLocalRef) |del| del(env, s_cls);
                                const comp_fid = env.*.GetStaticFieldID.?(env, s_cls, "Companion", "Lorg/jetbrains/skia/Surface$Companion;");
                                if (comp_fid) |cfid| {
                                    const comp_obj = env.*.GetStaticObjectField.?(env, s_cls, cfid);
                                    if (comp_obj) |cobj| {
                                        defer if (env.*.DeleteLocalRef) |del| del(env, cobj);
                                        const comp_cls = loadClass(env, loader, "org/jetbrains/skia/Surface$Companion");
                                        if (comp_cls) |cp_cls| {
                                            defer if (env.*.DeleteLocalRef) |del| del(env, cp_cls);
                                            const make_raster_mid = env.*.GetMethodID.?(env, cp_cls, "makeRasterN32Premul", "(II)Lorg/jetbrains/skia/Surface;");
                                            if (make_raster_mid) |mrmid| {
                                                const surface = env.*.CallObjectMethod.?(env, cobj, mrmid, @as(jint, @intCast(crop_w)), @as(jint, @intCast(crop_h)));
                                                if (surface) |surf| {
                                                    defer if (env.*.DeleteLocalRef) |del| del(env, surf);
                                                    const get_canvas_mid = env.*.GetMethodID.?(env, s_cls, "getCanvas", "()Lorg/jetbrains/skia/Canvas;");
                                                    if (get_canvas_mid) |gcmid| {
                                                        const canvas = env.*.CallObjectMethod.?(env, surf, gcmid);
                                                        if (canvas) |cvs| {
                                                            defer if (env.*.DeleteLocalRef) |del| del(env, cvs);
                                                            const canvas_cls = loadClass(env, loader, "org/jetbrains/skia/Canvas");
                                                            if (canvas_cls) |cvs_cls| {
                                                                defer if (env.*.DeleteLocalRef) |del| del(env, cvs_cls);
                                                                const clear_mid = env.*.GetMethodID.?(env, cvs_cls, "clear", "(I)Lorg/jetbrains/skia/Canvas;");
                                                                if (clear_mid) |clmid| {
                                                                    const cl_ret = env.*.CallObjectMethod.?(env, cvs, clmid, chat_bg);
                                                                    if (cl_ret != null and env.*.DeleteLocalRef != null) env.*.DeleteLocalRef.?(env, cl_ret);
                                                                } else {
                                                                    checkClearException(env);
                                                                }

                                                                const rect_cls = loadClass(env, loader, "org/jetbrains/skia/Rect");
                                                                if (rect_cls) |r_cls| {
                                                                    defer if (env.*.DeleteLocalRef) |del| del(env, r_cls);
                                                                    const rect_comp_fid = env.*.GetStaticFieldID.?(env, r_cls, "Companion", "Lorg/jetbrains/skia/Rect$Companion;");
                                                                    if (rect_comp_fid) |rcfid| {
                                                                        const rect_comp = env.*.GetStaticObjectField.?(env, r_cls, rcfid);
                                                                        if (rect_comp) |rc_obj| {
                                                                            defer if (env.*.DeleteLocalRef) |del| del(env, rc_obj);
                                                                            const rect_comp_cls = loadClass(env, loader, "org/jetbrains/skia/Rect$Companion");
                                                                            if (rect_comp_cls) |rc_cls| {
                                                                                defer if (env.*.DeleteLocalRef) |del| del(env, rc_cls);
                                                                                const make_ltrb_mid = env.*.GetMethodID.?(env, rc_cls, "makeLTRB", "(FFFF)Lorg/jetbrains/skia/Rect;");
                                                                                const make_wh_mid = env.*.GetMethodID.?(env, rc_cls, "makeWH", "(FF)Lorg/jetbrains/skia/Rect;");
                                                                                if (make_ltrb_mid != null and make_wh_mid != null) {
                                                                                    const src_rect = env.*.CallObjectMethod.?(env, rc_obj, make_ltrb_mid.?, @as(jfloat, @floatFromInt(min_x_padded)), @as(jfloat, @floatFromInt(min_y_padded)), @as(jfloat, @floatFromInt(max_x_padded)), @as(jfloat, @floatFromInt(max_y_padded)));
                                                                                    defer if (src_rect != null and env.*.DeleteLocalRef != null) env.*.DeleteLocalRef.?(env, src_rect);
                                                                                    const dst_rect = env.*.CallObjectMethod.?(env, rc_obj, make_wh_mid.?, @as(jfloat, @floatFromInt(crop_w)), @as(jfloat, @floatFromInt(crop_h)));
                                                                                    defer if (dst_rect != null and env.*.DeleteLocalRef != null) env.*.DeleteLocalRef.?(env, dst_rect);

                                                                                    const draw_mid = env.*.GetMethodID.?(env, cvs_cls, "drawImageRect", "(Lorg/jetbrains/skia/Image;Lorg/jetbrains/skia/Rect;Lorg/jetbrains/skia/Rect;)Lorg/jetbrains/skia/Canvas;");
                                                                                    if (draw_mid) |dmid| {
                                                                                        const cvs_ret = env.*.CallObjectMethod.?(env, cvs, dmid, full_img, src_rect, dst_rect);
                                                                                        defer if (cvs_ret != null and env.*.DeleteLocalRef != null) env.*.DeleteLocalRef.?(env, cvs_ret);

                                                                                        const make_snapshot_mid = env.*.GetMethodID.?(env, s_cls, "makeImageSnapshot", "()Lorg/jetbrains/skia/Image;");
                                                                                        if (make_snapshot_mid) |msmid| {
                                                                                            const snapshot = env.*.CallObjectMethod.?(env, surf, msmid);
                                                                                            if (snapshot) |snap| {
                                                                                                defer if (env.*.DeleteLocalRef) |del| del(env, snap);
                                                                                                const data_obj = env.*.CallObjectMethod.?(env, snap, encode_mid, png_fmt, @as(jint, 100));
                                                                                                if (data_obj) |dobj| {
                                                                                                    defer if (env.*.DeleteLocalRef) |del| del(env, dobj);
                                                                                                    final_bytes_obj = env.*.CallObjectMethod.?(env, dobj, get_bytes_mid);
                                                                                                }
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Fallback: encode full image directly
    if (final_bytes_obj == null) {
        const data_obj = env.*.CallObjectMethod.?(env, full_img, encode_mid, png_fmt, @as(jint, 100));
        if (data_obj) |dobj| {
            defer if (env.*.DeleteLocalRef) |del| del(env, dobj);
            final_bytes_obj = env.*.CallObjectMethod.?(env, dobj, get_bytes_mid);
        }
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

fn extractMessageItemDetails(
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
    target.sender_id = JniAccessor.getLongField(env, msg_item, "senderId");

    // 1. Author (senderName)
    target.author_len = 0;
    const get_name_mid = env.*.GetMethodID.?(env, item_cls, "getSenderName", "()Ljava/lang/String;");
    const j_name = if (get_name_mid) |mid| env.*.CallObjectMethod.?(env, msg_item, mid) else null;
    if (j_name != null) {
        if (JniAccessor.getStringUtfChars(env, j_name)) |chars| {
            defer JniAccessor.releaseStringUtfChars(env, j_name, chars);
            const slice = utf8Truncate(std.mem.span(chars), target.author_buf.len);
            @memcpy(target.author_buf[0..slice.len], slice);
            target.author_len = slice.len;
        }
    }

    // 2. Text (text or documentFileName)
    target.text_len = 0;
    const get_text_mid = env.*.GetMethodID.?(env, item_cls, "getText", "()Ljava/lang/String;");
    var j_text = if (get_text_mid) |mid| env.*.CallObjectMethod.?(env, msg_item, mid) else null;
    if (j_text == null) {
        const get_doc_mid = env.*.GetMethodID.?(env, item_cls, "getDocumentFileName", "()Ljava/lang/String;");
        if (get_doc_mid) |mid| {
            j_text = env.*.CallObjectMethod.?(env, msg_item, mid);
        }
    }
    if (j_text != null) {
        if (JniAccessor.getStringUtfChars(env, j_text)) |chars| {
            defer JniAccessor.releaseStringUtfChars(env, j_text, chars);
            const slice = utf8Truncate(std.mem.span(chars), target.text_buf.len);
            @memcpy(target.text_buf[0..slice.len], slice);
            target.text_len = slice.len;
        }
    }

    // 3. Time (formattedTime)
    target.time_len = 0;
    const get_time_mid = env.*.GetMethodID.?(env, item_cls, "getFormattedTime", "()Ljava/lang/String;");
    const j_time = if (get_time_mid) |mid| env.*.CallObjectMethod.?(env, msg_item, mid) else null;
    if (j_time != null) {
        if (JniAccessor.getStringUtfChars(env, j_time)) |chars| {
            defer JniAccessor.releaseStringUtfChars(env, j_time, chars);
            const slice = utf8Truncate(std.mem.span(chars), target.time_buf.len);
            @memcpy(target.time_buf[0..slice.len], slice);
            target.time_len = slice.len;
        }
    }

    // 4. Avatar (senderAvatarPath)
    target.avatar_len = 0;
    const get_avatar_mid = env.*.GetMethodID.?(env, item_cls, "getSenderAvatarPath", "()Ljava/lang/String;");
    const j_avatar = if (get_avatar_mid) |mid| env.*.CallObjectMethod.?(env, msg_item, mid) else null;
    if (j_avatar != null) {
        if (JniAccessor.getStringUtfChars(env, j_avatar)) |chars| {
            defer JniAccessor.releaseStringUtfChars(env, j_avatar, chars);
            const slice = utf8Truncate(std.mem.span(chars), target.avatar_buf.len);
            @memcpy(target.avatar_buf[0..slice.len], slice);
            target.avatar_len = slice.len;
        }
    }

    // 5. Initials (senderInitials)
    target.initials_len = 0;
    const get_initials_mid = env.*.GetMethodID.?(env, item_cls, "getSenderInitials", "()Ljava/lang/String;");
    const j_initials = if (get_initials_mid) |mid| env.*.CallObjectMethod.?(env, msg_item, mid) else null;
    if (j_initials != null) {
        if (JniAccessor.getStringUtfChars(env, j_initials)) |chars| {
            defer JniAccessor.releaseStringUtfChars(env, j_initials, chars);
            const slice = utf8Truncate(std.mem.span(chars), target.initials_buf.len);
            @memcpy(target.initials_buf[0..slice.len], slice);
            target.initials_len = slice.len;
        }
    }
}

fn findMessageItemInTelegramService(env: *JNIEnv, target_id: i64) ?jobject {
    if (env.*.PushLocalFrame) |push| {
        if (push(env, 32) != 0) return null;
    }
    var found_item: jobject = null;
    defer {
        if (env.*.PopLocalFrame) |pop| {
            _ = pop(env, found_item);
        }
    }

    const service_cls = JniAccessor.findClass(env, "com/mandagram/network/TelegramService") orelse return null;
    const inst_fid = env.*.GetStaticFieldID.?(
        env,
        service_cls,
        "INSTANCE",
        "Lcom/mandagram/network/TelegramService;",
    ) orelse return null;
    const service_inst = env.*.GetStaticObjectField.?(env, service_cls, inst_fid) orelse return null;

    const get_messages_mid = env.*.GetMethodID.?(
        env,
        service_cls,
        "getMessages",
        "()Lkotlinx/coroutines/flow/StateFlow;",
    ) orelse return null;
    const flow_obj = env.*.CallObjectMethod.?(env, service_inst, get_messages_mid) orelse return null;

    const flow_cls = JniAccessor.getObjectClass(env, flow_obj) orelse return null;
    const get_val_mid = env.*.GetMethodID.?(
        env,
        flow_cls,
        "getValue",
        "()Ljava/lang/Object;",
    ) orelse return null;
    const list_obj = env.*.CallObjectMethod.?(env, flow_obj, get_val_mid) orelse return null;

    const list_cls = JniAccessor.getObjectClass(env, list_obj) orelse return null;
    const size_mid = env.*.GetMethodID.?(env, list_cls, "size", "()I") orelse return null;
    const get_mid = env.*.GetMethodID.?(env, list_cls, "get", "(I)Ljava/lang/Object;") orelse return null;

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
    return found_item;
}

// -----------------------------------------------------------------------------
// Hook 1: ChatComposerActions#beginReply (Lcom/mandagram/models/MessageItem;)V
// -----------------------------------------------------------------------------

fn on_before_begin_reply(param: *HookParam) callconv(.c) void {
    if (!is_active.load(.seq_cst)) return;
    const env = param.getEnv() orelse return;
    if (param.args_count < 1) return;
    const msg_item = param.args[0] orelse return;

    const msg_id = JniAccessor.getLongField(env, msg_item, "id");
    if (msg_id == 0) return;

    quote_mutex.lock();
    extractMessageItemDetails(env, msg_item, &pending_quote);
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
// Hook 2: ChatComposerActions#sendDraft ()V
// -----------------------------------------------------------------------------

fn on_before_send_draft(param: *HookParam) callconv(.c) void {
    if (!is_active.load(.seq_cst)) return;
    const env = param.getEnv() orelse return;
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
        extractMessageItemDetails(env, reply_item, &pending_quote);
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
// Hook 3 & 4: Outgoing SendMessage Transformation (Text -> Photo with Caption)
// -----------------------------------------------------------------------------

fn handle_send_function(env: *JNIEnv, source_hook: [*:0]const u8, func_obj: jobject) void {
    if (!is_active.load(.seq_cst)) return;
    if (func_obj == null) return;

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

    const msg_photo_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputMessagePhoto");
    if (msg_photo_cls != null and env.*.IsInstanceOf.?(env, input_content, msg_photo_cls.?) != 0) return;

    const msg_text_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputMessageText");
    const is_text = (msg_text_cls != null and env.*.IsInstanceOf.?(env, input_content, msg_text_cls.?) != 0);
    if (!is_text) return;

    const outgoing_caption = JniAccessor.getObjectField(env, input_content, "text", "Lit/tdlight/jni/TdApi$FormattedText;");

    var text_buf: [4096]u8 = undefined;
    var text_slice: []const u8 = "";

    quote_mutex.lock();
    if (pending_quote.msg_id != msg_id or pending_quote.text_len == 0) {
        if (findMessageItemInTelegramService(env, msg_id)) |found| {
            extractMessageItemDetails(env, found, &pending_quote);
            if (cached_message_item) |old_ref| {
                if (env.*.DeleteGlobalRef) |del| del(env, old_ref);
            }
            cached_message_item = if (env.*.NewGlobalRef) |new_g| new_g(env, found) else null;
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
        if (item_ref) |ref| {
            const cur_id = JniAccessor.getLongField(env, ref, "id");
            if (cur_id == msg_id) target_item = ref;
        }
        if (target_item == null) {
            target_item = findMessageItemInTelegramService(env, msg_id);
        }
        if (target_item) |item| {
            photo_path = renderMessageItemToFile(env, item, &captured_buf);
        }
    }

    const final_photo = photo_path orelse {
        logErrFmt("[{s}] Failed to obtain rendered quote image", .{source_hook});
        return;
    };

    const input_photo_msg = createInputMessagePhoto(env, final_photo, outgoing_caption);
    if (input_photo_msg == null) return;

    JniAccessor.setObjectField(env, func_obj, "inputMessageContent", "Lit/tdlight/jni/TdApi$InputMessageContent;", input_photo_msg.?);
    logFmt("[{s}] Success: outgoing reply transformed into authentic Compose quote photo!", .{source_hook});

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

fn on_before_request_for_session(param: *HookParam) callconv(.c) void {
    if (!is_active.load(.seq_cst)) return;
    const env = param.getEnv() orelse return;
    var i: u32 = 0;
    while (i < param.args_count) : (i += 1) {
        if (param.args[i]) |arg| {
            handle_send_function(env, "requestForSession", arg);
        }
    }
}

fn on_before_client_send(param: *HookParam) callconv(.c) void {
    if (!is_active.load(.seq_cst)) return;
    const env = param.getEnv() orelse return;
    var i: u32 = 0;
    while (i < param.args_count) : (i += 1) {
        if (param.args[i]) |arg| {
            handle_send_function(env, "client.send", arg);
        }
    }
}

// -----------------------------------------------------------------------------
// Settings & Lifecycle
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

pub export fn mandagram_plugin_init(api: *const PluginApi) callconv(.c) bool {
    global_api = api;
    is_active.store(true, .seq_cst);
    api.log_info("KvoteReply", "Initializing KvoteReply plugin v1.0.0 (by OwnerTS)");

    loadSettings(api);

    _ = api.register_hook(
        "com/mandagram/ui/chat/ChatComposerActions",
        "beginReply",
        "(Lcom/mandagram/models/MessageItem;)V",
        on_before_begin_reply,
        null,
    );

    _ = api.register_hook(
        "com/mandagram/ui/chat/ChatComposerActions",
        "sendDraft",
        "()V",
        on_before_send_draft,
        null,
    );

    _ = api.register_hook(
        "com/mandagram/network/engine/TdLibSession",
        "requestForSession",
        null,
        on_before_request_for_session,
        null,
    );

    _ = api.register_hook(
        "it/tdlight/client/SimpleTelegramClient",
        "send",
        null,
        on_before_client_send,
        null,
    );

    if (api.register_chat_action) |reg_action| {
        _ = reg_action("toggle_discussions", "KvoteReply: Toggle Discussion Quotes", on_toggle_setting_click, 0);
    }

    return true;
}

pub export fn mandagram_plugin_unload() callconv(.c) void {
    is_active.store(false, .seq_cst);
    if (global_api) |api| {
        api.log_info("KvoteReply", "Unloading KvoteReply plugin v1.0.0");
    }

    quote_mutex.lock();
    cached_message_item = null;
    pending_quote = .{};
    quote_mutex.unlock();
}

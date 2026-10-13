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

var global_api: ?*const PluginApi = null;
var disable_in_discussions: bool = false;

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

const METADATA = plugin_api.PluginMetadata{
    .name = "KvoteReply",
    .version = "1.0.0",
    .author = "OwnerTS",
    .description = "Pixel-perfect authentic Compose message bubble photo quote replies for MandaGram.",
};

pub export fn mandagram_plugin_metadata() callconv(.c) ?*const plugin_api.PluginMetadata {
    return &METADATA;
}

fn logFmt(comptime fmt: []const u8, args: anytype) void {
    const api = global_api orelse return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    api.log_info("QuoteReply", msg);
}

fn logErrFmt(comptime fmt: []const u8, args: anytype) void {
    const api = global_api orelse return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    api.log_error("QuoteReply", msg);
}

// -----------------------------------------------------------------------------
// TDLib Object Constructors
// -----------------------------------------------------------------------------

fn createFormattedText(env: *JNIEnv, text_slice: []const u8) ?jobject {
    const fmt_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$FormattedText") orelse {
        logErrFmt("[createFormattedText] Failed to find TdApi$FormattedText class", .{});
        return null;
    };
    const text_entity_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$TextEntity") orelse {
        logErrFmt("[createFormattedText] Failed to find TdApi$TextEntity class", .{});
        return null;
    };

    var z_buf: [1025]u8 = undefined;
    const copy_len = @min(text_slice.len, 1024);
    @memcpy(z_buf[0..copy_len], text_slice[0..copy_len]);
    z_buf[copy_len] = 0;
    const j_str = JniAccessor.newStringUtf(env, z_buf[0..copy_len :0]) orelse {
        logErrFmt("[createFormattedText] newStringUtf failed", .{});
        return null;
    };

    const empty_entities = if (env.*.NewObjectArray) |new_arr|
        new_arr(env, 0, text_entity_cls, null)
    else {
        logErrFmt("[createFormattedText] NewObjectArray is null", .{});
        return null;
    };

    const fmt_ctor = env.*.GetMethodID.?(
        env,
        fmt_cls,
        "<init>",
        "(Ljava/lang/String;[Lit/tdlight/jni/TdApi$TextEntity;)V",
    ) orelse {
        logErrFmt("[createFormattedText] Failed to find FormattedText constructor", .{});
        return null;
    };

    const fmt_args = [_]jvalue{
        .{ .l = j_str },
        .{ .l = empty_entities },
    };

    return if (env.*.NewObjectA) |new_a|
        new_a(env, fmt_cls, fmt_ctor, &fmt_args)
    else
        null;
}

fn isFormattedTextValidForQuote(env: *JNIEnv, fmt_obj: jobject) bool {
    if (fmt_obj == null) return false;
    const fmt_cls = JniAccessor.getObjectClass(env, fmt_obj) orelse return false;
    const text_fid = env.*.GetFieldID.?(env, fmt_cls, "text", "Ljava/lang/String;");
    if (text_fid == null) {
        if (env.*.ExceptionClear) |clear| clear(env);
        return false;
    }
    const j_str = env.*.GetObjectField.?(env, fmt_obj, text_fid.?);
    if (j_str == null) return false;
    const str_cls = JniAccessor.getObjectClass(env, j_str) orelse return false;
    const len_mid = env.*.GetMethodID.?(env, str_cls, "length", "()I");
    if (len_mid == null) {
        if (env.*.ExceptionClear) |clear| clear(env);
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
        if (env.*.ExceptionClear) |clear| clear(env);
        return null;
    }
    const j_str = env.*.GetObjectField.?(env, fmt_obj, text_fid.?);
    if (j_str == null) return null;

    const chars = JniAccessor.getStringUtfChars(env, j_str) orelse return null;
    defer JniAccessor.releaseStringUtfChars(env, j_str, chars);
    const span = std.mem.span(chars);
    const copy_len = @min(span.len, out_buf.len);
    @memcpy(out_buf[0..copy_len], span[0..copy_len]);
    return out_buf[0..copy_len];
}

fn createInputTextQuote(env: *JNIEnv, fmt_obj: jobject) ?jobject {
    const q_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputTextQuote") orelse {
        logErrFmt("[createInputTextQuote] Failed to find TdApi$InputTextQuote class", .{});
        return null;
    };
    const q_ctor = env.*.GetMethodID.?(
        env,
        q_cls,
        "<init>",
        "(Lit/tdlight/jni/TdApi$FormattedText;I)V",
    ) orelse {
        logErrFmt("[createInputTextQuote] Failed to find constructor", .{});
        return null;
    };
    const q_args = [_]jvalue{
        .{ .l = fmt_obj },
        .{ .i = 0 }, // position = 0
    };
    return if (env.*.NewObjectA) |new_a|
        new_a(env, q_cls, q_ctor, &q_args)
    else
        null;
}

fn createInputMessageReplyToMessage(env: *JNIEnv, msg_id: i64, quote_obj: jobject) ?jobject {
    const reply_msg_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputMessageReplyToMessage") orelse {
        logErrFmt("[createInputMessageReplyToMessage] Failed to find class", .{});
        return null;
    };
    const reply_ctor = env.*.GetMethodID.?(
        env,
        reply_msg_cls,
        "<init>",
        "(JLit/tdlight/jni/TdApi$InputTextQuote;ILjava/lang/String;)V",
    ) orelse {
        logErrFmt("[createInputMessageReplyToMessage] Failed to find constructor", .{});
        return null;
    };

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

fn createInputMessagePhoto(env: *JNIEnv, photo_path_z: [*:0]const u8, caption_obj: ?jobject) ?jobject {
    // 1. TdApi$InputFileLocal(path)
    const file_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputFileLocal") orelse {
        logErrFmt("[createInputMessagePhoto] TdApi$InputFileLocal class not found", .{});
        return null;
    };
    const file_ctor = env.*.GetMethodID.?(env, file_cls, "<init>", "(Ljava/lang/String;)V") orelse {
        logErrFmt("[createInputMessagePhoto] InputFileLocal.<init> not found", .{});
        return null;
    };

    const j_path_str = JniAccessor.newStringUtf(env, photo_path_z) orelse return null;
    const file_args = [_]jvalue{ .{ .l = j_path_str } };
    const input_file = if (env.*.NewObjectA) |new_a|
        new_a(env, file_cls, file_ctor, &file_args)
    else return null;
    if (input_file == null) {
        logErrFmt("[createInputMessagePhoto] Failed to construct InputFileLocal", .{});
        return null;
    }

    // 2. TdApi$InputPhoto()
    const photo_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputPhoto") orelse {
        logErrFmt("[createInputMessagePhoto] TdApi$InputPhoto class not found", .{});
        return null;
    };
    const photo_ctor = env.*.GetMethodID.?(env, photo_cls, "<init>", "()V") orelse {
        logErrFmt("[createInputMessagePhoto] InputPhoto.<init> not found", .{});
        return null;
    };
    const empty_args = [_]jvalue{};
    const input_photo = if (env.*.NewObjectA) |new_a|
        new_a(env, photo_cls, photo_ctor, &empty_args)
    else return null;
    if (input_photo == null) {
        logErrFmt("[createInputMessagePhoto] Failed to construct InputPhoto", .{});
        return null;
    }

    JniAccessor.setObjectField(env, input_photo, "photo", "Lit/tdlight/jni/TdApi$InputFile;", input_file);

    // 3. TdApi$InputMessagePhoto()
    const msg_photo_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputMessagePhoto") orelse {
        logErrFmt("[createInputMessagePhoto] TdApi$InputMessagePhoto class not found", .{});
        return null;
    };
    const msg_photo_ctor = env.*.GetMethodID.?(env, msg_photo_cls, "<init>", "()V") orelse {
        logErrFmt("[createInputMessagePhoto] InputMessagePhoto.<init> not found", .{});
        return null;
    };
    const msg_photo = if (env.*.NewObjectA) |new_a|
        new_a(env, msg_photo_cls, msg_photo_ctor, &empty_args)
    else return null;
    if (msg_photo == null) {
        logErrFmt("[createInputMessagePhoto] Failed to construct InputMessagePhoto", .{});
        return null;
    }

    JniAccessor.setObjectField(env, msg_photo, "photo", "Lit/tdlight/jni/TdApi$InputPhoto;", input_photo);
    if (caption_obj) |cap| {
        JniAccessor.setObjectField(env, msg_photo, "caption", "Lit/tdlight/jni/TdApi$FormattedText;", cap);
    }

    return msg_photo;
}

// -----------------------------------------------------------------------------
// Message Information Lookups
// -----------------------------------------------------------------------------

fn getRawFormattedText(env: *JNIEnv, chat_id: i64, msg_id: i64) ?jobject {
    const engine_cls = JniAccessor.findClass(env, "com/mandagram/network/engine/TdLibNetworkEngine") orelse return null;
    const get_cc_mid = env.*.GetStaticMethodID.?(
        env,
        engine_cls,
        "access$getConversationController$p",
        "()Lcom/mandagram/network/engine/ConversationController;",
    ) orelse {
        if (env.*.ExceptionClear) |clear| clear(env);
        return null;
    };

    const conv_ctrl = env.*.CallStaticObjectMethod.?(env, engine_cls, get_cc_mid);
    if (conv_ctrl == null) return null;

    const ctrl_cls = JniAccessor.getObjectClass(env, conv_ctrl) orelse return null;
    const get_raw_mid = env.*.GetMethodID.?(
        env,
        ctrl_cls,
        "getRawMessage$MandaGram",
        "(JJ)Lit/tdlight/jni/TdApi$Message;",
    ) orelse {
        if (env.*.ExceptionClear) |clear| clear(env);
        return null;
    };

    const raw_msg = env.*.CallObjectMethod.?(env, conv_ctrl, get_raw_mid, msg_id, chat_id);
    if (raw_msg == null) return null;

    const raw_cls = JniAccessor.getObjectClass(env, raw_msg) orelse return null;
    const content_fid = env.*.GetFieldID.?(
        env,
        raw_cls,
        "content",
        "Lit/tdlight/jni/TdApi$MessageContent;",
    ) orelse {
        if (env.*.ExceptionClear) |clear| clear(env);
        return null;
    };

    const content_obj = env.*.GetObjectField.?(env, raw_msg, content_fid);
    if (content_obj == null) return null;

    const content_cls = JniAccessor.getObjectClass(env, content_obj) orelse return null;

    // 1. MessageText -> text
    const msg_text_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$MessageText");
    if (msg_text_cls != null and env.*.IsInstanceOf.?(env, content_obj, msg_text_cls.?) != 0) {
        const text_fid = env.*.GetFieldID.?(env, content_cls, "text", "Lit/tdlight/jni/TdApi$FormattedText;");
        if (text_fid != null) {
            return env.*.GetObjectField.?(env, content_obj, text_fid.?);
        }
    }

    // 2. Photo / Video / Animation / Document / Audio / Voice -> caption
    const caption_fid = env.*.GetFieldID.?(env, content_cls, "caption", "Lit/tdlight/jni/TdApi$FormattedText;");
    if (caption_fid != null) {
        return env.*.GetObjectField.?(env, content_obj, caption_fid.?);
    }
    if (env.*.ExceptionClear) |clear| clear(env);

    return null;
}

fn extractMessageItemDetails(
    env: *JNIEnv,
    msg_item: jobject,
    target: *PendingQuoteState,
) void {
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
            const slice = std.mem.span(chars);
            const copy_len = @min(slice.len, target.author_buf.len);
            @memcpy(target.author_buf[0..copy_len], slice[0..copy_len]);
            target.author_len = copy_len;
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
            const slice = std.mem.span(chars);
            const copy_len = @min(slice.len, target.text_buf.len);
            @memcpy(target.text_buf[0..copy_len], slice[0..copy_len]);
            target.text_len = copy_len;
        }
    }

    // 3. Time (formattedTime)
    target.time_len = 0;
    const get_time_mid = env.*.GetMethodID.?(env, item_cls, "getFormattedTime", "()Ljava/lang/String;");
    const j_time = if (get_time_mid) |mid| env.*.CallObjectMethod.?(env, msg_item, mid) else null;
    if (j_time != null) {
        if (JniAccessor.getStringUtfChars(env, j_time)) |chars| {
            defer JniAccessor.releaseStringUtfChars(env, j_time, chars);
            const slice = std.mem.span(chars);
            const copy_len = @min(slice.len, target.time_buf.len);
            @memcpy(target.time_buf[0..copy_len], slice[0..copy_len]);
            target.time_len = copy_len;
        }
    }

    // 4. Avatar (senderAvatarPath)
    target.avatar_len = 0;
    const get_avatar_mid = env.*.GetMethodID.?(env, item_cls, "getSenderAvatarPath", "()Ljava/lang/String;");
    const j_avatar = if (get_avatar_mid) |mid| env.*.CallObjectMethod.?(env, msg_item, mid) else null;
    if (j_avatar != null) {
        if (JniAccessor.getStringUtfChars(env, j_avatar)) |chars| {
            defer JniAccessor.releaseStringUtfChars(env, j_avatar, chars);
            const slice = std.mem.span(chars);
            const copy_len = @min(slice.len, target.avatar_buf.len);
            @memcpy(target.avatar_buf[0..copy_len], slice[0..copy_len]);
            target.avatar_len = copy_len;
        }
    }

    // 5. Initials (senderInitials)
    target.initials_len = 0;
    const get_initials_mid = env.*.GetMethodID.?(env, item_cls, "getSenderInitials", "()Ljava/lang/String;");
    const j_initials = if (get_initials_mid) |mid| env.*.CallObjectMethod.?(env, msg_item, mid) else null;
    if (j_initials != null) {
        if (JniAccessor.getStringUtfChars(env, j_initials)) |chars| {
            defer JniAccessor.releaseStringUtfChars(env, j_initials, chars);
            const slice = std.mem.span(chars);
            const copy_len = @min(slice.len, target.initials_buf.len);
            @memcpy(target.initials_buf[0..copy_len], slice[0..copy_len]);
            target.initials_len = copy_len;
        }
    }
}

fn findMessageDetailsInTelegramService(
    env: *JNIEnv,
    target_id: i64,
    target: *PendingQuoteState,
) bool {
    const service_cls = JniAccessor.findClass(env, "com/mandagram/network/TelegramService") orelse return false;
    const inst_fid = env.*.GetStaticFieldID.?(
        env,
        service_cls,
        "INSTANCE",
        "Lcom/mandagram/network/TelegramService;",
    ) orelse return false;
    const service_inst = env.*.GetStaticObjectField.?(env, service_cls, inst_fid) orelse return false;

    const get_messages_mid = env.*.GetMethodID.?(
        env,
        service_cls,
        "getMessages",
        "()Lkotlinx/coroutines/flow/StateFlow;",
    ) orelse return false;
    const flow_obj = env.*.CallObjectMethod.?(env, service_inst, get_messages_mid) orelse return false;

    const flow_cls = JniAccessor.getObjectClass(env, flow_obj) orelse return false;
    const get_val_mid = env.*.GetMethodID.?(
        env,
        flow_cls,
        "getValue",
        "()Ljava/lang/Object;",
    ) orelse return false;
    const list_obj = env.*.CallObjectMethod.?(env, flow_obj, get_val_mid) orelse return false;

    const list_cls = JniAccessor.getObjectClass(env, list_obj) orelse return false;
    const size_mid = env.*.GetMethodID.?(env, list_cls, "size", "()I") orelse return false;
    const get_mid = env.*.GetMethodID.?(env, list_cls, "get", "(I)Ljava/lang/Object;") orelse return false;

    const size = env.*.CallIntMethod.?(env, list_obj, size_mid);
    var i: i32 = size - 1;
    const min_i: i32 = if (size > 200) size - 200 else 0;
    while (i >= min_i) : (i -= 1) {
        const item = env.*.CallObjectMethod.?(env, list_obj, get_mid, i);
        if (item != null) {
            const item_id = JniAccessor.getLongField(env, item, "id");
            if (item_id == target_id) {
                extractMessageItemDetails(env, item, target);
                logFmt("[findMessageDetails] Found target message {d} (author: {d} bytes, text: {d} bytes, senderId: {d})", .{
                    target_id, target.author_len, target.text_len, target.sender_id,
                });
                return true;
            }
        }
    }
    return false;
}

fn isDiscussionGroup(env: *JNIEnv, chat_id: i64) bool {
    const service_cls = JniAccessor.findClass(env, "com/mandagram/network/TelegramService") orelse return false;
    const inst_fid = env.*.GetStaticFieldID.?(
        env,
        service_cls,
        "INSTANCE",
        "Lcom/mandagram/network/TelegramService;",
    ) orelse {
        if (env.*.ExceptionClear) |clear| clear(env);
        return false;
    };
    const service_inst = env.*.GetStaticObjectField.?(env, service_cls, inst_fid) orelse return false;

    const get_summary_mid = env.*.GetMethodID.?(
        env,
        service_cls,
        "getChatSummary",
        "(J)Lcom/mandagram/models/ChatSummary;",
    ) orelse {
        if (env.*.ExceptionClear) |clear| clear(env);
        return false;
    };

    const summary = env.*.CallObjectMethod.?(env, service_inst, get_summary_mid, chat_id);
    if (summary == null) return false;

    const summary_cls = JniAccessor.getObjectClass(env, summary) orelse return false;

    const is_replies_mid = env.*.GetMethodID.?(env, summary_cls, "isReplies", "()Z");
    if (is_replies_mid) |mid| {
        if (env.*.CallBooleanMethod.?(env, summary, mid) != 0) {
            return true;
        }
    } else {
        if (env.*.ExceptionClear) |clear| clear(env);
    }

    const is_forum_mid = env.*.GetMethodID.?(env, summary_cls, "isForum", "()Z");
    if (is_forum_mid) |mid| {
        if (env.*.CallBooleanMethod.?(env, summary, mid) != 0) {
            return true;
        }
    } else {
        if (env.*.ExceptionClear) |clear| clear(env);
    }

    return false;
}

// -----------------------------------------------------------------------------
// Isolated Headless Compose Renderer (ImageComposeScene -> In-Memory PNG)
// Zero OS/SkiaLayer Screenshots, Loaded dynamically into JVM via DefineClass (Zero .jar)
// -----------------------------------------------------------------------------

const BUBBLE_RENDERER_1 = @embedFile("bytecode/BubbleRendererV2$1.class");
const BUBBLE_RENDERER_2 = @embedFile("bytecode/BubbleRendererV2$2.class");
const BUBBLE_RENDERER_MAIN = @embedFile("bytecode/BubbleRendererV2.class");

const DefineClassFn = *const fn (
    env: *JNIEnv,
    name: ?[*:0]const u8,
    loader: jobject,
    buf: [*]const u8,
    len: jint,
) callconv(.c) jclass;

var bubble_renderer_class: ?jclass = null;

fn getAppClassLoader(env: *JNIEnv) ?jobject {
    const item_cls = JniAccessor.findClass(env, "com/mandagram/models/MessageItem") orelse {
        logErrFmt("[getAppClassLoader] findClass MessageItem failed", .{});
        return null;
    };
    const cls_cls = JniAccessor.getObjectClass(env, item_cls) orelse {
        logErrFmt("[getAppClassLoader] getObjectClass failed", .{});
        return null;
    };
    const mid = env.*.GetMethodID.?(
        env,
        cls_cls,
        "getClassLoader",
        "()Ljava/lang/ClassLoader;",
    ) orelse {
        logErrFmt("[getAppClassLoader] getClassLoader method not found", .{});
        return null;
    };
    return env.*.CallObjectMethod.?(env, item_cls, mid);
}

fn ensureBubbleRendererLoaded(env: *JNIEnv) ?jclass {
    if (bubble_renderer_class) |cls| return cls;

    if (env.*.FindClass.?(env, "com/mandagram/plugin/quotereply/BubbleRendererV2")) |existing| {
        bubble_renderer_class = env.*.NewGlobalRef.?(env, existing);
        return bubble_renderer_class;
    }
    if (env.*.ExceptionClear) |clear| clear(env);

    const loader = getAppClassLoader(env) orelse {
        logErrFmt("[ensureBubbleRendererLoaded] Failed to get ClassLoader", .{});
        return null;
    };

    const define_class: DefineClassFn = @ptrCast(env.*.DefineClass orelse {
        logErrFmt("[ensureBubbleRendererLoaded] DefineClass is null in JNIEnv", .{});
        return null;
    });

    _ = define_class(
        env,
        "com/mandagram/plugin/quotereply/BubbleRendererV2$1",
        loader,
        BUBBLE_RENDERER_1.ptr,
        @intCast(BUBBLE_RENDERER_1.len),
    );
    if (env.*.ExceptionClear) |clear| clear(env);

    _ = define_class(
        env,
        "com/mandagram/plugin/quotereply/BubbleRendererV2$2",
        loader,
        BUBBLE_RENDERER_2.ptr,
        @intCast(BUBBLE_RENDERER_2.len),
    );
    if (env.*.ExceptionClear) |clear| clear(env);

    const cls = define_class(
        env,
        "com/mandagram/plugin/quotereply/BubbleRendererV2",
        loader,
        BUBBLE_RENDERER_MAIN.ptr,
        @intCast(BUBBLE_RENDERER_MAIN.len),
    );
    if (cls == null) {
        logErrFmt("[ensureBubbleRendererLoaded] DefineClass returned null for BubbleRendererV2", .{});
        if (env.*.ExceptionClear) |clear| clear(env);
        return null;
    }

    bubble_renderer_class = env.*.NewGlobalRef.?(env, cls);
    logFmt("[ensureBubbleRendererLoaded] BubbleRendererV2 successfully loaded into JVM via JNI DefineClass!", .{});
    return bubble_renderer_class;
}

fn renderMessageItemToFile(env: *JNIEnv, msg_item: jobject, out_path_buf: []u8) ?[:0]const u8 {
    const renderer_cls = ensureBubbleRendererLoaded(env) orelse {
        logErrFmt("[renderMessageItemToFile] ensureBubbleRendererLoaded failed", .{});
        return null;
    };

    const mid = env.*.GetStaticMethodID.?(
        env,
        renderer_cls,
        "renderMessageToFile",
        "(Lcom/mandagram/models/MessageItem;Ljava/lang/String;)Ljava/lang/String;",
    ) orelse {
        logErrFmt("[renderMessageItemToFile] renderMessageToFile method not found", .{});
        if (env.*.ExceptionClear) |clear| clear(env);
        return null;
    };

    const j_res = env.*.CallStaticObjectMethod.?(env, renderer_cls, mid, msg_item, @as(jobject, null));
    if (j_res == null) {
        logErrFmt("[renderMessageItemToFile] renderMessageToFile returned null", .{});
        if (env.*.ExceptionClear) |clear| clear(env);
        return null;
    }

    if (JniAccessor.getStringUtfChars(env, j_res)) |chars| {
        defer JniAccessor.releaseStringUtfChars(env, j_res, chars);
        const slice = std.mem.span(chars);
        const copy_len = @min(slice.len, out_path_buf.len - 1);
        @memcpy(out_path_buf[0..copy_len], slice[0..copy_len]);
        out_path_buf[copy_len] = 0;
        logFmt("[renderMessageItemToFile] Successfully rendered authentic Compose bubble to {s}!", .{out_path_buf[0..copy_len]});
        return out_path_buf[0..copy_len :0];
    }
    return null;
}

fn findMessageItemInTelegramService(env: *JNIEnv, target_id: i64) ?jobject {
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
                return item;
            }
        }
    }
    return null;
}

// -----------------------------------------------------------------------------
// Hook 1: ChatComposerActions#beginReply (Lcom/mandagram/models/MessageItem;)V
// -----------------------------------------------------------------------------

fn on_before_begin_reply(param: *HookParam) callconv(.c) void {
    const env = param.getEnv() orelse return;
    if (param.args_count < 1) return;
    const msg_item = param.args[0] orelse return;

    const msg_id = JniAccessor.getLongField(env, msg_item, "id");
    if (msg_id == 0) return;

    quote_mutex.lock();
    extractMessageItemDetails(env, msg_item, &pending_quote);
    pending_quote.captured_path_len = 0; // reset previous capture
    if (cached_message_item) |old_ref| {
        env.*.DeleteGlobalRef.?(env, old_ref);
    }
    cached_message_item = env.*.NewGlobalRef.?(env, msg_item);
    const captured_msg_id = pending_quote.msg_id;
    const captured_author = pending_quote.author_len;
    const captured_len = pending_quote.text_len;
    quote_mutex.unlock();

    logFmt("[beginReply] Intercepted reply to target {d} (author: {d} bytes, text: {d} bytes), pre-rendering authentic bubble...", .{
        captured_msg_id, captured_author, captured_len,
    });

    var render_buf: [512]u8 = undefined;
    if (renderMessageItemToFile(env, msg_item, &render_buf)) |rendered_path| {
        quote_mutex.lock();
        if (pending_quote.msg_id == captured_msg_id) {
            const copy_len = @min(rendered_path.len, pending_quote.captured_path_buf.len - 1);
            @memcpy(pending_quote.captured_path_buf[0..copy_len], rendered_path[0..copy_len]);
            pending_quote.captured_path_buf[copy_len] = 0;
            pending_quote.captured_path_len = copy_len;
            logFmt("[beginReply] Successfully pre-rendered authentic bubble: {s}", .{rendered_path});
        }
        quote_mutex.unlock();
    }
}

// -----------------------------------------------------------------------------
// Hook 2: ChatComposerActions#sendDraft ()V
// -----------------------------------------------------------------------------

fn on_before_send_draft(param: *HookParam) callconv(.c) void {
    const env = param.getEnv() orelse return;
    const this_obj = param.this_ptr orelse return;

    logFmt("[sendDraft] Hook invoked", .{});

    // Get ComposerDraftEntry via access$getEntry$p
    const actions_cls = JniAccessor.getObjectClass(env, this_obj) orelse return;
    const get_entry_mid = env.*.GetStaticMethodID.?(
        env,
        actions_cls,
        "access$getEntry$p",
        "(Lcom/mandagram/ui/chat/ChatComposerActions;)Lcom/mandagram/ui/chat/ComposerDraftEntry;",
    ) orelse {
        logErrFmt("[sendDraft] Failed to find access$getEntry$p", .{});
        return;
    };

    const entry_obj = env.*.CallStaticObjectMethod.?(env, actions_cls, get_entry_mid, this_obj);
    if (entry_obj == null) {
        logErrFmt("[sendDraft] entry_obj is null", .{});
        return;
    }

    // Check entry.getReply()
    const entry_cls = JniAccessor.getObjectClass(env, entry_obj) orelse return;
    const get_reply_mid = env.*.GetMethodID.?(
        env,
        entry_cls,
        "getReply",
        "()Lcom/mandagram/models/MessageItem;",
    ) orelse {
        logErrFmt("[sendDraft] Failed to find getReply method", .{});
        return;
    };

    const reply_item = env.*.CallObjectMethod.?(env, entry_obj, get_reply_mid);
    if (reply_item == null) {
        logFmt("[sendDraft] No reply attached to draft (entry.getReply() is null)", .{});
        return;
    }

    const reply_id = JniAccessor.getLongField(env, reply_item, "id");
    quote_mutex.lock();
    const already_rendered = (pending_quote.msg_id == reply_id and pending_quote.captured_path_len > 0);
    if (!already_rendered) {
        extractMessageItemDetails(env, reply_item, &pending_quote);
        if (cached_message_item) |old_ref| {
            env.*.DeleteGlobalRef.?(env, old_ref);
        }
        cached_message_item = env.*.NewGlobalRef.?(env, reply_item);
    }
    quote_mutex.unlock();

    if (!already_rendered) {
        logFmt("[sendDraft] Target message {d} not pre-rendered, rendering authentic headless bubble now...", .{reply_id});
        var render_buf: [512]u8 = undefined;
        if (renderMessageItemToFile(env, reply_item, &render_buf)) |rendered_path| {
            quote_mutex.lock();
            if (pending_quote.msg_id == reply_id) {
                const copy_len = @min(rendered_path.len, pending_quote.captured_path_buf.len - 1);
                @memcpy(pending_quote.captured_path_buf[0..copy_len], rendered_path[0..copy_len]);
                pending_quote.captured_path_buf[copy_len] = 0;
                pending_quote.captured_path_len = copy_len;
                logFmt("[sendDraft] Successfully rendered authentic bubble: {s}", .{rendered_path});
            }
            quote_mutex.unlock();
        }
    }
}

// -----------------------------------------------------------------------------
// Hook 3 & 4: Outgoing SendMessage Transformation (Text -> Photo with Caption)
// -----------------------------------------------------------------------------

fn handle_send_function(env: *JNIEnv, source_hook: [*:0]const u8, func_obj: jobject) void {
    if (func_obj == null) return;

    const send_msg_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$SendMessage");
    const is_send_msg = (send_msg_cls != null and env.*.IsInstanceOf.?(env, func_obj, send_msg_cls.?) != 0);

    if (!is_send_msg) return;

    const chat_id = JniAccessor.getLongField(env, func_obj, "chatId");
    logFmt("[{s}] Intercepted outgoing SendMessage for chat {d}", .{ source_hook, chat_id });

    if (disable_in_discussions and chat_id != 0 and isDiscussionGroup(env, chat_id)) {
        logFmt("[{s}] Quote disabled: discussion/comments channel detected for chat {d}", .{ source_hook, chat_id });
        return;
    }

    // 1. Get replyTo
    const reply_to = JniAccessor.getObjectField(env, func_obj, "replyTo", "Lit/tdlight/jni/TdApi$InputMessageReplyTo;");
    if (reply_to == null) {
        logFmt("[{s}] replyTo is null (standalone message, not a reply)", .{source_hook});
        return;
    }

    const reply_msg_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputMessageReplyToMessage") orelse return;
    if (env.*.IsInstanceOf.?(env, reply_to, reply_msg_cls) == 0) {
        logFmt("[{s}] replyTo is not InputMessageReplyToMessage", .{source_hook});
        return;
    }

    const msg_id = JniAccessor.getLongField(env, reply_to, "messageId");
    logFmt("[{s}] Outgoing reply target messageId: {d}", .{ source_hook, msg_id });
    if (msg_id == 0) return;

    // 2. Check inputMessageContent
    const input_content = JniAccessor.getObjectField(env, func_obj, "inputMessageContent", "Lit/tdlight/jni/TdApi$InputMessageContent;");
    if (input_content == null) return;

    const msg_photo_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputMessagePhoto");
    if (msg_photo_cls != null and env.*.IsInstanceOf.?(env, input_content, msg_photo_cls.?) != 0) {
        logFmt("[{s}] inputMessageContent is already InputMessagePhoto (skipping duplicate transformation)", .{source_hook});
        return;
    }

    const msg_text_cls = JniAccessor.findClass(env, "it/tdlight/jni/TdApi$InputMessageText");
    const is_text = (msg_text_cls != null and env.*.IsInstanceOf.?(env, input_content, msg_text_cls.?) != 0);

    if (!is_text) {
        logFmt("[{s}] inputMessageContent is not InputMessageText (media/other), keeping original content", .{source_hook});
        return;
    }

    // 3. Extract the outgoing text (to become caption of the photo)
    const outgoing_caption = JniAccessor.getObjectField(env, input_content, "text", "Lit/tdlight/jni/TdApi$FormattedText;");

    // 4. Retrieve author name, quoted text, time, avatar, initials
    var author_buf: [256]u8 = undefined;
    var author_slice: []const u8 = "Цитата";
    var text_buf: [4096]u8 = undefined;
    var text_slice: []const u8 = "";
    var time_buf: [32]u8 = undefined;
    var time_slice: []const u8 = "12:00";
    var avatar_buf: [512]u8 = undefined;
    var avatar_slice: ?[]const u8 = null;
    var initials_buf: [16]u8 = undefined;
    var initials_slice: []const u8 = "TG";
    var target_sender_id: i64 = 0;

    quote_mutex.lock();
    if (pending_quote.msg_id != msg_id or pending_quote.text_len == 0) {
        _ = findMessageDetailsInTelegramService(env, msg_id, &pending_quote);
    }

    if (pending_quote.msg_id == msg_id) {
        target_sender_id = pending_quote.sender_id;
        if (pending_quote.author_len > 0) {
            const a_len = @min(pending_quote.author_len, author_buf.len);
            @memcpy(author_buf[0..a_len], pending_quote.author_buf[0..a_len]);
            author_slice = author_buf[0..a_len];
        }
        if (pending_quote.text_len > 0) {
            const t_len = @min(pending_quote.text_len, text_buf.len);
            @memcpy(text_buf[0..t_len], pending_quote.text_buf[0..t_len]);
            text_slice = text_buf[0..t_len];
        }
        if (pending_quote.time_len > 0) {
            const tm_len = @min(pending_quote.time_len, time_buf.len);
            @memcpy(time_buf[0..tm_len], pending_quote.time_buf[0..tm_len]);
            time_slice = time_buf[0..tm_len];
        }
        if (pending_quote.avatar_len > 0) {
            const av_len = @min(pending_quote.avatar_len, avatar_buf.len);
            @memcpy(avatar_buf[0..av_len], pending_quote.avatar_buf[0..av_len]);
            avatar_slice = avatar_buf[0..av_len];
        }
        if (pending_quote.initials_len > 0) {
            const in_len = @min(pending_quote.initials_len, initials_buf.len);
            @memcpy(initials_buf[0..in_len], pending_quote.initials_buf[0..in_len]);
            initials_slice = initials_buf[0..in_len];
        }
    }
    quote_mutex.unlock();

    if (text_slice.len == 0) {
        // Try raw TDLib message
        if (getRawFormattedText(env, chat_id, msg_id)) |raw_fmt| {
            if (getFormattedTextString(env, raw_fmt, &text_buf)) |t| {
                text_slice = t;
            }
        }
    }

    if (text_slice.len == 0) {
        text_slice = "💬 [Сообщение]";
    }

    logFmt("[{s}] Generating native quote photo card for author '{s}' (time: '{s}', senderId: {d}, quote: {d} bytes)...", .{
        source_hook, author_slice, time_slice, target_sender_id, text_slice.len
    });

    // 5. Check if we already have authentic UI card PNG for this message
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
        logFmt("[{s}] Bubble not pre-rendered, attempting live headless Compose render...", .{source_hook});
        var target_item: ?jobject = null;
        if (item_ref) |ref| {
            const cur_id = JniAccessor.getLongField(env, ref, "id");
            if (cur_id == msg_id) {
                target_item = ref;
            }
        }
        if (target_item == null) {
            target_item = findMessageItemInTelegramService(env, msg_id);
        }

        if (target_item) |item| {
            photo_path = renderMessageItemToFile(env, item, &captured_buf);
        }
    }

    if (photo_path) |rendered_bubble| {
        logFmt("[{s}] Using pixel-perfect authentic Compose message bubble PNG: {s}", .{ source_hook, rendered_bubble });
    } else {
        logErrFmt("[{s}] FAILED to render authentic Compose message bubble!", .{source_hook});
        return;
    }

    if (photo_path == null) {
        logErrFmt("[{s}] FAILED to obtain quote image!", .{source_hook});
        return;
    }

    logFmt("[{s}] Quote photo prepared at: {s}", .{ source_hook, photo_path.? });

    // 6. Create TdApi$InputMessagePhoto with the photo path and caption
    const input_photo_msg = createInputMessagePhoto(env, photo_path.?, outgoing_caption);
    if (input_photo_msg == null) {
        logErrFmt("[{s}] FAILED to create TdApi$InputMessagePhoto", .{source_hook});
        return;
    }

    // 7. Replace inputMessageContent in SendMessage
    JniAccessor.setObjectField(env, func_obj, "inputMessageContent", "Lit/tdlight/jni/TdApi$InputMessageContent;", input_photo_msg.?);
    logFmt("[{s}] SUCCESS: Replaced SendMessage.inputMessageContent with InputMessagePhoto!", .{source_hook});

    // 8. Also inject InputTextQuote into replyTo for complete MTProto quote support
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
    const env = param.getEnv() orelse return;
    var i: u32 = 0;
    while (i < param.args_count) : (i += 1) {
        if (param.args[i]) |arg| {
            handle_send_function(env, "requestForSession", arg);
        }
    }
}

fn on_before_client_send(param: *HookParam) callconv(.c) void {
    const env = param.getEnv() orelse return;
    var i: u32 = 0;
    while (i < param.args_count) : (i += 1) {
        if (param.args[i]) |arg| {
            handle_send_function(env, "client.send", arg);
        }
    }
}

// -----------------------------------------------------------------------------
// Settings & Initialization
// -----------------------------------------------------------------------------

fn on_toggle_setting_click(chat_id: i64, user_data: usize) callconv(.c) void {
    _ = chat_id;
    _ = user_data;
    disable_in_discussions = !disable_in_discussions;
    if (disable_in_discussions) {
        logFmt("[Settings] Quote in discussions is now DISABLED", .{});
    } else {
        logFmt("[Settings] Quote in discussions is now ENABLED", .{});
    }
}

pub export fn mandagram_plugin_init(api: *const PluginApi) callconv(.c) bool {
    global_api = api;
    api.log_info("KvoteReply", "Initializing KvoteReply plugin v1.0.0 (by OwnerTS)");

    // 1. Hook ChatComposerActions#beginReply (Lcom/mandagram/models/MessageItem;)V
    const res0 = api.register_hook(
        "com/mandagram/ui/chat/ChatComposerActions",
        "beginReply",
        "(Lcom/mandagram/models/MessageItem;)V",
        on_before_begin_reply,
        null,
    );

    // 2. Hook ChatComposerActions#sendDraft ()V
    const res1 = api.register_hook(
        "com/mandagram/ui/chat/ChatComposerActions",
        "sendDraft",
        "()V",
        on_before_send_draft,
        null,
    );

    // 3. Hook TdLibSession#requestForSession (any overload)
    const res2 = api.register_hook(
        "com/mandagram/network/engine/TdLibSession",
        "requestForSession",
        null,
        on_before_request_for_session,
        null,
    );

    // 4. Hook SimpleTelegramClient#send (any overload)
    const res3 = api.register_hook(
        "it/tdlight/client/SimpleTelegramClient",
        "send",
        null,
        on_before_client_send,
        null,
    );

    logFmt(
        "Hook registration results: beginReply={s}, sendDraft={s}, TdLibSession.requestForSession={s}, SimpleTelegramClient.send={s}",
        .{
            if (res0 == 0) "OK" else "FAILED",
            if (res1 == 0) "OK" else "FAILED",
            if (res2 == 0) "OK" else "FAILED",
            if (res3 == 0) "OK" else "FAILED",
        },
    );

    if (api.register_chat_action) |reg_action| {
        _ = reg_action("toggle_discussions", "KvoteReply: Toggle Discussion Quotes", on_toggle_setting_click, 0);
    }

    return true;
}

pub export fn mandagram_plugin_unload() callconv(.c) void {
    if (global_api) |api| {
        api.log_info("KvoteReply", "Unloading KvoteReply plugin v1.0.0");
    }
    quote_mutex.lock();
    pending_quote = .{};
    if (cached_message_item) |old_ref| {
        if (global_api) |_| {
            // JVM reference cleanup
        }
        cached_message_item = null;
        _ = old_ref;
    }
    bubble_renderer_class = null;
    quote_mutex.unlock();
}

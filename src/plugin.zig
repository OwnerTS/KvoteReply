//! ============================================================================
//! KvoteReply v2.0.0 — Pure FFI Native Quote Renderer Plugin for MandaGram
//!
//! Данный плагин перехватывает исходящие ответы на сообщения в Telegram и
//! превращает их в фото-цитаты с аутентичным внешним видом карточек сообщений:
//! - Полная совместимость с чистой FFI плагин-системой MandaGram (53 слота,
//!   40-байтный HookParam layout, zero overhead).
//! - Автономный нативный рендерер карточек цитат с типографикой (ASCII + Cyrillic),
//!   аватаром с инициалами автора и цветовыми акцентами.
//! - Встроенный PNG-энкодер со сжатием Deflate без внешних зависимостей.
//! - Интеграция с TDLib через execute_tdlib_query и hook отправки сообщений.
//! ============================================================================

const std = @import("std");

// =============================================================================
// FFI Plugin API Definition (MandaGram Pure FFI Host Interface)
// =============================================================================

/// Структура параметров вызова перехватчика (Memory Layout: 40 байт).
/// Соответствует HOOK_PARAM_LAYOUT в PluginBridge.kt ядра MandaGram.
pub const HookParam = extern struct {
    this_ptr: ?*anyopaque,
    args: [*]?*anyopaque,
    args_count: i32,
    padding: i32,
    result: ?*anyopaque,
    return_early: u8,
    has_result: u8,
    reserved: u16,
    padding2: u32,

    pub inline fn cancel(self: *HookParam) void {
        self.return_early = 1;
    }

    pub inline fn setResult(self: *HookParam, res: ?*anyopaque) void {
        self.result = res;
        self.has_result = 1;
        self.return_early = 1;
    }
};

/// Метаданные плагина
pub const PluginMetadata = extern struct {
    name: [*:0]const u8,
    version: [*:0]const u8,
    author: [*:0]const u8,
    description: [*:0]const u8,
};

/// Таблица указателей на функции интерфейса MandaGram Plugin API (53 слота)
pub const PluginApi = extern struct {
    // 0..8: Базовые сервисы и TDLib
    register_hook: ?*const fn (class_name: [*:0]const u8, method_name: [*:0]const u8, descriptor: ?[*:0]const u8, before_cb: ?*const fn (param: *HookParam) callconv(.c) void, after_cb: ?*const fn (param: *HookParam) callconv(.c) void) callconv(.c) i32,
    log_info: ?*const fn (tag: [*:0]const u8, msg: [*:0]const u8) callconv(.c) void,
    log_error: ?*const fn (tag: [*:0]const u8, msg: [*:0]const u8) callconv(.c) void,
    get_storage_dir: ?*const fn (plugin_name: [*:0]const u8, out_buf: [*]u8, max_len: i32) callconv(.c) i32,
    get_cache_dir: ?*const fn (plugin_name: [*:0]const u8, out_buf: [*]u8, max_len: i32) callconv(.c) i32,
    resolve_asset: ?*const fn (plugin_name: [*:0]const u8, asset_name: [*:0]const u8, out_buf: [*]u8, max_len: i32) callconv(.c) i32,
    get_current_user_id: ?*const fn () callconv(.c) i64,
    get_active_chat_id: ?*const fn () callconv(.c) i64,
    execute_tdlib_query: ?*const fn (json_query: [*:0]const u8, out_buf: [*]u8, max_len: i32) callconv(.c) i32,

    // 9..16: Compose Runtime Lambda & Composer Stubs
    create_composable_lambda: ?*const fn (render_fn: ?*const anyopaque, user_data: usize) callconv(.c) ?*anyopaque,
    create_scoped_lambda: ?*const fn (render_fn: ?*const anyopaque, user_data: usize) callconv(.c) ?*anyopaque,
    replace_composable: ?*const fn (slot_name: [*:0]const u8, render_fn: ?*const anyopaque, user_data: usize) callconv(.c) void,
    composer_start_group: ?*const fn (composer: ?*anyopaque, key: i32) callconv(.c) void,
    composer_end_group: ?*const fn (composer: ?*anyopaque) callconv(.c) void,
    composer_get_remembered: ?*const fn (composer: ?*anyopaque) callconv(.c) ?*anyopaque,
    composer_set_remembered: ?*const fn (composer: ?*anyopaque, value: ?*anyopaque) callconv(.c) void,
    composer_is_skipping: ?*const fn (composer: ?*anyopaque) callconv(.c) bool,

    // 17..20: Регистрация хуков сообщений и действий
    register_update_hook: ?*const fn (callback: ?*const fn (update_json: [*:0]const u8, user_data: usize) callconv(.c) bool, user_data: usize) callconv(.c) i32,
    register_message_send_hook: ?*const fn (before_cb: ?*const fn (chat_id: i64, text: [*:0]const u8, user_data: usize) callconv(.c) ?[*:0]const u8, after_cb: ?*const fn (chat_id: i64, message_id: i64, user_data: usize) callconv(.c) void, user_data: usize) callconv(.c) i32,
    register_message_receive_hook: ?*const fn (callback: ?*const fn (chat_id: i64, message_id: i64, text: [*:0]const u8, user_data: usize) callconv(.c) void, user_data: usize) callconv(.c) i32,
    register_chat_action: ?*const fn (id: [*:0]const u8, label: [*:0]const u8, click_cb: ?*const fn (chat_id: i64, user_data: usize) callconv(.c) void, user_data: usize) callconv(.c) i32,

    // 21..34: Рефлексия полей объектов и доступ к состоянию
    get_object_field: ?*const fn (obj: ?*anyopaque, field_name: [*:0]const u8) callconv(.c) ?*anyopaque,
    set_object_field: ?*const fn (obj: ?*anyopaque, field_name: [*:0]const u8, value: ?*anyopaque) callconv(.c) void,
    get_int_field: ?*const fn (obj: ?*anyopaque, field_name: [*:0]const u8) callconv(.c) i32,
    set_int_field: ?*const fn (obj: ?*anyopaque, field_name: [*:0]const u8, value: i32) callconv(.c) void,
    get_long_field: ?*const fn (obj: ?*anyopaque, field_name: [*:0]const u8) callconv(.c) i64,
    set_long_field: ?*const fn (obj: ?*anyopaque, field_name: [*:0]const u8, value: i64) callconv(.c) void,
    get_bool_field: ?*const fn (obj: ?*anyopaque, field_name: [*:0]const u8) callconv(.c) bool,
    set_bool_field: ?*const fn (obj: ?*anyopaque, field_name: [*:0]const u8, value: bool) callconv(.c) void,
    get_string_utf: ?*const fn (obj: ?*anyopaque, out_buf: [*]u8, max_len: i32) callconv(.c) i32,
    create_string_utf: ?*const fn (utf_str: [*:0]const u8) callconv(.c) ?*anyopaque,
    get_attached_field: ?*const fn (obj: ?*anyopaque, key: [*:0]const u8) callconv(.c) ?*anyopaque,
    set_attached_field: ?*const fn (obj: ?*anyopaque, key: [*:0]const u8, value: ?*anyopaque) callconv(.c) void,
    get_state_value: ?*const fn (state_obj: ?*anyopaque) callconv(.c) ?*anyopaque,
    set_state_value: ?*const fn (state_obj: ?*anyopaque, value: ?*anyopaque) callconv(.c) void,

    // 35..45: Модификаторы Compose UI
    modifier_empty: ?*const fn () callconv(.c) ?*anyopaque,
    modifier_size: ?*const fn (mod: ?*anyopaque, width_dp: f32, height_dp: f32) callconv(.c) ?*anyopaque,
    modifier_width: ?*const fn (mod: ?*anyopaque, width_dp: f32) callconv(.c) ?*anyopaque,
    modifier_height: ?*const fn (mod: ?*anyopaque, height_dp: f32) callconv(.c) ?*anyopaque,
    modifier_fill_max_width: ?*const fn (mod: ?*anyopaque) callconv(.c) ?*anyopaque,
    modifier_fill_max_height: ?*const fn (mod: ?*anyopaque) callconv(.c) ?*anyopaque,
    modifier_padding: ?*const fn (mod: ?*anyopaque, start_dp: f32, top_dp: f32, end_dp: f32, bottom_dp: f32) callconv(.c) ?*anyopaque,
    modifier_background: ?*const fn (mod: ?*anyopaque, color_argb: u32, corner_radius_dp: f32) callconv(.c) ?*anyopaque,
    modifier_border: ?*const fn (mod: ?*anyopaque, width_dp: f32, color_argb: u32, corner_radius_dp: f32) callconv(.c) ?*anyopaque,
    modifier_clickable: ?*const fn (mod: ?*anyopaque, on_click: ?*const fn () callconv(.c) void) callconv(.c) ?*anyopaque,
    modifier_weight: ?*const fn (mod: ?*anyopaque, row_or_col_scope: ?*anyopaque, weight: f32) callconv(.c) ?*anyopaque,

    // 46..52: Компоненты Compose UI
    compose_row: ?*const fn (composer: ?*anyopaque, modifier: ?*anyopaque, content_lambda: ?*anyopaque) callconv(.c) void,
    compose_column: ?*const fn (composer: ?*anyopaque, modifier: ?*anyopaque, content_lambda: ?*anyopaque) callconv(.c) void,
    compose_box: ?*const fn (composer: ?*anyopaque, modifier: ?*anyopaque, content_lambda: ?*anyopaque) callconv(.c) void,
    compose_spacer: ?*const fn (composer: ?*anyopaque, modifier: ?*anyopaque) callconv(.c) void,
    compose_text: ?*const fn (composer: ?*anyopaque, text: [*:0]const u8, modifier: ?*anyopaque, color_argb: u32, font_size_sp: f32, is_bold: bool, max_lines: i32) callconv(.c) void,
    compose_image: ?*const fn (composer: ?*anyopaque, bitmap: ?*anyopaque, modifier: ?*anyopaque) callconv(.c) void,
    get_avatar_bitmap: ?*const fn (chat_or_user_id: i64) callconv(.c) ?*anyopaque,
};

// =============================================================================
// Typography & 8x16 Bitmap Font (ASCII + Cyrillic)
// =============================================================================

pub const GLYPH_WIDTH = 8;
pub const GLYPH_HEIGHT = 16;

const GLYPH_UNKNOWN = [16]u8{
    0x00, 0x7E, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42,
    0x42, 0x42, 0x42, 0x42, 0x42, 0x7E, 0x00, 0x00,
};

const GLYPH_LEFT_GUILLEMET = [16]u8{
    0x00, 0x00, 0x00, 0x00, 0x00, 0x33, 0x66, 0xCC,
    0x66, 0x33, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

const GLYPH_RIGHT_GUILLEMET = [16]u8{
    0x00, 0x00, 0x00, 0x00, 0x00, 0xCC, 0x66, 0x33,
    0x66, 0xCC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

const GLYPH_DASH = [16]u8{
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

const GLYPH_ELLIPSIS = [16]u8{
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x49, 0x00, 0x00, 0x00,
};

const GLYPH_YO_UPPER = [16]u8{
    0x66, 0x00, 0x7F, 0x40, 0x40, 0x40, 0x7E, 0x40,
    0x40, 0x40, 0x40, 0x7F, 0x00, 0x00, 0x00, 0x00,
};

const GLYPH_YO_LOWER = [16]u8{
    0x66, 0x00, 0x00, 0x3C, 0x42, 0x42, 0x7E, 0x40,
    0x40, 0x42, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00,
};

const ASCII_GLYPHS = [95][16]u8{
    [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ' '
    [_]u8{ 0x00, 0x00, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00 }, // '!'
    [_]u8{ 0x00, 0x66, 0x66, 0x66, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '"'
    [_]u8{ 0x00, 0x00, 0x24, 0x24, 0x7E, 0x24, 0x24, 0x24, 0x7E, 0x24, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '#'
    [_]u8{ 0x00, 0x18, 0x3E, 0x60, 0x60, 0x3C, 0x06, 0x06, 0x7C, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '$'
    [_]u8{ 0x00, 0x00, 0x62, 0x64, 0x08, 0x10, 0x26, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '%'
    [_]u8{ 0x00, 0x00, 0x38, 0x44, 0x44, 0x38, 0x54, 0x4A, 0x44, 0x3A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '&'
    [_]u8{ 0x00, 0x18, 0x18, 0x08, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '\''
    [_]u8{ 0x00, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '('
    [_]u8{ 0x00, 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ')'
    [_]u8{ 0x00, 0x00, 0x18, 0x5A, 0x3C, 0x5A, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '*'
    [_]u8{ 0x00, 0x00, 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '+'
    [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x08, 0x10, 0x00, 0x00, 0x00 }, // ','
    [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '-'
    [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '.'
    [_]u8{ 0x00, 0x02, 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '/'
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '0'
    [_]u8{ 0x00, 0x00, 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '1'
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x7E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '2'
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '3'
    [_]u8{ 0x00, 0x00, 0x0C, 0x1C, 0x2C, 0x4C, 0x7E, 0x0C, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '4'
    [_]u8{ 0x00, 0x00, 0x7E, 0x40, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '5'
    [_]u8{ 0x00, 0x00, 0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '6'
    [_]u8{ 0x00, 0x00, 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '7'
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '8'
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x38, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '9'
    [_]u8{ 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ':'
    [_]u8{ 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x08, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ';'
    [_]u8{ 0x00, 0x00, 0x06, 0x18, 0x60, 0x18, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '<'
    [_]u8{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '='
    [_]u8{ 0x00, 0x00, 0x60, 0x18, 0x06, 0x18, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '>'
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x0C, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '?'
    [_]u8{ 0x00, 0x00, 0x3C, 0x42, 0x99, 0xA5, 0xA5, 0x9E, 0x40, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '@'
    [_]u8{ 0x00, 0x00, 0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'A'
    [_]u8{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'B'
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'C'
    [_]u8{ 0x00, 0x00, 0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'D'
    [_]u8{ 0x00, 0x00, 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'E'
    [_]u8{ 0x00, 0x00, 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'F'
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'G'
    [_]u8{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'H'
    [_]u8{ 0x00, 0x00, 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'I'
    [_]u8{ 0x00, 0x00, 0x0E, 0x06, 0x06, 0x06, 0x06, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'J'
    [_]u8{ 0x00, 0x00, 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'K'
    [_]u8{ 0x00, 0x00, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'L'
    [_]u8{ 0x00, 0x00, 0x63, 0x77, 0x7F, 0x6B, 0x63, 0x63, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'M'
    [_]u8{ 0x00, 0x00, 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'N'
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'O'
    [_]u8{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'P'
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x66, 0x6C, 0x36, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'Q'
    [_]u8{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'R'
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'S'
    [_]u8{ 0x00, 0x00, 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'T'
    [_]u8{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'U'
    [_]u8{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'V'
    [_]u8{ 0x00, 0x00, 0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'W'
    [_]u8{ 0x00, 0x00, 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'X'
    [_]u8{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'Y'
    [_]u8{ 0x00, 0x00, 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'Z'
    [_]u8{ 0x00, 0x1E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x1E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '['
    [_]u8{ 0x00, 0x80, 0xC0, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '\'
    [_]u8{ 0x00, 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ']'
    [_]u8{ 0x00, 0x18, 0x3C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '^'
    [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '_'
    [_]u8{ 0x00, 0x18, 0x0C, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '`'
    [_]u8{ 0x00, 0x00, 0x00, 0x3C, 0x06, 0x3E, 0x66, 0x66, 0x3E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'a'
    [_]u8{ 0x00, 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x7C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'b'
    [_]u8{ 0x00, 0x00, 0x00, 0x3C, 0x66, 0x60, 0x60, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'c'
    [_]u8{ 0x00, 0x06, 0x06, 0x3E, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'd'
    [_]u8{ 0x00, 0x00, 0x00, 0x3C, 0x66, 0x7E, 0x60, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'e'
    [_]u8{ 0x00, 0x0E, 0x18, 0x7C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'f'
    [_]u8{ 0x00, 0x00, 0x00, 0x3E, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'g'
    [_]u8{ 0x00, 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'h'
    [_]u8{ 0x00, 0x18, 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'i'
    [_]u8{ 0x00, 0x06, 0x06, 0x00, 0x0E, 0x06, 0x06, 0x06, 0x06, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'j'
    [_]u8{ 0x00, 0x60, 0x60, 0x66, 0x6C, 0x78, 0x78, 0x6C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'k'
    [_]u8{ 0x00, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'l'
    [_]u8{ 0x00, 0x00, 0x00, 0x76, 0x7F, 0x6B, 0x6B, 0x6B, 0x6B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'm'
    [_]u8{ 0x00, 0x00, 0x00, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'n'
    [_]u8{ 0x00, 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'o'
    [_]u8{ 0x00, 0x00, 0x00, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'p'
    [_]u8{ 0x00, 0x00, 0x00, 0x3E, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x06, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'q'
    [_]u8{ 0x00, 0x00, 0x00, 0x7C, 0x66, 0x60, 0x60, 0x60, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'r'
    [_]u8{ 0x00, 0x00, 0x00, 0x3E, 0x60, 0x3C, 0x06, 0x46, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 's'
    [_]u8{ 0x00, 0x10, 0x18, 0x7E, 0x18, 0x18, 0x18, 0x18, 0x0E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 't'
    [_]u8{ 0x00, 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'u'
    [_]u8{ 0x00, 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'v'
    [_]u8{ 0x00, 0x00, 0x00, 0x63, 0x6B, 0x6B, 0x7F, 0x3E, 0x36, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'w'
    [_]u8{ 0x00, 0x00, 0x00, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'x'
    [_]u8{ 0x00, 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'y'
    [_]u8{ 0x00, 0x00, 0x00, 0x7E, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 'z'
    [_]u8{ 0x00, 0x0E, 0x18, 0x18, 0x70, 0x18, 0x18, 0x18, 0x0E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '{'
    [_]u8{ 0x00, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '|'
    [_]u8{ 0x00, 0x70, 0x18, 0x18, 0x0E, 0x18, 0x18, 0x18, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '}'
    [_]u8{ 0x00, 0x32, 0x4C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // '~'
};

const CYRILLIC_UPPER_GLYPHS = [32][16]u8{
    [_]u8{ 0x00, 0x00, 0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // А
    [_]u8{ 0x00, 0x00, 0x7E, 0x60, 0x60, 0x7C, 0x66, 0x66, 0x7C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Б
    [_]u8{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // В
    [_]u8{ 0x00, 0x00, 0x7E, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Г
    [_]u8{ 0x00, 0x00, 0x1C, 0x2C, 0x4C, 0x4C, 0x4C, 0x4C, 0x7F, 0x63, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Д
    [_]u8{ 0x00, 0x00, 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Е
    [_]u8{ 0x00, 0x00, 0x77, 0x55, 0x55, 0x3E, 0x55, 0x55, 0x77, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Ж
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // З
    [_]u8{ 0x00, 0x00, 0x66, 0x66, 0x6E, 0x7E, 0x76, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // И
    [_]u8{ 0x00, 0x3C, 0x66, 0x66, 0x6E, 0x7E, 0x76, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Й
    [_]u8{ 0x00, 0x00, 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // К
    [_]u8{ 0x00, 0x00, 0x1E, 0x36, 0x66, 0x66, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Л
    [_]u8{ 0x00, 0x00, 0x63, 0x77, 0x7F, 0x6B, 0x63, 0x63, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // М
    [_]u8{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Н
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // О
    [_]u8{ 0x00, 0x00, 0x7E, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // П
    [_]u8{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Р
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // С
    [_]u8{ 0x00, 0x00, 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Т
    [_]u8{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // У
    [_]u8{ 0x00, 0x00, 0x18, 0x3C, 0x5A, 0x5A, 0x3C, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Ф
    [_]u8{ 0x00, 0x00, 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Х
    [_]u8{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x66, 0x7E, 0x06, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Ц
    [_]u8{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x06, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Ч
    [_]u8{ 0x00, 0x00, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x7F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Ш
    [_]u8{ 0x00, 0x00, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x7F, 0x03, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Щ
    [_]u8{ 0x00, 0x00, 0x70, 0x30, 0x30, 0x3C, 0x36, 0x36, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Ъ
    [_]u8{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x76, 0x6E, 0x6E, 0x76, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Ы
    [_]u8{ 0x00, 0x00, 0x60, 0x60, 0x60, 0x7C, 0x66, 0x66, 0x7C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Ь
    [_]u8{ 0x00, 0x00, 0x3C, 0x66, 0x06, 0x1E, 0x06, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Э
    [_]u8{ 0x00, 0x00, 0x67, 0x69, 0x69, 0x79, 0x69, 0x69, 0x67, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Ю
    [_]u8{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x36, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Я
};

const CYRILLIC_LOWER_GLYPHS = [32][16]u8{
    [_]u8{ 0x00, 0x00, 0x00, 0x3C, 0x06, 0x3E, 0x66, 0x66, 0x3E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // а
    [_]u8{ 0x00, 0x38, 0x30, 0x30, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // б
    [_]u8{ 0x00, 0x00, 0x00, 0x7C, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // в
    [_]u8{ 0x00, 0x00, 0x00, 0x7E, 0x60, 0x60, 0x60, 0x60, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // г
    [_]u8{ 0x00, 0x00, 0x00, 0x1C, 0x2C, 0x4C, 0x4C, 0x7F, 0x63, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // д
    [_]u8{ 0x00, 0x00, 0x00, 0x3C, 0x66, 0x7E, 0x60, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // е
    [_]u8{ 0x00, 0x00, 0x00, 0x77, 0x55, 0x3E, 0x55, 0x55, 0x77, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ж
    [_]u8{ 0x00, 0x00, 0x00, 0x3C, 0x66, 0x0C, 0x06, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // з
    [_]u8{ 0x00, 0x00, 0x00, 0x66, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // и
    [_]u8{ 0x00, 0x3C, 0x00, 0x66, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // й
    [_]u8{ 0x00, 0x00, 0x00, 0x66, 0x6C, 0x78, 0x70, 0x6C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // к
    [_]u8{ 0x00, 0x00, 0x00, 0x1E, 0x36, 0x66, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // л
    [_]u8{ 0x00, 0x00, 0x00, 0x63, 0x77, 0x7F, 0x6B, 0x63, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // м
    [_]u8{ 0x00, 0x00, 0x00, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // н
    [_]u8{ 0x00, 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // о
    [_]u8{ 0x00, 0x00, 0x00, 0x7E, 0x66, 0x66, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // п
    [_]u8{ 0x00, 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // р
    [_]u8{ 0x00, 0x00, 0x00, 0x3C, 0x66, 0x60, 0x60, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // с
    [_]u8{ 0x00, 0x00, 0x00, 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // т
    [_]u8{ 0x00, 0x00, 0x00, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // у
    [_]u8{ 0x00, 0x00, 0x00, 0x18, 0x3C, 0x5A, 0x3C, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ф
    [_]u8{ 0x00, 0x00, 0x00, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // х
    [_]u8{ 0x00, 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x7E, 0x06, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ц
    [_]u8{ 0x00, 0x00, 0x00, 0x66, 0x66, 0x3E, 0x06, 0x06, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ч
    [_]u8{ 0x00, 0x00, 0x00, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x7F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ш
    [_]u8{ 0x00, 0x00, 0x00, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x7F, 0x03, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00 }, // щ
    [_]u8{ 0x00, 0x00, 0x00, 0x70, 0x30, 0x3C, 0x36, 0x36, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ъ
    [_]u8{ 0x00, 0x00, 0x00, 0x66, 0x66, 0x76, 0x6E, 0x6E, 0x76, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ы
    [_]u8{ 0x00, 0x00, 0x00, 0x60, 0x60, 0x7C, 0x66, 0x66, 0x7C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ь
    [_]u8{ 0x00, 0x00, 0x00, 0x3C, 0x66, 0x0E, 0x06, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // э
    [_]u8{ 0x00, 0x00, 0x00, 0x67, 0x69, 0x79, 0x69, 0x69, 0x67, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // ю
    [_]u8{ 0x00, 0x00, 0x00, 0x3E, 0x66, 0x3E, 0x36, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // я
};

pub fn getGlyph(codepoint: u32) [16]u8 {
    if (codepoint >= 0x20 and codepoint <= 0x7E) {
        return ASCII_GLYPHS[codepoint - 0x20];
    }
    if (codepoint >= 0x0410 and codepoint <= 0x042F) {
        return CYRILLIC_UPPER_GLYPHS[codepoint - 0x0410];
    }
    if (codepoint >= 0x0430 and codepoint <= 0x044F) {
        return CYRILLIC_LOWER_GLYPHS[codepoint - 0x0430];
    }
    if (codepoint == 0x0401) return GLYPH_YO_UPPER;
    if (codepoint == 0x0451) return GLYPH_YO_LOWER;
    if (codepoint == 0x00AB) return GLYPH_LEFT_GUILLEMET;
    if (codepoint == 0x00BB) return GLYPH_RIGHT_GUILLEMET;
    if (codepoint == 0x2014 or codepoint == 0x2013) return GLYPH_DASH;
    if (codepoint == 0x2026) return GLYPH_ELLIPSIS;
    return GLYPH_UNKNOWN;
}

// =============================================================================
// Color & Canvas Drawing Primitives
// =============================================================================

pub const Color = struct {
    pub const TRANSPARENT: u32 = 0x00000000;
    pub const WHITE: u32 = 0xFFFFFFFF;
    pub const BLACK: u32 = 0xFF000000;

    pub const DARK_BG: u32 = 0xFF100D0B;
    pub const DARK_BUBBLE: u32 = 0xFF1E232A;
    pub const DARK_BORDER: u32 = 0xFF2B333E;
    pub const DARK_TEXT: u32 = 0xFFF5F5F7;
    pub const DARK_TIME: u32 = 0xFF8A939D;
    pub const DARK_BAR: u32 = 0xFF4EA4F6;

    pub const ACCENTS = [_]u32{
        0xFF4EA4F6,
        0xFF28B9B5,
        0xFFA067E6,
        0xFFF07A3E,
        0xFFE56578,
        0xFF50BF62,
        0xFFE0B338,
    };

    pub fn getAccentForName(name: []const u8) u32 {
        var hash: u32 = 0;
        for (name) |b| {
            hash = (hash *% 33) +% b;
        }
        return ACCENTS[hash % ACCENTS.len];
    }
};

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    pixels: []u32,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Canvas {
        const pixels = try allocator.alloc(u32, width * height);
        @memset(pixels, 0);
        return Canvas{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.pixels);
    }

    pub fn clear(self: *Canvas, color: u32) void {
        @memset(self.pixels, color);
    }

    pub inline fn setPixel(self: *Canvas, x: usize, y: usize, color: u32) void {
        if (x < self.width and y < self.height) {
            self.pixels[y * self.width + x] = color;
        }
    }

    pub fn blendPixel(self: *Canvas, x: usize, y: usize, color: u32) void {
        if (x >= self.width or y >= self.height) return;
        const sa: u32 = (color >> 24) & 0xFF;
        if (sa == 0) return;
        if (sa == 255) {
            self.pixels[y * self.width + x] = color;
            return;
        }

        const dst = self.pixels[y * self.width + x];
        const da: u32 = (dst >> 24) & 0xFF;

        const sr: u32 = (color >> 16) & 0xFF;
        const sg: u32 = (color >> 8) & 0xFF;
        const sb: u32 = color & 0xFF;

        const dr: u32 = (dst >> 16) & 0xFF;
        const dg: u32 = (dst >> 8) & 0xFF;
        const db: u32 = dst & 0xFF;

        const inv_a = 255 - sa;
        const out_a = sa + ((da * inv_a) / 255);
        if (out_a == 0) return;

        const out_r = (sr * sa + dr * da * inv_a / 255) / out_a;
        const out_g = (sg * sa + dg * da * inv_a / 255) / out_a;
        const out_b = (sb * sa + db * da * inv_a / 255) / out_a;

        self.pixels[y * self.width + x] = (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
    }

    pub fn drawRect(self: *Canvas, x: usize, y: usize, w: usize, h: usize, color: u32) void {
        var cy = y;
        while (cy < y + h and cy < self.height) : (cy += 1) {
            var cx = x;
            while (cx < x + w and cx < self.width) : (cx += 1) {
                self.blendPixel(cx, cy, color);
            }
        }
    }

    pub fn drawRoundRect(
        self: *Canvas,
        x: usize,
        y: usize,
        w: usize,
        h: usize,
        radius: usize,
        fill_color: u32,
        border_color: u32,
        border_w: usize,
    ) void {
        const r_sq: i64 = @intCast(radius * radius);
        const inner_r: i64 = if (radius > border_w) @intCast(radius - border_w) else 0;
        const inner_r_sq = inner_r * inner_r;

        var py: usize = y;
        while (py < y + h and py < self.height) : (py += 1) {
            var px: usize = x;
            while (px < x + w and px < self.width) : (px += 1) {
                var is_corner = false;
                var corner_dist_sq: i64 = 0;

                const left = px < x + radius;
                const right = px >= x + w - radius;
                const top = py < y + radius;
                const bottom = py >= y + h - radius;

                if (left and top) {
                    const dx: i64 = @intCast(x + radius - 1 - px);
                    const dy: i64 = @intCast(y + radius - 1 - py);
                    corner_dist_sq = dx * dx + dy * dy;
                    is_corner = true;
                } else if (right and top) {
                    const dx: i64 = @intCast(px - (x + w - radius));
                    const dy: i64 = @intCast(y + radius - 1 - py);
                    corner_dist_sq = dx * dx + dy * dy;
                    is_corner = true;
                } else if (left and bottom) {
                    const dx: i64 = @intCast(x + radius - 1 - px);
                    const dy: i64 = @intCast(py - (y + h - radius));
                    corner_dist_sq = dx * dx + dy * dy;
                    is_corner = true;
                } else if (right and bottom) {
                    const dx: i64 = @intCast(px - (x + w - radius));
                    const dy: i64 = @intCast(py - (y + h - radius));
                    corner_dist_sq = dx * dx + dy * dy;
                    is_corner = true;
                }

                if (is_corner) {
                    if (corner_dist_sq > r_sq) {
                        continue;
                    }
                    if (border_w > 0 and corner_dist_sq >= inner_r_sq) {
                        self.blendPixel(px, py, border_color);
                    } else {
                        self.blendPixel(px, py, fill_color);
                    }
                } else {
                    const on_border = (border_w > 0) and
                        (px < x + border_w or px >= x + w - border_w or py < y + border_w or py >= y + h - border_w);
                    if (on_border) {
                        self.blendPixel(px, py, border_color);
                    } else {
                        self.blendPixel(px, py, fill_color);
                    }
                }
            }
        }
    }

    pub fn drawCircle(self: *Canvas, cx: isize, cy: isize, radius: usize, color: u32) void {
        const r_isize: isize = @intCast(radius);
        const r_sq: i64 = @intCast(radius * radius);

        var dy = -r_isize;
        while (dy <= r_isize) : (dy += 1) {
            const py = cy + dy;
            if (py < 0 or py >= @as(isize, @intCast(self.height))) continue;

            var dx = -r_isize;
            while (dx <= r_isize) : (dx += 1) {
                const px = cx + dx;
                if (px < 0 or px >= @as(isize, @intCast(self.width))) continue;

                if (dx * dx + dy * dy <= r_sq) {
                    self.blendPixel(@intCast(px), @intCast(py), color);
                }
            }
        }
    }

    pub fn drawGlyph(self: *Canvas, x: usize, y: usize, glyph: [16]u8, color: u32, scale: usize) void {
        var row: usize = 0;
        while (row < 16) : (row += 1) {
            const row_bits = glyph[row];
            var col: usize = 0;
            while (col < 8) : (col += 1) {
                if ((row_bits & (@as(u8, 0x80) >> @intCast(col))) != 0) {
                    if (scale == 1) {
                        self.blendPixel(x + col, y + row, color);
                    } else {
                        var sy: usize = 0;
                        while (sy < scale) : (sy += 1) {
                            var sx: usize = 0;
                            while (sx < scale) : (sx += 1) {
                                self.blendPixel(x + col * scale + sx, y + row * scale + sy, color);
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn drawText(self: *Canvas, x: usize, y: usize, utf8_text: []const u8, color: u32, scale: usize) usize {
        var cur_x = x;
        var i: usize = 0;
        while (i < utf8_text.len) {
            const b0 = utf8_text[i];
            var cp: u32 = 0;
            var seq_len: usize = 1;

            if (b0 < 0x80) {
                cp = b0;
                seq_len = 1;
            } else if ((b0 & 0xE0) == 0xC0 and i + 1 < utf8_text.len) {
                cp = (@as(u32, b0 & 0x1F) << 6) | (utf8_text[i + 1] & 0x3F);
                seq_len = 2;
            } else if ((b0 & 0xF0) == 0xE0 and i + 2 < utf8_text.len) {
                cp = (@as(u32, b0 & 0x0F) << 12) | (@as(u32, utf8_text[i + 1] & 0x3F) << 6) | (utf8_text[i + 2] & 0x3F);
                seq_len = 3;
            } else if ((b0 & 0xF8) == 0xF0 and i + 3 < utf8_text.len) {
                cp = (@as(u32, b0 & 0x07) << 18) | (@as(u32, utf8_text[i + 1] & 0x3F) << 12) | (@as(u32, utf8_text[i + 2] & 0x3F) << 6) | (utf8_text[i + 3] & 0x3F);
                seq_len = 4;
            } else {
                cp = b0;
                seq_len = 1;
            }
            i += seq_len;

            const glyph = getGlyph(cp);
            self.drawGlyph(cur_x, y, glyph, color, scale);
            cur_x += GLYPH_WIDTH * scale;
        }
        return cur_x - x;
    }
};

// =============================================================================
// Standalone Pure Zig PNG Encoder
// =============================================================================

fn adler32(data: []const u8) u32 {
    const MOD_ADLER: u32 = 65521;
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % MOD_ADLER;
        b = (b + a) % MOD_ADLER;
    }
    return (b << 16) | a;
}

fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc ^= byte;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc >>= 1;
            }
        }
    }
    return ~crc;
}

pub fn encodePng(allocator: std.mem.Allocator, width: u32, height: u32, pixels: []const u32) ![]u8 {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);

    const stride: usize = 1 + w * 4;
    const raw_len = h * stride;
    const raw_data = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw_data);

    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row_start = y * stride;
        raw_data[row_start] = 0; // Filter byte: None (0)

        var x: usize = 0;
        while (x < w) : (x += 1) {
            const pixel = pixels[y * w + x];
            const a: u8 = @intCast((pixel >> 24) & 0xFF);
            const r: u8 = @intCast((pixel >> 16) & 0xFF);
            const g: u8 = @intCast((pixel >> 8) & 0xFF);
            const b: u8 = @intCast(pixel & 0xFF);

            const px_offset = row_start + 1 + x * 4;
            raw_data[px_offset + 0] = r;
            raw_data[px_offset + 1] = g;
            raw_data[px_offset + 2] = b;
            raw_data[px_offset + 3] = a;
        }
    }

    const max_block_size: usize = 65535;
    const num_blocks = (raw_len + max_block_size - 1) / max_block_size;
    const zlib_max_size = 2 + num_blocks * 5 + raw_len + 4;
    const zlib_data = try allocator.alloc(u8, zlib_max_size);
    defer allocator.free(zlib_data);

    zlib_data[0] = 0x78;
    zlib_data[1] = 0x01;
    var out_pos: usize = 2;
    var in_pos: usize = 0;

    var b_idx: usize = 0;
    while (b_idx < num_blocks) : (b_idx += 1) {
        const is_last = (b_idx == num_blocks - 1);
        const block_len = @min(raw_len - in_pos, max_block_size);

        zlib_data[out_pos] = if (is_last) 1 else 0;
        out_pos += 1;

        const len_u16: u16 = @intCast(block_len);
        const nlen_u16 = ~len_u16;

        zlib_data[out_pos + 0] = @intCast(len_u16 & 0xFF);
        zlib_data[out_pos + 1] = @intCast((len_u16 >> 8) & 0xFF);
        zlib_data[out_pos + 2] = @intCast(nlen_u16 & 0xFF);
        zlib_data[out_pos + 3] = @intCast((nlen_u16 >> 8) & 0xFF);
        out_pos += 4;

        @memcpy(zlib_data[out_pos .. out_pos + block_len], raw_data[in_pos .. in_pos + block_len]);
        out_pos += block_len;
        in_pos += block_len;
    }

    const adler = adler32(raw_data);
    zlib_data[out_pos + 0] = @intCast((adler >> 24) & 0xFF);
    zlib_data[out_pos + 1] = @intCast((adler >> 16) & 0xFF);
    zlib_data[out_pos + 2] = @intCast((adler >> 8) & 0xFF);
    zlib_data[out_pos + 3] = @intCast(adler & 0xFF);
    out_pos += 4;

    const idat_chunk_size = 12 + out_pos;
    const total_png_size = 8 + 25 + idat_chunk_size + 12;
    const png_file = try allocator.alloc(u8, total_png_size);

    @memcpy(png_file[0..8], "\x89PNG\r\n\x1a\n");

    var p: usize = 8;
    std.mem.writeInt(u32, png_file[p .. p + 4][0..4], 13, .big);
    p += 4;
    @memcpy(png_file[p .. p + 4], "IHDR");
    p += 4;
    const ihdr_start = p;
    std.mem.writeInt(u32, png_file[p .. p + 4][0..4], width, .big);
    p += 4;
    std.mem.writeInt(u32, png_file[p .. p + 4][0..4], height, .big);
    p += 4;
    png_file[p] = 8;
    p += 1;
    png_file[p] = 6;
    p += 1;
    png_file[p] = 0;
    p += 1;
    png_file[p] = 0;
    p += 1;
    png_file[p] = 0;
    p += 1;
    const ihdr_crc = crc32(png_file[ihdr_start - 4 .. p]);
    std.mem.writeInt(u32, png_file[p .. p + 4][0..4], ihdr_crc, .big);
    p += 4;

    std.mem.writeInt(u32, png_file[p .. p + 4][0..4], @intCast(out_pos), .big);
    p += 4;
    @memcpy(png_file[p .. p + 4], "IDAT");
    p += 4;
    const idat_start = p;
    @memcpy(png_file[p .. p + out_pos], zlib_data[0..out_pos]);
    p += out_pos;
    const idat_crc = crc32(png_file[idat_start - 4 .. p]);
    std.mem.writeInt(u32, png_file[p .. p + 4][0..4], idat_crc, .big);
    p += 4;

    std.mem.writeInt(u32, png_file[p .. p + 4][0..4], 0, .big);
    p += 4;
    @memcpy(png_file[p .. p + 4], "IEND");
    p += 4;
    const iend_crc = crc32(png_file[p - 4 .. p]);
    std.mem.writeInt(u32, png_file[p .. p + 4][0..4], iend_crc, .big);
    p += 4;

    return png_file;
}

// =============================================================================
// Quote Card Layout & Renderer (with balanced top/bottom padding)
// =============================================================================

pub fn renderQuoteCard(
    allocator: std.mem.Allocator,
    sender_name: []const u8,
    text: []const u8,
    time: []const u8,
    initials: []const u8,
    is_outgoing: bool,
) ![]u8 {
    _ = is_outgoing;
    const card_width: usize = 560;

    const max_line_chars = 46;
    var lines_buf: [16][128]u8 = undefined;
    var lines_len: [16]usize = undefined;
    var line_count: usize = 0;

    var text_idx: usize = 0;
    while (text_idx < text.len and line_count < 12) {
        while (text_idx < text.len and (text[text_idx] == ' ' or text[text_idx] == '\n' or text[text_idx] == '\r')) {
            text_idx += 1;
        }
        if (text_idx >= text.len) break;

        var end = @min(text.len, text_idx + max_line_chars);
        var has_nl = false;
        var nl_pos = text_idx;
        while (nl_pos < end) : (nl_pos += 1) {
            if (text[nl_pos] == '\n') {
                end = nl_pos;
                has_nl = true;
                break;
            }
        }

        if (!has_nl and end < text.len) {
            var space_pos = end;
            while (space_pos > text_idx) : (space_pos -= 1) {
                if (text[space_pos] == ' ') {
                    end = space_pos;
                    break;
                }
            }
        }

        const slice = text[text_idx..end];
        const copy_len = @min(slice.len, lines_buf[line_count].len);
        @memcpy(lines_buf[line_count][0..copy_len], slice[0..copy_len]);
        lines_len[line_count] = copy_len;
        line_count += 1;
        text_idx = if (has_nl) end + 1 else end;
    }

    if (line_count == 0) {
        const def_msg = "💬 [Вложение]";
        @memcpy(lines_buf[0][0..def_msg.len], def_msg);
        lines_len[0] = def_msg.len;
        line_count = 1;
    }

    // Сбалансированные отступы: верхний отступ увеличен для симметрии
    const header_height: usize = 50;
    const line_spacing: usize = 20;
    const text_block_height = line_count * line_spacing;
    const footer_height: usize = 24;
    const card_padding: usize = 16;
    const card_height = header_height + text_block_height + footer_height;

    const canvas_w = card_width;
    const canvas_h = card_height + card_padding * 2;

    var canvas = try Canvas.init(allocator, canvas_w, canvas_h);
    defer canvas.deinit();

    canvas.clear(Color.DARK_BG);

    const card_x = 12;
    const card_y = card_padding;
    const card_w = card_width - 24;
    const card_h = card_height;
    canvas.drawRoundRect(card_x, card_y, card_w, card_h, 14, Color.DARK_BUBBLE, Color.DARK_BORDER, 1);

    const accent_color = Color.getAccentForName(sender_name);

    // Аватар: радиус 17, верхний отступ ~15px от границы пузыря
    const avatar_cx: isize = @intCast(card_x + 30);
    const avatar_cy: isize = @intCast(card_y + 32);
    canvas.drawCircle(avatar_cx, avatar_cy, 17, accent_color);

    // Инициалы автора внутри аватара
    const init_text = if (initials.len > 0) initials else "?";
    const init_x: usize = @intCast(avatar_cx - @as(isize, @intCast(init_text.len * 4)));
    const init_y: usize = @intCast(avatar_cy - 8);
    _ = canvas.drawText(init_x, init_y, init_text, Color.WHITE, 1);

    // Имя автора: комфортный отступ 20px сверху
    const name_str = if (sender_name.len > 0) sender_name else "Пользователь";
    _ = canvas.drawText(card_x + 58, card_y + 20, name_str, accent_color, 1);

    // Вертикальная полоса цитаты
    const stripe_x = card_x + 58;
    const stripe_y = card_y + 46;
    const stripe_h = text_block_height + 4;
    canvas.drawRoundRect(stripe_x, stripe_y, 3, stripe_h, 1, accent_color, 0, 0);

    // Текст сообщения
    var line_y = stripe_y;
    var l: usize = 0;
    while (l < line_count) : (l += 1) {
        const l_slice = lines_buf[l][0..lines_len[l]];
        _ = canvas.drawText(stripe_x + 10, line_y, l_slice, Color.DARK_TEXT, 1);
        line_y += line_spacing;
    }

    // Время отправки в правом нижнем углу
    const time_str = if (time.len > 0) time else "12:00";
    const time_w = time_str.len * GLYPH_WIDTH;
    const time_x = card_x + card_w - time_w - 18;
    const time_y = card_y + card_height - 20;
    _ = canvas.drawText(time_x, time_y, time_str, Color.DARK_TIME, 1);

    return encodePng(allocator, @intCast(canvas.width), @intCast(canvas.height), canvas.pixels);
}

pub fn saveQuoteCardToFile(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    sender_name: []const u8,
    text: []const u8,
    time: []const u8,
    initials: []const u8,
    is_outgoing: bool,
    out_path_buf: []u8,
) ?[:0]const u8 {
    const png_bytes = renderQuoteCard(allocator, sender_name, text, time, initials, is_outgoing) catch return null;
    defer allocator.free(png_bytes);

    const ts = std.time.milliTimestamp();
    const full_path = std.fmt.bufPrint(
        out_path_buf,
        "{s}/quote_reply_{d}.png",
        .{ cache_dir, ts },
    ) catch return null;

    const file = std.fs.createFileAbsolute(full_path, .{}) catch return null;
    defer file.close();

    file.writeAll(png_bytes) catch return null;

    if (full_path.len < out_path_buf.len) {
        out_path_buf[full_path.len] = 0;
        return out_path_buf[0..full_path.len :0];
    }
    return null;
}

// =============================================================================
// Plugin Global State & Infrastructure
// =============================================================================

var global_api: ?*const PluginApi = null;
var is_active = std.atomic.Value(bool).init(true);
var disable_in_discussions: bool = false;

pub const METADATA = PluginMetadata{
    .name = "KvoteReply",
    .version = "2.0.0",
    .author = "OwnerTS",
    .description = "Pixel-perfect authentic message bubble photo quote replies for MandaGram (Pure FFI, Pure Zig).",
};

pub export fn mandagram_plugin_metadata() callconv(.c) ?*const PluginMetadata {
    return &METADATA;
}

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

var quote_mutex = std.Thread.Mutex{};
var pending_quote = PendingQuoteState{};
var outgoing_json_buf: [16384]u8 = undefined;

pub fn logFmt(comptime fmt: []const u8, args: anytype) void {
    const api = global_api orelse return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    if (api.log_info) |log_fn| {
        log_fn("KvoteReply", msg);
    }
}

pub fn logErrFmt(comptime fmt: []const u8, args: anytype) void {
    const api = global_api orelse return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    if (api.log_error) |log_fn| {
        log_fn("KvoteReply", msg);
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

fn preRenderQuote(api: *const PluginApi, state: *PendingQuoteState) ?[:0]const u8 {
    var dir_buf: [512]u8 = undefined;
    const cache_dir = getQuotesCacheDir(api, &dir_buf) orelse return null;
    cleanupCacheDir(cache_dir, 8);

    const name_slice = state.sender_name[0..state.sender_name_len];
    const text_slice = state.text[0..state.text_len];
    const time_slice = state.time[0..state.time_len];
    const init_slice = state.initials[0..state.initials_len];

    var path_buf: [512]u8 = undefined;
    if (saveQuoteCardToFile(
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

// =============================================================================
// Hooks Implementation
// =============================================================================

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

    const topic_obj = get_obj(msg_item, "forumTopicId");
    pending_quote.is_discussion = (topic_obj != null);

    if (get_obj(msg_item, "senderName")) |jname| {
        const len = get_str(jname, &pending_quote.sender_name, pending_quote.sender_name.len);
        pending_quote.sender_name_len = if (len > 0) @intCast(len) else 0;
    } else {
        pending_quote.sender_name_len = 0;
    }

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

    if (get_obj(msg_item, "formattedTime")) |jtime| {
        const len = get_str(jtime, &pending_quote.time, pending_quote.time.len);
        pending_quote.time_len = if (len > 0) @intCast(len) else 0;
    } else {
        pending_quote.time_len = 0;
    }

    if (get_obj(msg_item, "senderInitials")) |jinit| {
        const len = get_str(jinit, &pending_quote.initials, pending_quote.initials.len);
        pending_quote.initials_len = if (len > 0) @intCast(len) else 0;
    } else {
        pending_quote.initials_len = 0;
    }

    pending_quote.captured_path_len = 0;

    if (preRenderQuote(api, &pending_quote)) |rendered_path| {
        logFmt("[beginReply] Pre-rendered quote card ready: {s}", .{rendered_path});
    }
    quote_mutex.unlock();
}

fn on_before_send_draft(param: *HookParam) callconv(.c) void {
    if (!is_active.load(.seq_cst)) return;
    const api = global_api orelse return;

    const this_obj = param.this_ptr orelse return;
    const get_obj = api.get_object_field orelse return;
    const get_long = api.get_long_field orelse return;

    const entry_obj = get_obj(this_obj, "entry") orelse return;
    const reply_item = get_obj(entry_obj, "reply") orelse return;
    const reply_id = get_long(reply_item, "id");
    if (reply_id == 0) return;

    quote_mutex.lock();
    const need_render = (pending_quote.msg_id != reply_id or pending_quote.captured_path_len == 0);
    if (need_render) {
        pending_quote.msg_id = reply_id;
        _ = preRenderQuote(api, &pending_quote);
    }
    quote_mutex.unlock();
}

fn on_before_send_message(
    chat_id: i64,
    text_ptr: [*:0]const u8,
    user_data: usize,
) callconv(.c) ?[*:0]const u8 {
    _ = user_data;
    if (!is_active.load(.seq_cst)) return text_ptr;

    quote_mutex.lock();
    defer quote_mutex.unlock();

    if (pending_quote.msg_id == 0) return text_ptr;
    if (pending_quote.chat_id != 0 and pending_quote.chat_id != chat_id) return text_ptr;
    if (disable_in_discussions and pending_quote.is_discussion) return text_ptr;

    if (pending_quote.captured_path_len == 0) {
        if (global_api) |api| {
            if (preRenderQuote(api, &pending_quote)) |p| {
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
        \\{{"@type":"inputMessagePhoto","photo":{{"@type":"inputFileLocal","path":"{s}"}},"caption":{{"@type":"formattedText","text":"{s}","entities":[]}}}}
    ,
        .{
            escaped_path,
            escaped_caption,
        },
    ) catch return text_ptr;

    logFmt("[send] Transformed outgoing reply into authentic photo quote card!", .{});

    pending_quote = .{};

    return json.ptr;
}

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

// =============================================================================
// Lifecycle Exports
// =============================================================================

pub export fn mandagram_plugin_init(api: *const PluginApi) callconv(.c) bool {
    global_api = api;
    is_active.store(true, .seq_cst);
    if (api.log_info) |log_fn| {
        log_fn("KvoteReply", "Initializing KvoteReply plugin v2.0.0 (Pure FFI, Pure Zig)");
    }

    loadSettings(api);

    if (api.register_hook) |reg_hook| {
        _ = reg_hook(
            "com/mandagram/ui/chat/ChatComposerActions",
            "beginReply",
            "(Lcom/mandagram/models/MessageItem;)V",
            on_before_begin_reply,
            null,
        );

        _ = reg_hook(
            "com/mandagram/ui/chat/ChatComposerActions",
            "sendDraft",
            "()V",
            on_before_send_draft,
            null,
        );
    }

    if (api.register_message_send_hook) |reg_send| {
        _ = reg_send(on_before_send_message, null, 0);
    }

    if (api.register_chat_action) |reg_action| {
        _ = reg_action("toggle_discussions", "KvoteReply: Toggle Discussion Quotes", on_toggle_setting_click, 0);
    }

    return true;
}

pub export fn mandagram_plugin_unload() callconv(.c) void {
    is_active.store(false, .seq_cst);
    if (global_api) |api| {
        if (api.log_info) |log_fn| {
            log_fn("KvoteReply", "Unloading KvoteReply plugin v2.0.0");
        }
    }

    quote_mutex.lock();
    pending_quote = .{};
    quote_mutex.unlock();
}

// =============================================================================
// Unit Tests
// =============================================================================

const testing = std.testing;

test "utf8Truncate ascii" {
    const text = "Hello world!";
    const res = utf8Truncate(text, 5);
    try testing.expectEqualStrings("Hello", res);
}

test "utf8Truncate cyrillic exact boundary" {
    const text = "Привет";
    try testing.expectEqual(@as(usize, 12), text.len);

    const res4 = utf8Truncate(text, 4);
    try testing.expectEqualStrings("Пр", res4);

    const res5 = utf8Truncate(text, 5);
    try testing.expectEqualStrings("Пр", res5);

    const res6 = utf8Truncate(text, 6);
    try testing.expectEqualStrings("При", res6);
}

test "utf8Truncate 4-byte emoji boundary" {
    const text = "A🔥B";
    const res3 = utf8Truncate(text, 3);
    try testing.expectEqualStrings("A", res3);

    const res5 = utf8Truncate(text, 5);
    try testing.expectEqualStrings("A🔥", res5);
}

test "escapeJson handles quotes, slashes, and control characters" {
    const input = "Hello \"World\"\nLine 2\\Path\tTab";
    var out_buf: [256]u8 = undefined;
    const escaped = escapeJson(input, &out_buf);
    try testing.expectEqualStrings("Hello \\\"World\\\"\\nLine 2\\\\Path\\tTab", escaped);
}

test "plugin metadata" {
    const meta = mandagram_plugin_metadata();
    try testing.expect(meta != null);
    try testing.expectEqualStrings("KvoteReply", std.mem.span(meta.?.name));
    try testing.expectEqualStrings("2.0.0", std.mem.span(meta.?.version));
    try testing.expectEqualStrings("OwnerTS", std.mem.span(meta.?.author));
}

test "cleanupCacheDir rotates old quote files" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &tmp_path_buf);

    const names = [_][]const u8{
        "quote_reply_1.png",
        "quote_reply_2.png",
        "quote_reply_3.png",
        "quote_reply_4.png",
        "quote_reply_5.png",
    };
    for (names) |name| {
        const f = try tmp.dir.createFile(name, .{});
        f.close();
    }

    cleanupCacheDir(tmp_path, 3);

    var count: usize = 0;
    var iter = tmp.dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "quote_reply_")) {
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "renderQuoteCard generates valid PNG" {
    const png_data = try renderQuoteCard(
        testing.allocator,
        "kote :3",
        "Привет, мир! Это тестовая цитата.",
        "12:34",
        "K:",
        false,
    );
    defer testing.allocator.free(png_data);

    try testing.expect(png_data.len > 8);
    try testing.expectEqualStrings("\x89PNG\r\n\x1a\n", png_data[0..8]);
}

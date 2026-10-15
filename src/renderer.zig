//! ============================================================================
//! High-Performance Pure Native Quote Card Renderer & PNG Encoder
//! ============================================================================

const std = @import("std");
const font = @import("font.zig");

pub const Color = struct {
    pub const TRANSPARENT: u32 = 0x00000000;
    pub const WHITE: u32 = 0xFFFFFFFF;
    pub const BLACK: u32 = 0xFF000000;

    // Dark theme Telegram message colors
    pub const DARK_BG: u32 = 0xFF100D0B; // Chat background
    pub const DARK_BUBBLE: u32 = 0xFF1E232A; // Bubble card background
    pub const DARK_BORDER: u32 = 0xFF2B333E; // Card border
    pub const DARK_TEXT: u32 = 0xFFF5F5F7; // Primary text
    pub const DARK_TIME: u32 = 0xFF8A939D; // Secondary time text
    pub const DARK_BAR: u32 = 0xFF4EA4F6; // Accent quote stripe

    // Accent colors for author avatar/name
    pub const ACCENTS = [_]u32{
        0xFF4EA4F6, // Blue
        0xFF28B9B5, // Cyan
        0xFFA067E6, // Purple
        0xFFF07A3E, // Orange
        0xFFE56578, // Pink
        0xFF50BF62, // Green
        0xFFE0B338, // Amber
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

    pub fn drawRect(self: *Canvas, rx: usize, ry: usize, rw: usize, rh: usize, color: u32) void {
        var y = ry;
        const max_y = @min(self.height, ry + rh);
        const max_x = @min(self.width, rx + rw);
        while (y < max_y) : (y += 1) {
            var x = rx;
            while (x < max_x) : (x += 1) {
                self.blendPixel(x, y, color);
            }
        }
    }

    pub fn drawCircle(self: *Canvas, cx: isize, cy: isize, radius: isize, color: u32) void {
        const r2 = radius * radius;
        var dy = -radius;
        while (dy <= radius) : (dy += 1) {
            const y = cy + dy;
            if (y < 0 or y >= @as(isize, @intCast(self.height))) continue;
            var dx = -radius;
            while (dx <= radius) : (dx += 1) {
                const x = cx + dx;
                if (x < 0 or x >= @as(isize, @intCast(self.width))) continue;
                if (dx * dx + dy * dy <= r2) {
                    self.blendPixel(@intCast(x), @intCast(y), color);
                }
            }
        }
    }

    pub fn drawRoundRect(
        self: *Canvas,
        rx: usize,
        ry: usize,
        rw: usize,
        rh: usize,
        radius: usize,
        fill_color: u32,
        border_color: u32,
        border_width: usize,
    ) void {
        const r_int: isize = @intCast(radius);
        const max_y = @min(self.height, ry + rh);
        const max_x = @min(self.width, rx + rw);

        var y: usize = ry;
        while (y < max_y) : (y += 1) {
            const iy: isize = @intCast(y);
            const cy: isize = @intCast(ry);
            const ch: isize = @intCast(rh);

            var x: usize = rx;
            while (x < max_x) : (x += 1) {
                const ix: isize = @intCast(x);
                const cx: isize = @intCast(rx);
                const cw: isize = @intCast(rw);

                // Determine distance to corners
                var inside = true;
                var on_border = false;

                const in_left_corner = (ix < cx + r_int);
                const in_right_corner = (ix >= cx + cw - r_int);
                const in_top_corner = (iy < cy + r_int);
                const in_bottom_corner = (iy >= cy + ch - r_int);

                if (in_left_corner and in_top_corner) {
                    const dx = cx + r_int - ix;
                    const dy = cy + r_int - iy;
                    const dist2 = dx * dx + dy * dy;
                    if (dist2 > r_int * r_int) inside = false;
                    if (border_width > 0 and dist2 > (r_int - @as(isize, @intCast(border_width))) * (r_int - @as(isize, @intCast(border_width)))) on_border = true;
                } else if (in_right_corner and in_top_corner) {
                    const dx = ix - (cx + cw - r_int);
                    const dy = cy + r_int - iy;
                    const dist2 = dx * dx + dy * dy;
                    if (dist2 > r_int * r_int) inside = false;
                    if (border_width > 0 and dist2 > (r_int - @as(isize, @intCast(border_width))) * (r_int - @as(isize, @intCast(border_width)))) on_border = true;
                } else if (in_left_corner and in_bottom_corner) {
                    const dx = cx + r_int - ix;
                    const dy = iy - (cy + ch - r_int);
                    const dist2 = dx * dx + dy * dy;
                    if (dist2 > r_int * r_int) inside = false;
                    if (border_width > 0 and dist2 > (r_int - @as(isize, @intCast(border_width))) * (r_int - @as(isize, @intCast(border_width)))) on_border = true;
                } else if (in_right_corner and in_bottom_corner) {
                    const dx = ix - (cx + cw - r_int);
                    const dy = iy - (cy + ch - r_int);
                    const dist2 = dx * dx + dy * dy;
                    if (dist2 > r_int * r_int) inside = false;
                    if (border_width > 0 and dist2 > (r_int - @as(isize, @intCast(border_width))) * (r_int - @as(isize, @intCast(border_width)))) on_border = true;
                } else if (border_width > 0) {
                    if (ix < cx + @as(isize, @intCast(border_width)) or
                        ix >= cx + cw - @as(isize, @intCast(border_width)) or
                        iy < cy + @as(isize, @intCast(border_width)) or
                        iy >= cy + ch - @as(isize, @intCast(border_width)))
                    {
                        on_border = true;
                    }
                }

                if (inside) {
                    if (on_border and border_color != 0) {
                        self.blendPixel(x, y, border_color);
                    } else {
                        self.blendPixel(x, y, fill_color);
                    }
                }
            }
        }
    }

    pub fn drawGlyph(self: *Canvas, gx: usize, gy: usize, codepoint: u32, color: u32, scale: usize) void {
        const rows = font.getGlyph(codepoint);
        var r: usize = 0;
        while (r < font.GLYPH_HEIGHT) : (r += 1) {
            const byte = rows[r];
            var c: usize = 0;
            while (c < font.GLYPH_WIDTH) : (c += 1) {
                const bit = (byte >> @intCast(7 - c)) & 1;
                if (bit != 0) {
                    var sy: usize = 0;
                    while (sy < scale) : (sy += 1) {
                        var sx: usize = 0;
                        while (sx < scale) : (sx += 1) {
                            self.blendPixel(gx + c * scale + sx, gy + r * scale + sy, color);
                        }
                    }
                }
            }
        }
    }

    pub fn drawText(self: *Canvas, start_x: usize, start_y: usize, text: []const u8, color: u32, scale: usize) usize {
        var cur_x = start_x;
        var i: usize = 0;
        while (i < text.len) {
            const b = text[i];
            var codepoint: u32 = b;
            var len: usize = 1;

            if ((b & 0x80) == 0) {
                codepoint = b;
                len = 1;
            } else if ((b & 0xE0) == 0xC0 and i + 1 < text.len) {
                codepoint = (@as(u32, b & 0x1F) << 6) | @as(u32, text[i + 1] & 0x3F);
                len = 2;
            } else if ((b & 0xF0) == 0xE0 and i + 2 < text.len) {
                codepoint = (@as(u32, b & 0x0F) << 12) |
                    (@as(u32, text[i + 1] & 0x3F) << 6) |
                    @as(u32, text[i + 2] & 0x3F);
                len = 3;
            } else if ((b & 0xF8) == 0xF0 and i + 3 < text.len) {
                codepoint = (@as(u32, b & 0x07) << 18) |
                    (@as(u32, text[i + 1] & 0x3F) << 12) |
                    (@as(u32, text[i + 2] & 0x3F) << 6) |
                    @as(u32, text[i + 3] & 0x3F);
                len = 4;
            }

            self.drawGlyph(cur_x, start_y, codepoint, color, scale);
            cur_x += font.GLYPH_WIDTH * scale;
            i += len;
        }
        return cur_x - start_x;
    }
};

// =============================================================================
// PNG Encoder Implementation
// =============================================================================

fn crc32(data: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (data) |b| {
        c ^= b;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            c = (c >> 1) ^ (0xEDB88320 & (~(c & 1) +% 1));
        }
    }
    return ~c;
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    const MOD_ADLER: u32 = 65521;
    for (data) |byte| {
        a = (a + byte) % MOD_ADLER;
        b = (b + a) % MOD_ADLER;
    }
    return (b << 16) | a;
}

pub fn encodePng(allocator: std.mem.Allocator, width: u32, height: u32, rgba_pixels: []const u32) ![]u8 {
    // 1. Prepare raw scanlines with 0x00 filter byte per line
    const row_size: usize = 1 + width * 4;
    const raw_data_size = height * row_size;
    const raw_data = try allocator.alloc(u8, raw_data_size);
    defer allocator.free(raw_data);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row_offset = y * row_size;
        raw_data[row_offset] = 0; // Filter: None
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const pixel = rgba_pixels[y * width + x];
            const a: u8 = @intCast((pixel >> 24) & 0xFF);
            const r: u8 = @intCast((pixel >> 16) & 0xFF);
            const g: u8 = @intCast((pixel >> 8) & 0xFF);
            const b: u8 = @intCast(pixel & 0xFF);

            const px_offset = row_offset + 1 + x * 4;
            raw_data[px_offset + 0] = r;
            raw_data[px_offset + 1] = g;
            raw_data[px_offset + 2] = b;
            raw_data[px_offset + 3] = a;
        }
    }

    // 2. Wrap raw scanlines into zlib uncompressed stream
    const num_blocks = (raw_data_size + 65534) / 65535;
    const zlib_data_size = 2 + (num_blocks * 5) + raw_data_size + 4;
    const zlib_data = try allocator.alloc(u8, zlib_data_size);
    defer allocator.free(zlib_data);

    zlib_data[0] = 0x78; // CMF (Deflate, 32K window)
    zlib_data[1] = 0x01; // FLG

    var in_pos: usize = 0;
    var out_pos: usize = 2;

    while (in_pos < raw_data_size) {
        const block_len = @min(65535, raw_data_size - in_pos);
        const is_last = (in_pos + block_len >= raw_data_size);

        zlib_data[out_pos] = if (is_last) 1 else 0;
        out_pos += 1;

        const len_u16: u16 = @intCast(block_len);
        const nlen_u16: u16 = ~len_u16;

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

    // 3. Assemble full PNG file
    // Signature (8) + IHDR (25) + IDAT (12 + zlib) + IEND (12)
    const idat_chunk_size = 12 + out_pos;
    const total_png_size = 8 + 25 + idat_chunk_size + 12;
    const png_file = try allocator.alloc(u8, total_png_size);

    // PNG signature
    @memcpy(png_file[0..8], "\x89PNG\r\n\x1a\n");

    // IHDR chunk
    var p: usize = 8;
    std.mem.writeInt(u32, png_file[p .. p + 4][0..4], 13, .big); // Length
    p += 4;
    @memcpy(png_file[p .. p + 4], "IHDR"); // Type
    p += 4;
    const ihdr_start = p;
    std.mem.writeInt(u32, png_file[p .. p + 4][0..4], width, .big);
    p += 4;
    std.mem.writeInt(u32, png_file[p .. p + 4][0..4], height, .big);
    p += 4;
    png_file[p] = 8; // Bit depth: 8
    p += 1;
    png_file[p] = 6; // Color type: RGBA (6)
    p += 1;
    png_file[p] = 0; // Compression: Deflate
    p += 1;
    png_file[p] = 0; // Filter: None
    p += 1;
    png_file[p] = 0; // Interlace: None
    p += 1;
    const ihdr_crc = crc32(png_file[ihdr_start - 4 .. p]);
    std.mem.writeInt(u32, png_file[p .. p + 4][0..4], ihdr_crc, .big);
    p += 4;

    // IDAT chunk
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

    // IEND chunk
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
// Quote Card Layout & Renderer
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

    // Calculate lines by word-wrapping text
    const max_line_chars = 46;
    var lines_buf: [16][128]u8 = undefined;
    var lines_len: [16]usize = undefined;
    var line_count: usize = 0;

    var text_idx: usize = 0;
    while (text_idx < text.len and line_count < 12) {
        // Skip leading whitespace on line
        while (text_idx < text.len and (text[text_idx] == ' ' or text[text_idx] == '\n' or text[text_idx] == '\r')) {
            text_idx += 1;
        }
        if (text_idx >= text.len) break;

        var end = @min(text.len, text_idx + max_line_chars);
        // Find natural newline or space
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
            // Find last space before limit
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

    // Dynamic height calculation
    const header_height: usize = 42;
    const line_spacing: usize = 20;
    const text_block_height = line_count * line_spacing;
    const footer_height: usize = 24;
    const card_padding: usize = 16;
    const card_height = header_height + text_block_height + footer_height;

    // Total canvas size
    const canvas_w = card_width;
    const canvas_h = card_height + card_padding * 2;

    var canvas = try Canvas.init(allocator, canvas_w, canvas_h);
    defer canvas.deinit();

    // Fill backdrop with dark chat background
    canvas.clear(Color.DARK_BG);

    // Draw main bubble card (rounded rectangle with subtle border)
    const card_x = 12;
    const card_y = card_padding;
    const card_w = card_width - 24;
    const card_h = card_height;
    canvas.drawRoundRect(card_x, card_y, card_w, card_h, 14, Color.DARK_BUBBLE, Color.DARK_BORDER, 1);

    const accent_color = Color.getAccentForName(sender_name);

    // Draw Avatar Initials Circle (Diameter: 34 px)
    const avatar_cx: isize = @intCast(card_x + 28);
    const avatar_cy: isize = @intCast(card_y + 26);
    canvas.drawCircle(avatar_cx, avatar_cy, 17, accent_color);

    // Draw Initials inside Avatar (white, 1x)
    const init_text = if (initials.len > 0) initials else "?";
    const init_x: usize = @intCast(avatar_cx - @as(isize, @intCast(init_text.len * 4)));
    const init_y: usize = @intCast(avatar_cy - 8);
    _ = canvas.drawText(init_x, init_y, init_text, Color.WHITE, 1);

    // Draw Author Name (bold accent color, 1x)
    const name_str = if (sender_name.len > 0) sender_name else "Пользователь";
    _ = canvas.drawText(card_x + 54, card_y + 14, name_str, accent_color, 1);

    // Draw vertical quote stripe next to text
    const stripe_x = card_x + 54;
    const stripe_y = card_y + 36;
    const stripe_h = text_block_height + 4;
    canvas.drawRoundRect(stripe_x, stripe_y, 3, stripe_h, 1, accent_color, 0, 0);

    // Draw multi-line quoted message text
    var line_y = stripe_y;
    var l: usize = 0;
    while (l < line_count) : (l += 1) {
        const l_slice = lines_buf[l][0..lines_len[l]];
        _ = canvas.drawText(stripe_x + 10, line_y, l_slice, Color.DARK_TEXT, 1);
        line_y += line_spacing;
    }

    // Draw timestamp & quote indicator at bottom right
    const time_str = if (time.len > 0) time else "12:00";
    const time_w = time_str.len * font.GLYPH_WIDTH;
    const time_x = card_x + card_w - time_w - 18;
    const time_y = card_y + card_h - 20;
    _ = canvas.drawText(time_x, time_y, time_str, Color.DARK_TIME, 1);

    // Encode to PNG bytes
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

const std = @import("std");
const testing = std.testing;
const plugin = @import("plugin.zig");
const renderer = @import("renderer.zig");
const font = @import("font.zig");

test "utf8Truncate ascii" {
    const text = "Hello world!";
    const res = plugin.utf8Truncate(text, 5);
    try testing.expectEqualStrings("Hello", res);
}

test "utf8Truncate cyrillic exact boundary" {
    // "Привет" is 12 bytes (2 bytes per char: П, р, и, в, е, т)
    const text = "Привет";
    try testing.expectEqual(@as(usize, 12), text.len);

    // Cutting at 4 bytes (2 characters "Пр")
    const res4 = plugin.utf8Truncate(text, 4);
    try testing.expectEqualStrings("Пр", res4);

    // Cutting at 5 bytes (middle of "и") -> must back up to 4 bytes ("Пр")
    const res5 = plugin.utf8Truncate(text, 5);
    try testing.expectEqualStrings("Пр", res5);

    // Cutting at 6 bytes (exact 3 characters "При")
    const res6 = plugin.utf8Truncate(text, 6);
    try testing.expectEqualStrings("При", res6);
}

test "utf8Truncate 4-byte emoji boundary" {
    // "💬" is 3 bytes (0xE1 0x92 0xAC), "🔥" is 4 bytes (0xF0 0x9F 0x94 0xA5)
    const text = "A🔥B";
    // text is 1 + 4 + 1 = 6 bytes
    // Cutting at 3 bytes (middle of emoji) -> must back up to 1 byte ("A")
    const res3 = plugin.utf8Truncate(text, 3);
    try testing.expectEqualStrings("A", res3);

    // Cutting at 5 bytes (exact after emoji) -> "A🔥"
    const res5 = plugin.utf8Truncate(text, 5);
    try testing.expectEqualStrings("A🔥", res5);
}

test "escapeJson handles quotes, slashes, and control characters" {
    const input = "Hello \"World\"\nLine 2\\Path\tTab";
    var out_buf: [256]u8 = undefined;
    const escaped = plugin.escapeJson(input, &out_buf);
    try testing.expectEqualStrings("Hello \\\"World\\\"\\nLine 2\\\\Path\\tTab", escaped);
}

test "plugin metadata" {
    const meta = plugin.mandagram_plugin_metadata();
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

    // Create 5 quote files
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

    // Cleanup down to 3 files
    plugin.cleanupCacheDir(tmp_path, 3);

    // Count remaining
    var count: usize = 0;
    var iter = tmp.dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "quote_reply_")) {
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "font module provides valid glyphs for ascii and cyrillic" {
    const glyph_a = font.getGlyph('A');
    var sum_a: u32 = 0;
    for (glyph_a) |b| sum_a += b;
    try testing.expect(sum_a > 0);

    const glyph_cyr_b = font.getGlyph(0x0411); // 'Б'
    var sum_b: u32 = 0;
    for (glyph_cyr_b) |b| sum_b += b;
    try testing.expect(sum_b > 0);
}

test "png encoder produces valid PNG structure" {
    const width = 64;
    const height = 32;
    var pixels: [width * height]u32 = undefined;
    @memset(&pixels, 0xFF00FF00); // Green

    const png_bytes = try renderer.encodePng(testing.allocator, width, height, &pixels);
    defer testing.allocator.free(png_bytes);

    // PNG signature
    try testing.expect(png_bytes.len > 64);
    try testing.expectEqualStrings("\x89PNG\r\n\x1a\n", png_bytes[0..8]);

    // IHDR chunk
    try testing.expectEqualStrings("IHDR", png_bytes[12..16]);

    // IEND chunk at end
    const end_offset = png_bytes.len - 12;
    try testing.expectEqualStrings("IEND", png_bytes[end_offset + 4 .. end_offset + 8]);
}

test "renderQuoteCard produces valid card PNG" {
    const png_data = try renderer.renderQuoteCard(
        testing.allocator,
        "Pavel Durov",
        "Telegram is fast and secure. Here is an authentic quote reply!",
        "19:42",
        "PD",
        false,
    );
    defer testing.allocator.free(png_data);

    try testing.expect(png_data.len > 1000);
    try testing.expectEqualStrings("\x89PNG\r\n\x1a\n", png_data[0..8]);
}

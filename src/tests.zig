const std = @import("std");
const testing = std.testing;
const plugin = @import("plugin.zig");

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

test "plugin metadata" {
    const meta = plugin.mandagram_plugin_metadata();
    try testing.expect(meta != null);
    try testing.expectEqualStrings("KvoteReply", std.mem.span(meta.?.name));
    try testing.expectEqualStrings("1.0.0", std.mem.span(meta.?.version));
    try testing.expectEqualStrings("OwnerTS", std.mem.span(meta.?.author));
}

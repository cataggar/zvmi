//! Minimal, hand-rolled XML helpers for the specific, shallow message shapes
//! used by the Azure WireServer goal-state protocol (Versions.xml,
//! GoalState.xml, and the Health report body this repo builds and sends).
//!
//! This is deliberately not a general-purpose XML parser: it does not track
//! nesting depth, does not validate well-formedness, and assumes callers
//! search within an appropriately scoped substring (e.g. the block returned
//! by an outer `findElement` call) when a tag name could otherwise appear at
//! more than one nesting level in the same document (see `ElementIterator`
//! and its use for `<Supported><Version>...</Version>...</Supported>`).
const std = @import("std");

pub const ParseError = error{
    ElementNotFound,
    UnterminatedElement,
    TagTooLong,
};

/// Largest tag name this parser supports (used to size a stack buffer for
/// building the "</tag>" closing-tag needle). Every tag name actually used
/// by the goal-state/health-report/versions XML shapes is well under this.
const max_tag_len = 64;

/// Returns the inner text of the first `<tag>...</tag>` (or self-closing
/// `<tag/>`) element found in `xml_text`, searching from the start.
pub fn findElement(xml_text: []const u8, tag: []const u8) ?[]const u8 {
    return (findElementFrom(xml_text, tag, 0) orelse return null).text;
}

pub const Found = struct {
    text: []const u8,
    /// Offset in the original `xml_text` right after the element's closing
    /// tag (or self-closing tag), suitable as the `start` for a subsequent
    /// search to find the *next* sibling element.
    end_pos: usize,
};

/// Like `findElement`, but starts searching at byte offset `start` and also
/// returns where the match ended, so callers can resume searching after it
/// (see `ElementIterator`).
pub fn findElementFrom(xml_text: []const u8, tag: []const u8, start: usize) ?Found {
    if (tag.len == 0 or tag.len > max_tag_len) return null;

    var i = start;
    while (i < xml_text.len) {
        const lt = std.mem.indexOfScalarPos(u8, xml_text, i, '<') orelse return null;
        const after_lt = lt + 1;

        // Skip closing tags, comments, and processing instructions -- none
        // of those can be the start of the element we're looking for.
        if (after_lt >= xml_text.len or xml_text[after_lt] == '/' or xml_text[after_lt] == '!' or xml_text[after_lt] == '?') {
            i = after_lt;
            continue;
        }

        if (after_lt + tag.len > xml_text.len or !std.mem.eql(u8, xml_text[after_lt .. after_lt + tag.len], tag)) {
            i = after_lt;
            continue;
        }

        // Confirm a tag-name boundary follows (not e.g. "Versionx"
        // partially matching "Version").
        const boundary = after_lt + tag.len;
        const boundary_ok = boundary < xml_text.len and switch (xml_text[boundary]) {
            '>', ' ', '\t', '\r', '\n', '/' => true,
            else => false,
        };
        if (!boundary_ok) {
            i = after_lt;
            continue;
        }

        const gt = std.mem.indexOfScalarPos(u8, xml_text, boundary, '>') orelse return null;
        if (xml_text[gt - 1] == '/') {
            // Self-closing element: <Tag .../> with no text content.
            return .{ .text = xml_text[gt + 1 .. gt + 1], .end_pos = gt + 1 };
        }

        const content_start = gt + 1;
        var needle_buf: [max_tag_len + 3]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "</{s}>", .{tag}) catch return null;
        const close_idx = std.mem.indexOfPos(u8, xml_text, content_start, needle) orelse return null;
        return .{ .text = xml_text[content_start..close_idx], .end_pos = close_idx + needle.len };
    }
    return null;
}

/// Iterates over every immediate `<tag>...</tag>` occurrence in `xml_text`
/// in document order (e.g. the repeated `<Version>` children of
/// `<Supported>`). Intended to be called on an already block-scoped
/// substring (see `findElement`) when the same tag name also appears
/// elsewhere in the outer document.
pub const ElementIterator = struct {
    xml_text: []const u8,
    tag: []const u8,
    pos: usize = 0,

    pub fn init(xml_text: []const u8, tag: []const u8) ElementIterator {
        return .{ .xml_text = xml_text, .tag = tag };
    }

    pub fn next(self: *ElementIterator) ?[]const u8 {
        const found = findElementFrom(self.xml_text, self.tag, self.pos) orelse return null;
        self.pos = found.end_pos;
        return found.text;
    }
};

/// Decodes the handful of XML entities that can appear in the text content
/// of the WireServer protocol messages this repo cares about (`&amp;`,
/// `&lt;`, `&gt;`, `&quot;`, `&apos;`). Returns a newly allocated copy even
/// when `text` contains no entities, for a uniform ownership story.
pub fn decodeEntitiesAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(allocator, text.len);
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            const rest = text[i..];
            const decoded: struct { ch: u8, len: usize } = blk: {
                if (std.mem.startsWith(u8, rest, "&amp;")) break :blk .{ .ch = '&', .len = 5 };
                if (std.mem.startsWith(u8, rest, "&lt;")) break :blk .{ .ch = '<', .len = 4 };
                if (std.mem.startsWith(u8, rest, "&gt;")) break :blk .{ .ch = '>', .len = 4 };
                if (std.mem.startsWith(u8, rest, "&quot;")) break :blk .{ .ch = '"', .len = 6 };
                if (std.mem.startsWith(u8, rest, "&apos;")) break :blk .{ .ch = '\'', .len = 6 };
                break :blk .{ .ch = 0, .len = 0 };
            };
            if (decoded.len != 0) {
                try out.append(allocator, decoded.ch);
                i += decoded.len;
                continue;
            }
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Escapes `&`, `<`, and `>` in `text` so it's safe to embed as XML element
/// text content (matching Python's `xml.sax.saxutils.escape` default
/// behavior, which the real WALinuxAgent uses to build its health report).
pub fn escapeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(allocator, text.len);
    errdefer out.deinit(allocator);

    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

test "findElement returns inner text of a simple element" {
    const xml = "<Root><Incarnation>1</Incarnation></Root>";
    try std.testing.expectEqualStrings("1", findElement(xml, "Incarnation").?);
}

test "findElement ignores unrelated tags with a shared prefix" {
    const xml = "<Root><VersionExtra>x</VersionExtra><Version>2012-11-30</Version></Root>";
    try std.testing.expectEqualStrings("2012-11-30", findElement(xml, "Version").?);
}

test "findElement returns null when the tag is absent" {
    const xml = "<Root><Foo>bar</Foo></Root>";
    try std.testing.expectEqual(@as(?[]const u8, null), findElement(xml, "Missing"));
}

test "findElement handles self-closing tags as empty text" {
    const xml = "<Root><Empty/></Root>";
    try std.testing.expectEqualStrings("", findElement(xml, "Empty").?);
}

test "ElementIterator walks repeated sibling elements in order" {
    const xml = "<Supported><Version>2010-12-15</Version><Version>2012-11-30</Version></Supported>";
    var it = ElementIterator.init(xml, "Version");
    try std.testing.expectEqualStrings("2010-12-15", it.next().?);
    try std.testing.expectEqualStrings("2012-11-30", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "findElement is block-scoped when given a substring" {
    const xml = "<Versions><Preferred><Version>2012-11-30</Version></Preferred>" ++
        "<Supported><Version>2010-12-15</Version><Version>2012-11-30</Version></Supported></Versions>";
    const preferred_block = findElement(xml, "Preferred").?;
    try std.testing.expectEqualStrings("2012-11-30", findElement(preferred_block, "Version").?);

    const supported_block = findElement(xml, "Supported").?;
    var it = ElementIterator.init(supported_block, "Version");
    try std.testing.expectEqualStrings("2010-12-15", it.next().?);
    try std.testing.expectEqualStrings("2012-11-30", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "decodeEntitiesAlloc decodes the standard XML entities" {
    const allocator = std.testing.allocator;
    const decoded = try decodeEntitiesAlloc(allocator, "a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("a & b <c> \"d\" 'e'", decoded);
}

test "decodeEntitiesAlloc passes through text with no entities" {
    const allocator = std.testing.allocator;
    const decoded = try decodeEntitiesAlloc(allocator, "plain-text-123");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("plain-text-123", decoded);
}

test "escapeAlloc escapes ampersand and angle brackets only" {
    const allocator = std.testing.allocator;
    const escaped = try escapeAlloc(allocator, "a & b <c> \"d\" 'e'");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("a &amp; b &lt;c&gt; \"d\" 'e'", escaped);
}

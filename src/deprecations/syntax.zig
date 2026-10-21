//! The forms a Zig release took out of the language, rewritten over the
//! tokens before the syntax tree is read: a file in a dropped form does not
//! parse under the new release, so nothing on the tree can reach it. Only a
//! file that does not parse is repaired, and only at the sites of a form its
//! release's table names.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = std.zig.Token;

/// A form a release dropped.
pub const Form = enum {
    /// `a ** n`, array repetition (gone in 0.17). A one-element array
    /// literal becomes `@as([n]T, @splat(e))`; any other operand is
    /// rewritten by hand.
    array_repeat,

    /// The form, and its rewrite, as source: this release's parser must
    /// refuse the first and take the second, or the table is wrong for it.
    pub fn sample(form: Form) struct { old: [:0]const u8, new: [:0]const u8 } {
        return switch (form) {
            .array_repeat => .{ .old = "const a = [_]u8{0} ** 4;\n", .new = "const a = @as([4]u8, @splat(0));\n" },
        };
    }

    /// What a site the rewrite cannot make asks of a person.
    fn byHand(form: Form) struct { name: []const u8, doc: []const u8 } {
        return switch (form) {
            .array_repeat => .{ .name = "a ** n", .doc = "array repetition is gone: `@splat` repeats one element, a longer pattern is written out" },
        };
    }
};

/// One site rewritten.
pub const Rewritten = struct { line: usize, old: []const u8, new: []const u8 };
/// One site left to a person.
pub const ByHand = struct { line: usize, name: []const u8, doc: []const u8 };
pub const Result = struct { text: [:0]const u8, rewritten: []const Rewritten, by_hand: []const ByHand };

const Edit = struct { start: usize, end: usize, text: []const u8 };

/// `text` with every site of `forms` it can rewrite rewritten, and the ones
/// it cannot listed.
pub fn repair(a: Allocator, text: [:0]const u8, forms: []const Form) !Result {
    var tokens: std.ArrayList(Token) = .empty;
    var tokenizer: std.zig.Tokenizer = .init(text);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(a, token);
        if (token.tag == .eof) break;
    }
    var edits: std.ArrayList(Edit) = .empty;
    var rewritten: std.ArrayList(Rewritten) = .empty;
    var by_hand: std.ArrayList(ByHand) = .empty;
    for (forms) |form| switch (form) {
        .array_repeat => try arrayRepeats(a, text, tokens.items, &edits, &rewritten, &by_hand),
    };
    std.mem.sort(Edit, edits.items, {}, struct {
        fn before(_: void, x: Edit, y: Edit) bool {
            return x.start < y.start;
        }
    }.before);
    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (edits.items) |edit| {
        try out.appendSlice(a, text[cursor..edit.start]);
        try out.appendSlice(a, edit.text);
        cursor = edit.end;
    }
    try out.appendSlice(a, text[cursor..]);
    return .{ .text = try out.toOwnedSliceSentinel(a, 0), .rewritten = rewritten.items, .by_hand = by_hand.items };
}

/// Every binary `**`: two asterisks with nothing between them after a token
/// that ends an operand, which a pointer to a pointer (`**T`) never follows.
fn arrayRepeats(a: Allocator, text: []const u8, tokens: []const Token, edits: *std.ArrayList(Edit), rewritten: *std.ArrayList(Rewritten), by_hand: *std.ArrayList(ByHand)) !void {
    var i: usize = 1;
    while (i + 2 < tokens.len) : (i += 1) {
        if (tokens[i].tag != .asterisk or tokens[i + 1].tag != .asterisk or tokens[i].loc.end != tokens[i + 1].loc.start) continue;
        if (!endsOperand(tokens[i - 1].tag)) continue;
        const line = 1 + std.mem.count(u8, text[0..tokens[i].loc.start], "\n");
        const site = oneElement(text, tokens, i) orelse {
            const hand = Form.array_repeat.byHand();
            try by_hand.append(a, .{ .line = line, .name = hand.name, .doc = hand.doc });
            continue;
        };
        const new = try a.print("@as([{s}]{s}, @splat({s}))", .{ site.count, site.child, site.element });
        try edits.append(a, .{ .start = site.start, .end = site.end, .text = new });
        try rewritten.append(a, .{ .line = line, .old = text[site.start..site.end], .new = new });
        i = site.after;
    }
}

fn endsOperand(tag: Token.Tag) bool {
    return switch (tag) {
        .identifier, .number_literal, .string_literal, .char_literal, .r_paren, .r_bracket, .r_brace => true,
        else => false,
    };
}

const Site = struct { start: usize, end: usize, count: []const u8, child: []const u8, element: []const u8, after: usize };

/// `[_]T{ e } ** n` or `[1]T{ e } ** n`, with `n` a name, a number, a
/// field of a name or a parenthesized expression; null for anything else.
fn oneElement(text: []const u8, tokens: []const Token, star: usize) ?Site {
    // The literal: `{ e }` before the operator.
    if (tokens[star - 1].tag != .r_brace) return null;
    const open = matchBack(tokens, star - 1, .l_brace, .r_brace) orelse return null;
    if (open == 0) return null;
    // Its type, back to the `[` that opens it.
    var start = open;
    var depth: usize = 0;
    while (start > 0) {
        const tag = tokens[start - 1].tag;
        switch (tag) {
            .r_bracket => depth += 1,
            .l_bracket => {
                if (depth == 0) return null;
                depth -= 1;
            },
            .identifier, .period, .asterisk, .question_mark, .keyword_const, .keyword_volatile, .number_literal, .colon => {},
            else => break,
        }
        start -= 1;
        if (depth == 0 and tokens[start].tag == .l_bracket) {
            const before = if (start == 0) Token.Tag.eof else tokens[start - 1].tag;
            if (!typeContinues(before)) break;
        }
    }
    if (tokens[start].tag != .l_bracket) return null;
    const close = matchForward(tokens, start, .l_bracket, .r_bracket) orelse return null;
    if (close != start + 2) return null;
    const length = text[tokens[start + 1].loc.start..tokens[start + 1].loc.end];
    if (!std.mem.eql(u8, length, "_") and !std.mem.eql(u8, length, "1")) return null;
    if (close + 1 >= open) return null;
    const child = text[tokens[close + 1].loc.start..tokens[open - 1].loc.end];
    // One element, a trailing comma allowed.
    var element_end = star - 1;
    if (tokens[element_end - 1].tag == .comma) element_end -= 1;
    if (element_end == open + 1) return null;
    var nest: usize = 0;
    for (tokens[open + 1 .. element_end]) |token| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => nest += 1,
        .r_paren, .r_bracket, .r_brace => nest -|= 1,
        .comma => if (nest == 0) return null,
        else => {},
    };
    const element = text[tokens[open + 1].loc.start..tokens[element_end - 1].loc.end];
    // The count after the operator.
    var last = star + 2;
    switch (tokens[last].tag) {
        .number_literal, .identifier => while (last + 2 < tokens.len and tokens[last + 1].tag == .period and tokens[last + 2].tag == .identifier) {
            last += 2;
        },
        .l_paren => last = matchForward(tokens, last, .l_paren, .r_paren) orelse return null,
        else => return null,
    }
    switch (tokens[last + 1].tag) {
        .l_paren, .l_bracket, .period => return null,
        else => {},
    }
    return .{
        .start = tokens[start].loc.start,
        .end = tokens[last].loc.end,
        .count = text[tokens[star + 2].loc.start..tokens[last].loc.end],
        .child = child,
        .element = element,
        .after = last,
    };
}

/// Whether a type goes on before `[` at this token: `[_][4]u8` is one type
/// read from its last `[`, `= [_]u8` starts at it.
fn typeContinues(tag: Token.Tag) bool {
    return switch (tag) {
        .r_bracket, .asterisk, .question_mark => true,
        else => false,
    };
}

fn matchBack(tokens: []const Token, at: usize, open: Token.Tag, close: Token.Tag) ?usize {
    var depth: usize = 0;
    var i = at + 1;
    while (i > 0) {
        i -= 1;
        if (tokens[i].tag == close) depth += 1;
        if (tokens[i].tag == open) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn matchForward(tokens: []const Token, at: usize, open: Token.Tag, close: Token.Tag) ?usize {
    var depth: usize = 0;
    for (tokens[at..], at..) |token, i| {
        if (token.tag == open) depth += 1;
        if (token.tag == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
        if (token.tag == .eof) return null;
    }
    return null;
}

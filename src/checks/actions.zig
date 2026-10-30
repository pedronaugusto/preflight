//! The actions a GitHub workflow uses: every `uses` key of its YAML, in block style or flow
//! style (`- {uses: o/r@v1}`), with the value it names. Read from the YAML's structure, not
//! its lines, so no style hides one. A block scalar's text (a `run: |` script) is text, not
//! keys. What cannot be read for certain is an error at its line, as a check that skipped it
//! would pass it: a `uses` naming no plain or quoted value, or one continued on the next line,
//! a quoted key or `uses` value with an escape or a line break (which YAML decodes), an alias
//! as a key or to no scalar, an explicit `?` key, a tab in indentation.
const std = @import("std");

pub const Use = struct { value: []const u8, line: usize };

/// Why a workflow could not be read, and where.
pub const Problem = struct { line: usize, what: []const u8 };

pub const Error = error{ Unreadable, OutOfMemory };

/// Every `uses` value of the YAML `text`, in order.
pub fn uses(a: std.mem.Allocator, text: []const u8, problem: *Problem) Error![]const Use {
    var scanner: Scanner = .{ .a = a, .text = text, .problem = problem };
    try scanner.scan();
    const tokens = scanner.tokens.items;
    // Each anchor, by name, at the token of the scalar it holds.
    var anchors: std.StringHashMapUnmanaged(usize) = .empty;
    var out: std.ArrayList(Use) = .empty;
    for (tokens, 0..) |token, i| {
        // A key is read only as it is written: one that escapes or folds a character, or an
        // alias, could be `uses`.
        if (token.kind == .alias and isKey(tokens, i)) return fail(problem, token.line, "an alias as a key");
        if (token.kind == .scalar and isKey(tokens, i) and !token.exact) return fail(problem, token.line, "a quoted key with an escape or a line break, which this reader does not decode");
        if (token.kind == .anchor and i + 1 < tokens.len and tokens[i + 1].kind == .scalar and !isKey(tokens, i + 1)) {
            try anchors.put(a, token.text, i + 1);
        }
        if (token.kind != .scalar or !isKey(tokens, i) or !std.mem.eql(u8, token.text, "uses")) continue;
        var at = i + 2;
        while (at < tokens.len and (tokens[at].kind == .anchor or tokens[at].kind == .tag)) at += 1;
        const value = if (at < tokens.len and tokens[at].kind == .scalar and !isKey(tokens, at))
            at
        else if (at < tokens.len and tokens[at].kind == .alias)
            anchors.get(tokens[at].text) orelse return fail(problem, tokens[at].line, "`uses` names an alias whose anchor holds no scalar before it")
        else
            return fail(problem, token.line, "`uses` names no action as a plain or quoted scalar");
        if (!tokens[value].exact) return fail(problem, tokens[value].line, "`uses` names its action with an escape or a line break, which this reader does not decode");
        if (continued(tokens, value)) return fail(problem, tokens[value].line, "`uses` names its action in a plain scalar continued on the next line");
        try out.append(a, .{ .value = tokens[value].text, .line = tokens[at].line });
    }
    return out.items;
}

fn isKey(tokens: []const Token, i: usize) bool {
    return i + 1 < tokens.len and tokens[i + 1].kind == .colon;
}

/// Whether the plain scalar at `i` goes on in the next token: a scalar with no indicator
/// between them that is no key, as only a multi-line plain scalar's next line can be.
fn continued(tokens: []const Token, i: usize) bool {
    return i + 1 < tokens.len and tokens[i + 1].kind == .scalar and !isKey(tokens, i + 1);
}

fn fail(problem: *Problem, line: usize, what: []const u8) error{Unreadable} {
    problem.* = .{ .line = line, .what = what };
    return error.Unreadable;
}

const Token = struct {
    kind: enum { scalar, colon, dash, open, close, comma, anchor, alias, tag, block },
    text: []const u8 = "",
    line: usize,
    column: usize,
    quoted: bool = false,
    /// The text is the scalar's value as written: no escape, doubled quote or line break in
    /// a quoted one, which YAML would decode or fold.
    exact: bool = true,
};

const Scanner = struct {
    a: std.mem.Allocator,
    text: []const u8,
    problem: *Problem,
    tokens: std.ArrayList(Token) = .empty,
    i: usize = 0,
    line: usize = 1,
    line_start: usize = 0,
    depth: usize = 0,

    fn scan(s: *Scanner) Error!void {
        while (s.i < s.text.len) {
            if (s.i == s.line_start) try s.indentation();
            if (s.i >= s.text.len) break;
            const c = s.text[s.i];
            switch (c) {
                '\n' => s.newline(),
                ' ', '\t', '\r' => s.i += 1,
                '#' => s.skipLine(),
                '{', '[' => {
                    try s.emit(.open, "");
                    s.depth += 1;
                    s.i += 1;
                },
                '}', ']' => {
                    if (s.depth == 0) return fail(s.problem, s.line, "a flow collection closes that never opened");
                    try s.emit(.close, "");
                    s.depth -= 1;
                    s.i += 1;
                },
                ',' => {
                    try s.emit(.comma, "");
                    s.i += 1;
                },
                '?' => if (s.separated(s.i + 1)) return fail(s.problem, s.line, "an explicit key (`?`)") else try s.plain(),
                ':' => if (s.separated(s.i + 1) or s.afterQuoted()) {
                    try s.emit(.colon, "");
                    s.i += 1;
                } else try s.plain(),
                '-' => if (s.depth == 0 and s.separated(s.i + 1)) {
                    try s.emit(.dash, "");
                    s.i += 1;
                } else try s.plain(),
                '&', '*', '!' => {
                    const start = s.i + 1;
                    s.i = start;
                    while (s.i < s.text.len and !isSpace(s.text[s.i]) and !isFlow(s.text[s.i]) and s.text[s.i] != '\n' and s.text[s.i] != '\r') s.i += 1;
                    try s.emitAt(switch (c) {
                        '&' => .anchor,
                        '*' => .alias,
                        else => .tag,
                    }, s.text[start..s.i], start);
                },
                '|', '>' => try s.block(),
                '"' => try s.double(),
                '\'' => try s.single(),
                else => try s.plain(),
            }
        }
        if (s.depth != 0) return fail(s.problem, s.line, "a flow collection never closes");
    }

    /// A line's start: its indentation, a document marker or a directive.
    fn indentation(s: *Scanner) Error!void {
        var at = s.i;
        var tab = false;
        while (at < s.text.len and (s.text[at] == ' ' or s.text[at] == '\t')) : (at += 1) tab = tab or s.text[at] == '\t';
        const blank = at == s.text.len or s.text[at] == '\n' or s.text[at] == '\r' or s.text[at] == '#';
        if (tab and !blank and s.depth == 0) return fail(s.problem, s.line, "a tab in indentation, which YAML refuses");
        s.i = at;
        if (at != s.line_start) return;
        const rest = s.text[at..];
        if (std.mem.startsWith(u8, rest, "%")) return s.skipLine();
        if ((std.mem.startsWith(u8, rest, "---") or std.mem.startsWith(u8, rest, "...")) and s.separated(at + 3)) s.i = at + 3;
    }

    /// A literal or folded block scalar: its text is the lines indented past the key or
    /// sequence entry it is the value of, which are not keys.
    fn block(s: *Scanner) Error!void {
        const tokens = s.tokens.items;
        var parent: ?usize = null;
        if (tokens.len >= 2 and tokens[tokens.len - 1].kind == .colon and tokens[tokens.len - 2].line == s.line) parent = tokens[tokens.len - 2].column;
        if (tokens.len >= 1 and tokens[tokens.len - 1].kind == .dash and tokens[tokens.len - 1].line == s.line) parent = tokens[tokens.len - 1].column;
        try s.emit(.block, "");
        s.skipLine();
        while (s.i < s.text.len) {
            s.newline();
            var at = s.i;
            while (at < s.text.len and s.text[at] == ' ') at += 1;
            const blank = at == s.text.len or s.text[at] == '\n' or s.text[at] == '\r';
            // The first line indented no further than the parent is the parent's next part.
            if (!blank and at - s.i <= (parent orelse 0)) return;
            s.i = at;
            s.skipLine();
        }
    }

    fn double(s: *Scanner) Error!void {
        const line = s.line;
        const column = s.i - s.line_start;
        s.i += 1;
        const start = s.i;
        var exact = true;
        while (s.i < s.text.len and s.text[s.i] != '"') {
            if (s.text[s.i] == '\\' or s.text[s.i] == '\n') exact = false;
            if (s.text[s.i] == '\\') s.i += 1 else if (s.text[s.i] == '\n') s.newlineInside();
            s.i += 1;
        }
        if (s.i >= s.text.len) return fail(s.problem, line, "a double-quoted scalar never closes");
        try s.tokens.append(s.a, .{ .kind = .scalar, .text = s.text[start..s.i], .line = line, .column = column, .quoted = true, .exact = exact });
        s.i += 1;
    }

    fn single(s: *Scanner) Error!void {
        const line = s.line;
        const column = s.i - s.line_start;
        s.i += 1;
        const start = s.i;
        var exact = true;
        while (s.i < s.text.len) {
            if (s.text[s.i] == '\'') {
                if (s.i + 1 < s.text.len and s.text[s.i + 1] == '\'') {
                    exact = false;
                    s.i += 2;
                    continue;
                }
                break;
            }
            if (s.text[s.i] == '\n') {
                exact = false;
                s.newlineInside();
            }
            s.i += 1;
        }
        if (s.i >= s.text.len) return fail(s.problem, line, "a single-quoted scalar never closes");
        try s.tokens.append(s.a, .{ .kind = .scalar, .text = s.text[start..s.i], .line = line, .column = column, .quoted = true, .exact = exact });
        s.i += 1;
    }

    /// A plain scalar: up to `: `, ` #`, the line's end, and in a flow collection a flow
    /// indicator.
    fn plain(s: *Scanner) Error!void {
        const start = s.i;
        while (s.i < s.text.len) : (s.i += 1) {
            const c = s.text[s.i];
            if (c == '\n' or c == '\r') break;
            if (c == ':' and (s.separated(s.i + 1) or (s.depth > 0 and s.i + 1 < s.text.len and isFlow(s.text[s.i + 1])))) break;
            if (c == '#' and s.i > start and isSpace(s.text[s.i - 1])) break;
            if (s.depth > 0 and isFlow(c)) break;
        }
        try s.emitAt(.scalar, std.mem.trimEnd(u8, s.text[start..s.i], " \t"), start);
    }

    /// Whether the byte at `at` ends an indicator: a space, the line's end, the text's end,
    /// or in a flow collection a flow indicator.
    fn separated(s: *const Scanner, at: usize) bool {
        if (at >= s.text.len) return true;
        const c = s.text[at];
        return isSpace(c) or c == '\n' or c == '\r' or (s.depth > 0 and isFlow(c));
    }

    /// A `:` right after a quoted key is its indicator, as JSON writes it (`"uses":"x"`).
    fn afterQuoted(s: *const Scanner) bool {
        const tokens = s.tokens.items;
        if (tokens.len == 0 or !tokens[tokens.len - 1].quoted) return false;
        return s.i > 0 and (s.text[s.i - 1] == '"' or s.text[s.i - 1] == '\'');
    }

    fn emit(s: *Scanner, kind: @FieldType(Token, "kind"), text: []const u8) Error!void {
        try s.emitAt(kind, text, s.i);
    }

    fn emitAt(s: *Scanner, kind: @FieldType(Token, "kind"), text: []const u8, at: usize) Error!void {
        try s.tokens.append(s.a, .{ .kind = kind, .text = text, .line = s.line, .column = at - s.line_start });
    }

    fn skipLine(s: *Scanner) void {
        while (s.i < s.text.len and s.text[s.i] != '\n') s.i += 1;
    }

    fn newline(s: *Scanner) void {
        s.i += 1;
        s.line += 1;
        s.line_start = s.i;
    }

    /// A line break inside a quoted scalar: counted, not a line's start.
    fn newlineInside(s: *Scanner) void {
        s.line += 1;
        s.line_start = s.i + 1;
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isFlow(c: u8) bool {
    return c == ',' or c == '[' or c == ']' or c == '{' or c == '}';
}

fn expectUses(text: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var problem: Problem = .{ .line = 0, .what = "" };
    const got = try uses(arena.allocator(), text, &problem);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |value, use| try std.testing.expectEqualStrings(value, use.value);
}

fn expectUnreadable(text: []const u8, what: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var problem: Problem = .{ .line = 0, .what = "" };
    try std.testing.expectError(error.Unreadable, uses(arena.allocator(), text, &problem));
    try std.testing.expect(std.mem.find(u8, problem.what, what) != null);
}

test "uses is read in block style and flow style alike, quoted or not, a comment beside it" {
    try expectUses(
        \\jobs:
        \\  a:
        \\    steps:
        \\      - uses: actions/checkout@v4 # v4
        \\      - {uses: mlugg/setup-zig@v2, with: {version: 0.17.0}}
        \\      - "uses": 'o/r@main'
        \\    uses: "o/r/.github/workflows/zig.yml@main"
        \\  b: {steps: [{"uses":"x/y@v1"}, {run: echo}]}
        \\
    , &.{ "actions/checkout@v4", "mlugg/setup-zig@v2", "o/r@main", "o/r/.github/workflows/zig.yml@main", "x/y@v1" });
}

test "a block scalar's text holds no keys, however it is indented past its key" {
    try expectUses(
        \\steps:
        \\  - run: |
        \\      echo uses: not/an@action
        \\    uses: o/r@v1
        \\  - name: >-
        \\        uses: still/text@v0
        \\
        \\        uses: and/more@v0
        \\    uses: p/q@v2
        \\
    , &.{ "o/r@v1", "p/q@v2" });
}

test "an alias to a scalar is read as its anchor's value; what cannot be read for certain is an error" {
    try expectUses("a: &checkout actions/checkout@v4\nsteps:\n  - uses: *checkout\n", &.{"actions/checkout@v4"});
    try expectUnreadable("steps:\n  - uses: *nowhere\n", "alias");
    try expectUnreadable("steps:\n  - uses:\n    with: {}\n", "names no action");
    try expectUnreadable("steps:\n  - uses: |\n      o/r@v1\n", "names no action");
    try expectUnreadable("steps:\n  - ? uses\n    : o/r@v1\n", "explicit key");
    try expectUnreadable("steps:\n\t- uses: o/r@v1\n", "tab");
    try expectUnreadable("steps: [{uses: o/r@v1}\n", "never closes");
}

test "a key or a value YAML would decode or join is refused, never read as written (review-1029b m-c)" {
    try expectUnreadable("steps:\n  - \"u\\x73es\": o/r@main\n", "quoted key");
    try expectUnreadable("steps:\n  - \"\\u0075ses\": o/r@main\n", "quoted key");
    try expectUnreadable("steps:\n  - \"us\\\n    es\": o/r@main\n", "quoted key");
    try expectUnreadable("k: &k uses\nsteps:\n  - *k : o/r@main\n", "alias as a key");
    try expectUnreadable("steps:\n  - uses: \"o/r@\\x6dain\"\n", "with an escape");
    try expectUnreadable("steps:\n  - uses: 'o/r@it''s'\n", "with an escape");
    try expectUnreadable("steps:\n  - uses: o/r@\n      main\n", "continued on the next line");
    try expectUnreadable("a: &v o/r@\n  main\nsteps:\n  - uses: *v\n", "continued on the next line");
    // A run script's escapes are its own: only keys and what `uses` names are read.
    try expectUses("steps:\n  - run: \"echo \\\"hi\\\"\"\n    uses: o/r@v1\n  - uses:\n      o/r@v2\n", &.{ "o/r@v1", "o/r@v2" });
}

const std = @import("std");

pub const TokenType = enum {
    // Literals
    integer,
    float,
    string,

    // Identifiers
    identifier,

    // Keywords
    kw_var,
    kw_const,
    kw_fn,
    kw_return,
    kw_if,
    kw_else,
    kw_while,
    kw_true,
    kw_false,
    kw_null,
    kw_print,

    // Type keywords
    kw_int,
    kw_float,
    kw_string,
    kw_bool,

    // Operators
    plus,
    minus,
    star,
    slash,
    percent,
    assign,
    equal,
    not_equal,
    less,
    greater,
    less_equal,
    greater_equal,
    bang,
    amp_amp,
    pipe_pipe,

    // Delimiters
    lparen,
    rparen,
    lbrace,
    rbrace,
    semicolon,
    colon,
    comma,

    // Special
    eof,
    invalid,
};

pub const Token = struct {
    kind: TokenType,
    lexeme: []const u8,
    line: usize,

    pub fn format(self: Token, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}({s})", .{ @tagName(self.kind), self.lexeme });
    }
};

pub const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "var", .kw_var },
    .{ "const", .kw_const },
    .{ "fn", .kw_fn },
    .{ "return", .kw_return },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "null", .kw_null },
    .{ "print", .kw_print },
    .{ "int", .kw_int },
    .{ "float", .kw_float },
    .{ "string", .kw_string },
    .{ "bool", .kw_bool },
});

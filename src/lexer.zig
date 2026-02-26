const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const keywords = @import("token.zig").keywords;

pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: usize,

    pub const State = struct {
        pos: usize,
        line: usize,
    };

    pub fn saveState(self: *const Lexer) State {
        return .{ .pos = self.pos, .line = self.line };
    }

    pub fn restoreState(self: *Lexer, state: State) void {
        self.pos = state.pos;
        self.line = state.line;
    }

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
        };
    }

    pub fn nextToken(self: *Lexer) Token {
        self.skipWhitespaceAndComments();

        if (self.pos >= self.source.len) {
            return self.makeToken(.eof, "");
        }

        const start = self.pos;
        const c = self.advance();

        return switch (c) {
            '+' => self.makeToken(.plus, self.source[start..self.pos]),
            '-' => self.makeToken(.minus, self.source[start..self.pos]),
            '*' => self.makeToken(.star, self.source[start..self.pos]),
            '/' => self.makeToken(.slash, self.source[start..self.pos]),
            '%' => self.makeToken(.percent, self.source[start..self.pos]),
            '(' => self.makeToken(.lparen, self.source[start..self.pos]),
            ')' => self.makeToken(.rparen, self.source[start..self.pos]),
            '{' => self.makeToken(.lbrace, self.source[start..self.pos]),
            '}' => self.makeToken(.rbrace, self.source[start..self.pos]),
            ';' => self.makeToken(.semicolon, self.source[start..self.pos]),
            ':' => self.makeToken(.colon, self.source[start..self.pos]),
            ',' => self.makeToken(.comma, self.source[start..self.pos]),

            '=' => {
                if (self.match('=')) {
                    return self.makeToken(.equal, self.source[start..self.pos]);
                }
                return self.makeToken(.assign, self.source[start..self.pos]);
            },
            '!' => {
                if (self.match('=')) {
                    return self.makeToken(.not_equal, self.source[start..self.pos]);
                }
                return self.makeToken(.bang, self.source[start..self.pos]);
            },
            '<' => {
                if (self.match('=')) {
                    return self.makeToken(.less_equal, self.source[start..self.pos]);
                }
                return self.makeToken(.less, self.source[start..self.pos]);
            },
            '>' => {
                if (self.match('=')) {
                    return self.makeToken(.greater_equal, self.source[start..self.pos]);
                }
                return self.makeToken(.greater, self.source[start..self.pos]);
            },
            '&' => {
                if (self.match('&')) {
                    return self.makeToken(.amp_amp, self.source[start..self.pos]);
                }
                return self.makeToken(.invalid, self.source[start..self.pos]);
            },
            '|' => {
                if (self.match('|')) {
                    return self.makeToken(.pipe_pipe, self.source[start..self.pos]);
                }
                return self.makeToken(.invalid, self.source[start..self.pos]);
            },

            '"' => self.readString(start),

            else => {
                if (isDigit(c)) {
                    return self.readNumber(start);
                }
                if (isAlpha(c)) {
                    return self.readIdentifier(start);
                }
                return self.makeToken(.invalid, self.source[start..self.pos]);
            },
        };
    }

    fn readString(self: *Lexer, start: usize) Token {
        while (self.pos < self.source.len and self.peek() != '"' and self.peek() != '\n') {
            self.pos += 1;
        }
        if (self.pos >= self.source.len or self.peek() == '\n') {
            return self.makeToken(.invalid, self.source[start..self.pos]);
        }
        self.pos += 1; // closing quote
        return self.makeToken(.string, self.source[start..self.pos]);
    }

    fn readNumber(self: *Lexer, start: usize) Token {
        while (self.pos < self.source.len and isDigit(self.peek())) {
            self.pos += 1;
        }
        if (self.pos < self.source.len and self.peek() == '.' and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
            self.pos += 1; // consume '.'
            while (self.pos < self.source.len and isDigit(self.peek())) {
                self.pos += 1;
            }
            return self.makeToken(.float, self.source[start..self.pos]);
        }
        return self.makeToken(.integer, self.source[start..self.pos]);
    }

    fn readIdentifier(self: *Lexer, start: usize) Token {
        while (self.pos < self.source.len and (isAlpha(self.peek()) or isDigit(self.peek()))) {
            self.pos += 1;
        }
        const text = self.source[start..self.pos];
        const token_type = keywords.get(text) orelse .identifier;
        return self.makeToken(token_type, text);
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.peek();
            switch (c) {
                ' ', '\t', '\r' => self.pos += 1,
                '\n' => {
                    self.pos += 1;
                    self.line += 1;
                },
                '/' => {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                        while (self.pos < self.source.len and self.peek() != '\n') {
                            self.pos += 1;
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        return c;
    }

    fn peek(self: *Lexer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.pos >= self.source.len) return false;
        if (self.source[self.pos] != expected) return false;
        self.pos += 1;
        return true;
    }

    fn makeToken(self: *Lexer, token_type: TokenType, lexeme: []const u8) Token {
        return .{
            .kind = token_type,
            .lexeme = lexeme,
            .line = self.line,
        };
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }
};

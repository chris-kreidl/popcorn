const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const ast = @import("ast.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;

pub const Parser = struct {
    const ParseError = error{ ParseError, OutOfMemory };

    lexer: Lexer,
    current: Token,
    allocator: std.mem.Allocator,
    had_error: bool,
    error_msg: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var lexer = Lexer.init(source);
        const first = lexer.nextToken();
        return .{
            .lexer = lexer,
            .current = first,
            .allocator = allocator,
            .had_error = false,
            .error_msg = null,
        };
    }

    pub fn parse(self: *Parser) ParseError![]*Stmt {
        var stmts: std.ArrayList(*Stmt) = .empty;
        while (self.current.kind != .eof) {
            const s = try self.parseStatement();
            try stmts.append(self.allocator, s);
        }
        return try stmts.toOwnedSlice(self.allocator);
    }

    fn parseStatement(self: *Parser) ParseError!*Stmt {
        return switch (self.current.kind) {
            .kw_var, .kw_const => self.parseVarDecl(),
            .kw_fn => self.parseFnDecl(),
            .kw_if => self.parseIfStmt(),
            .kw_while => self.parseWhileStmt(),
            .kw_return => self.parseReturnStmt(),
            .kw_print => self.parsePrintStmt(),
            .lbrace => self.parseBlock(),
            else => self.parseExprStmtOrAssignment(),
        };
    }

    fn parseVarDecl(self: *Parser) ParseError!*Stmt {
        const is_const = self.current.kind == .kw_const;
        self.advance(); // consume var/const

        const name = self.current.lexeme;
        try self.expect(.identifier, "Expected variable name");

        var type_name: ?[]const u8 = null;
        if (self.current.kind == .colon) {
            self.advance();
            type_name = self.current.lexeme;
            if (self.current.kind != .kw_int and self.current.kind != .kw_float and
                self.current.kind != .kw_string and self.current.kind != .kw_bool)
            {
                return self.reportError("Expected type name");
            }
            self.advance();
        }

        try self.expect(.assign, "Expected '=' in variable declaration");
        const initializer = try self.parseExpression();
        try self.expect(.semicolon, "Expected ';' after variable declaration");

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .var_decl = .{
            .name = name,
            .type_name = type_name,
            .initializer = initializer,
            .is_const = is_const,
        } };
        return stmt;
    }

    fn parseFnDecl(self: *Parser) ParseError!*Stmt {
        self.advance(); // consume 'fn'

        const name = self.current.lexeme;
        try self.expect(.identifier, "Expected function name");
        try self.expect(.lparen, "Expected '(' after function name");

        var params: std.ArrayList(Stmt.Param) = .empty;
        if (self.current.kind != .rparen) {
            while (true) {
                const param_name = self.current.lexeme;
                try self.expect(.identifier, "Expected parameter name");
                try self.expect(.colon, "Expected ':' after parameter name");
                const type_name = self.current.lexeme;
                if (self.current.kind != .kw_int and self.current.kind != .kw_float and
                    self.current.kind != .kw_string and self.current.kind != .kw_bool)
                {
                    return self.reportError("Expected type name");
                }
                self.advance();
                try params.append(self.allocator, .{ .name = param_name, .type_name = type_name });
                if (self.current.kind != .comma) break;
                self.advance();
            }
        }
        try self.expect(.rparen, "Expected ')' after parameters");

        var return_type: ?[]const u8 = null;
        if (self.current.kind == .colon) {
            self.advance();
            return_type = self.current.lexeme;
            if (self.current.kind != .kw_int and self.current.kind != .kw_float and
                self.current.kind != .kw_string and self.current.kind != .kw_bool)
            {
                return self.reportError("Expected return type");
            }
            self.advance();
        }

        try self.expect(.lbrace, "Expected '{' before function body");
        const body = try self.parseStmtList();
        try self.expect(.rbrace, "Expected '}' after function body");

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .fn_decl = .{
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .body = body,
        } };
        return stmt;
    }

    fn parseIfStmt(self: *Parser) ParseError!*Stmt {
        self.advance(); // consume 'if'
        const condition = try self.parseExpression();

        try self.expect(.lbrace, "Expected '{' after if condition");
        const then_branch = try self.parseStmtList();
        try self.expect(.rbrace, "Expected '}' after if body");

        var else_branch: ?[]const *Stmt = null;
        if (self.current.kind == .kw_else) {
            self.advance();
            if (self.current.kind == .kw_if) {
                // else if
                const elif = try self.parseIfStmt();
                const slice = try self.allocator.alloc(*Stmt, 1);
                slice[0] = elif;
                else_branch = slice;
            } else {
                try self.expect(.lbrace, "Expected '{' after else");
                else_branch = try self.parseStmtList();
                try self.expect(.rbrace, "Expected '}' after else body");
            }
        }

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .if_stmt = .{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
        } };
        return stmt;
    }

    fn parseWhileStmt(self: *Parser) ParseError!*Stmt {
        self.advance(); // consume 'while'
        const condition = try self.parseExpression();

        try self.expect(.lbrace, "Expected '{' after while condition");
        const body = try self.parseStmtList();
        try self.expect(.rbrace, "Expected '}' after while body");

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .while_stmt = .{
            .condition = condition,
            .body = body,
        } };
        return stmt;
    }

    fn parseReturnStmt(self: *Parser) ParseError!*Stmt {
        self.advance(); // consume 'return'

        var value: ?*Expr = null;
        if (self.current.kind != .semicolon) {
            value = try self.parseExpression();
        }
        try self.expect(.semicolon, "Expected ';' after return");

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .return_stmt = .{ .value = value } };
        return stmt;
    }

    fn parsePrintStmt(self: *Parser) ParseError!*Stmt {
        self.advance(); // consume 'print'
        try self.expect(.lparen, "Expected '(' after print");
        const value = try self.parseExpression();
        try self.expect(.rparen, "Expected ')' after print argument");
        try self.expect(.semicolon, "Expected ';' after print statement");

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .print_stmt = value };
        return stmt;
    }

    fn parseBlock(self: *Parser) ParseError!*Stmt {
        self.advance(); // consume '{'
        const stmts = try self.parseStmtList();
        try self.expect(.rbrace, "Expected '}'");

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .block = stmts };
        return stmt;
    }

    fn parseStmtList(self: *Parser) ParseError![]const *Stmt {
        var stmts: std.ArrayList(*Stmt) = .empty;
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            try stmts.append(self.allocator, try self.parseStatement());
        }
        return try stmts.toOwnedSlice(self.allocator);
    }

    fn parseExprStmtOrAssignment(self: *Parser) ParseError!*Stmt {
        // Check for assignment: identifier = expr;
        if (self.current.kind == .identifier) {
            const name = self.current.lexeme;
            const saved = self.lexer.saveState();
            const saved_current = self.current;
            self.advance();
            if (self.current.kind == .assign) {
                self.advance(); // consume '='
                const value = try self.parseExpression();
                try self.expect(.semicolon, "Expected ';' after assignment");
                const stmt = try self.allocator.create(Stmt);
                stmt.* = .{ .assignment = .{ .name = name, .value = value } };
                return stmt;
            }
            // Not an assignment, restore and parse as expression
            self.lexer.restoreState(saved);
            self.current = saved_current;
        }

        const expr = try self.parseExpression();
        try self.expect(.semicolon, "Expected ';' after expression");

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .expr_stmt = expr };
        return stmt;
    }

    // Expression parsing with precedence climbing
    fn parseExpression(self: *Parser) ParseError!*Expr {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!*Expr {
        var left = try self.parseAnd();
        while (self.current.kind == .pipe_pipe) {
            const op = self.current.kind;
            self.advance();
            const right = try self.parseAnd();
            const expr = try self.allocator.create(Expr);
            expr.* = .{ .binary = .{ .left = left, .operator = op, .right = right } };
            left = expr;
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!*Expr {
        var left = try self.parseEquality();
        while (self.current.kind == .amp_amp) {
            const op = self.current.kind;
            self.advance();
            const right = try self.parseEquality();
            const expr = try self.allocator.create(Expr);
            expr.* = .{ .binary = .{ .left = left, .operator = op, .right = right } };
            left = expr;
        }
        return left;
    }

    fn parseEquality(self: *Parser) ParseError!*Expr {
        var left = try self.parseComparison();
        while (self.current.kind == .equal or self.current.kind == .not_equal) {
            const op = self.current.kind;
            self.advance();
            const right = try self.parseComparison();
            const expr = try self.allocator.create(Expr);
            expr.* = .{ .binary = .{ .left = left, .operator = op, .right = right } };
            left = expr;
        }
        return left;
    }

    fn parseComparison(self: *Parser) ParseError!*Expr {
        var left = try self.parseAddSub();
        while (self.current.kind == .less or self.current.kind == .greater or
            self.current.kind == .less_equal or self.current.kind == .greater_equal)
        {
            const op = self.current.kind;
            self.advance();
            const right = try self.parseAddSub();
            const expr = try self.allocator.create(Expr);
            expr.* = .{ .binary = .{ .left = left, .operator = op, .right = right } };
            left = expr;
        }
        return left;
    }

    fn parseAddSub(self: *Parser) ParseError!*Expr {
        var left = try self.parseMulDiv();
        while (self.current.kind == .plus or self.current.kind == .minus) {
            const op = self.current.kind;
            self.advance();
            const right = try self.parseMulDiv();
            const expr = try self.allocator.create(Expr);
            expr.* = .{ .binary = .{ .left = left, .operator = op, .right = right } };
            left = expr;
        }
        return left;
    }

    fn parseMulDiv(self: *Parser) ParseError!*Expr {
        var left = try self.parseUnary();
        while (self.current.kind == .star or self.current.kind == .slash or self.current.kind == .percent) {
            const op = self.current.kind;
            self.advance();
            const right = try self.parseUnary();
            const expr = try self.allocator.create(Expr);
            expr.* = .{ .binary = .{ .left = left, .operator = op, .right = right } };
            left = expr;
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*Expr {
        if (self.current.kind == .bang or self.current.kind == .minus) {
            const op = self.current.kind;
            self.advance();
            const operand = try self.parseUnary();
            const expr = try self.allocator.create(Expr);
            expr.* = .{ .unary = .{ .operator = op, .operand = operand } };
            return expr;
        }
        return self.parseCall();
    }

    fn parseCall(self: *Parser) ParseError!*Expr {
        if (self.current.kind == .identifier) {
            const name = self.current.lexeme;
            const saved = self.lexer.saveState();
            const saved_current = self.current;
            self.advance();
            if (self.current.kind == .lparen) {
                self.advance(); // consume '('
                var args: std.ArrayList(*Expr) = .empty;
                if (self.current.kind != .rparen) {
                    while (true) {
                        try args.append(self.allocator, try self.parseExpression());
                        if (self.current.kind != .comma) break;
                        self.advance();
                    }
                }
                try self.expect(.rparen, "Expected ')' after arguments");
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .call = .{
                    .callee = name,
                    .args = try args.toOwnedSlice(self.allocator),
                } };
                return expr;
            }
            // Not a call, restore
            self.lexer.restoreState(saved);
            self.current = saved_current;
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) ParseError!*Expr {
        switch (self.current.kind) {
            .integer => {
                const val = std.fmt.parseInt(i64, self.current.lexeme, 10) catch return self.reportError("Invalid integer");
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .integer_literal = val };
                self.advance();
                return expr;
            },
            .float => {
                const val = std.fmt.parseFloat(f64, self.current.lexeme) catch return self.reportError("Invalid float");
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .float_literal = val };
                self.advance();
                return expr;
            },
            .string => {
                const lexeme = self.current.lexeme;
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .string_literal = lexeme[1 .. lexeme.len - 1] };
                self.advance();
                return expr;
            },
            .kw_true => {
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .bool_literal = true };
                self.advance();
                return expr;
            },
            .kw_false => {
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .bool_literal = false };
                self.advance();
                return expr;
            },
            .kw_null => {
                const expr = try self.allocator.create(Expr);
                expr.* = .null_literal;
                self.advance();
                return expr;
            },
            .identifier => {
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .identifier = self.current.lexeme };
                self.advance();
                return expr;
            },
            .lparen => {
                self.advance();
                const inner = try self.parseExpression();
                try self.expect(.rparen, "Expected ')'");
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .grouping = inner };
                return expr;
            },
            else => return self.reportError("Unexpected token"),
        }
    }

    fn advance(self: *Parser) void {
        self.current = self.lexer.nextToken();
    }

    fn expect(self: *Parser, token_type: TokenType, msg: []const u8) ParseError!void {
        if (self.current.kind != token_type) {
            return self.reportError(msg);
        }
        self.advance();
    }

    fn reportError(self: *Parser, msg: []const u8) ParseError {
        if (!self.had_error) {
            self.had_error = true;
            self.error_msg = msg;
        }
        return error.ParseError;
    }
};

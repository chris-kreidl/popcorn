const std = @import("std");
const ast = @import("ast.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const ResolvedSlot = ast.ResolvedSlot;

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(Scope),
    max_slots_per_scope: u16,
    max_scope_depth: u16,
    const ResolveError = error{
        OutOfMemory,
        TooManyVariablesInScope,
        ScopeNestingTooDeep,
    };

    const Scope = struct {
        slots: std.StringHashMap(u16),
        next_slot: u16,
    };

    pub fn init(allocator: std.mem.Allocator) Resolver {
        return initWithLimits(allocator, std.math.maxInt(u16), std.math.maxInt(u16));
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, max_slots_per_scope: u16, max_scope_depth: u16) Resolver {
        return .{
            .allocator = allocator,
            .scopes = .empty,
            .max_slots_per_scope = max_slots_per_scope,
            .max_scope_depth = max_scope_depth,
        };
    }

    pub fn deinit(self: *Resolver) void {
        for (self.scopes.items) |*scope| {
            scope.slots.deinit();
        }
        self.scopes.deinit(self.allocator);
    }

    pub fn resolve(self: *Resolver, stmts: []*Stmt) ResolveError!void {
        try self.beginScope();
        defer _ = self.endScope();

        for (stmts) |stmt| {
            try self.resolveStmt(stmt);
        }
    }

    fn beginScope(self: *Resolver) ResolveError!void {
        if (self.scopes.items.len > self.max_scope_depth) {
            return error.ScopeNestingTooDeep;
        }

        const scope = Scope{
            .slots = std.StringHashMap(u16).init(self.allocator),
            .next_slot = 0,
        };
        try self.scopes.append(self.allocator, scope);
    }

    fn endScope(self: *Resolver) u16 {
        var scope = self.scopes.pop().?;
        const slot_count = scope.next_slot;
        scope.slots.deinit();
        return slot_count;
    }

    fn declareInCurrentScope(self: *Resolver, name: []const u8) ResolveError!?u16 {
        if (self.scopes.items.len == 0) {
            return null;
        }

        const scope = &self.scopes.items[self.scopes.items.len - 1];
        if (scope.slots.get(name)) |slot| {
            return slot;
        }

        if (scope.next_slot >= self.max_slots_per_scope) {
            return error.TooManyVariablesInScope;
        }

        const slot = scope.next_slot;
        scope.next_slot += 1;
        try scope.slots.put(name, slot);
        return slot;
    }

    fn resolveName(self: *Resolver, name: []const u8) ResolveError!?ResolvedSlot {
        var depth: usize = 0;
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            if (depth > self.max_scope_depth) {
                return error.ScopeNestingTooDeep;
            }

            i -= 1;
            const scope = &self.scopes.items[i];
            if (scope.slots.get(name)) |slot| {
                return .{ .depth = @intCast(depth), .slot = slot };
            }
            depth += 1;
        }
        return null;
    }

    fn resolveStmt(self: *Resolver, stmt: *Stmt) ResolveError!void {
        switch (stmt.*) {
            .expr_stmt => |expr| try self.resolveExpr(expr),
            .print_stmt => |expr| try self.resolveExpr(expr),
            .var_decl => |*decl| {
                try self.resolveExpr(decl.initializer);
                decl.resolved_slot = try self.declareInCurrentScope(decl.name);
            },
            .assignment => |*assign| {
                try self.resolveExpr(assign.value);
                assign.resolved = try self.resolveName(assign.name);
            },
            // Note: .block opens its own scope here, and if_stmt/while_stmt/fn_decl
            // also open scopes for their bodies. This works because those bodies are
            // raw []*Stmt, not wrapped in .block nodes. If that representation changes,
            // avoid double-scoping.
            .block => |stmts| {
                try self.beginScope();
                defer _ = self.endScope();
                for (stmts) |child| {
                    try self.resolveStmt(child);
                }
            },
            .if_stmt => |if_stmt| {
                try self.resolveExpr(if_stmt.condition);
                try self.beginScope();
                defer _ = self.endScope();
                for (if_stmt.then_branch) |child| {
                    try self.resolveStmt(child);
                }

                if (if_stmt.else_branch) |else_branch| {
                    try self.beginScope();
                    defer _ = self.endScope();
                    for (else_branch) |child| {
                        try self.resolveStmt(child);
                    }
                }
            },
            .while_stmt => |while_stmt| {
                try self.resolveExpr(while_stmt.condition);
                try self.beginScope();
                defer _ = self.endScope();
                for (while_stmt.body) |child| {
                    try self.resolveStmt(child);
                }
            },
            .fn_decl => |*fn_decl| try self.resolveFnDecl(fn_decl),
            .return_stmt => |ret| {
                if (ret.value) |value| {
                    try self.resolveExpr(value);
                }
            },
        }
    }

    fn resolveExpr(self: *Resolver, expr: *Expr) ResolveError!void {
        switch (expr.*) {
            .integer_literal,
            .float_literal,
            .string_literal,
            .bool_literal,
            .null_literal,
            => {},
            .identifier => |*identifier| {
                identifier.resolved = try self.resolveName(identifier.name);
            },
            .grouping => |inner| try self.resolveExpr(inner),
            .unary => |unary| try self.resolveExpr(unary.operand),
            .binary => |binary| {
                try self.resolveExpr(binary.left);
                try self.resolveExpr(binary.right);
            },
            .call => |*call| {
                call.callee_resolved = try self.resolveName(call.callee);
                for (call.args) |arg| {
                    try self.resolveExpr(arg);
                }
            },
        }
    }

    fn resolveFnDecl(self: *Resolver, fn_decl: *Stmt.FnDecl) ResolveError!void {
        fn_decl.resolved_slot = try self.declareInCurrentScope(fn_decl.name);

        try self.beginScope();
        var scope_popped = false;
        defer {
            if (!scope_popped) {
                _ = self.endScope();
            }
        }

        for (fn_decl.params) |*param| {
            param.resolved_slot = (try self.declareInCurrentScope(param.name)).?;
        }

        for (fn_decl.body) |child| {
            try self.resolveStmt(child);
        }

        fn_decl.local_slot_count = self.endScope();
        scope_popped = true;
    }
};

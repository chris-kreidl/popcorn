const std = @import("std");
const ast = @import("ast.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const ResolvedSlot = ast.ResolvedSlot;
const TokenType = @import("token.zig").TokenType;

pub const CompileError = error{ OutOfMemory, UnsupportedFeature };
pub const RuntimeError = error{
    RuntimeError,
    TypeError,
    UndefinedVariable,
    ConstAssignment,
    DivisionByZero,
    IntegerOverflow,
    ArityMismatch,
};

pub const VmError = CompileError || RuntimeError;

pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    null_val,
    function: *Function,

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .boolean => |v| v,
            .null_val => false,
            .int => |v| v != 0,
            .float => |v| v != 0.0,
            .string => |v| v.len > 0,
            .function => true,
        };
    }

    // Returns an allocator-owned string representation. Caller owns the memory
    // and must free it with the same allocator.
    pub fn toString(self: Value, allocator: std.mem.Allocator) []const u8 {
        return switch (self) {
            .int => |v| std.fmt.allocPrint(allocator, "{d}", .{v}) catch @panic("OOM"),
            .float => |v| std.fmt.allocPrint(allocator, "{d}", .{v}) catch @panic("OOM"),
            .string => |v| allocator.dupe(u8, v) catch @panic("OOM"),
            .boolean => |v| std.fmt.allocPrint(allocator, "{s}", .{if (v) "true" else "false"}) catch @panic("OOM"),
            .null_val => std.fmt.allocPrint(allocator, "null", .{}) catch @panic("OOM"),
            .function => |f| std.fmt.allocPrint(allocator, "<fn {s}>", .{f.name}) catch @panic("OOM"),
        };
    }
};

const OpCode = enum(u8) {
    push_const,
    dup,
    pop,

    load_global,
    define_global,
    set_global,

    load_local,
    define_local,
    set_local,
    load_frame_local,
    set_frame_local,
    enter_scope,
    exit_scope,

    add,
    sub,
    mul,
    div,
    mod,
    neg,
    not,
    truthy,
    equal,
    not_equal,
    less,
    greater,
    less_equal,
    greater_equal,

    jump_if_false,
    jump_if_true,
    jump,

    print,
    call,
    ret,
};

const ArithOp = enum { add, sub, mul, div, mod };

const Chunk = struct {
    code: std.ArrayList(u8),
    constants: std.ArrayList(Value),

    fn init() Chunk {
        return .{
            .code = .empty,
            .constants = .empty,
        };
    }

    fn addConst(self: *Chunk, allocator: std.mem.Allocator, value: Value) !u32 {
        const idx: u32 = @intCast(self.constants.items.len);
        try self.constants.append(allocator, value);
        return idx;
    }

    fn emitOp(self: *Chunk, allocator: std.mem.Allocator, op: OpCode) !void {
        try self.code.append(allocator, @intFromEnum(op));
    }

    fn emitU8(self: *Chunk, allocator: std.mem.Allocator, value: u8) !void {
        try self.code.append(allocator, value);
    }

    fn emitU16(self: *Chunk, allocator: std.mem.Allocator, value: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, value, .little);
        try self.code.appendSlice(allocator, &buf);
    }

    fn emitU32(self: *Chunk, allocator: std.mem.Allocator, value: u32) !u32 {
        const pos: u32 = @intCast(self.code.items.len);
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        try self.code.appendSlice(allocator, &buf);
        return pos;
    }

    fn emitPushConst(self: *Chunk, allocator: std.mem.Allocator, idx: u32) !void {
        try self.emitOp(allocator, .push_const);
        _ = try self.emitU32(allocator, idx);
    }

    fn emitJumpPlaceholder(self: *Chunk, allocator: std.mem.Allocator, op: OpCode) !u32 {
        try self.emitOp(allocator, op);
        return self.emitU32(allocator, 0);
    }

    fn patchU32At(self: *Chunk, pos: u32, value: u32) void {
        const start: usize = @intCast(pos);
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        @memcpy(self.code.items[start .. start + 4], &buf);
    }
};

pub const Function = struct {
    name: []const u8,
    arity: u16,
    local_slot_count: u16,
    param_slots: []u16,
    chunk: Chunk,
};

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    vm: *Vm,
    global_names: std.StringHashMap(void),
    function_global_refs: std.StringHashMap(void),
    in_script: bool,
    lexical_depth: usize,
    runtime_scope_stack: std.ArrayList(bool),

    pub fn init(allocator: std.mem.Allocator, vm: *Vm) Compiler {
        return .{
            .allocator = allocator,
            .vm = vm,
            .global_names = std.StringHashMap(void).init(allocator),
            .function_global_refs = std.StringHashMap(void).init(allocator),
            .in_script = false,
            .lexical_depth = 0,
            .runtime_scope_stack = .empty,
        };
    }

    pub fn compileProgram(self: *Compiler, stmts: []*Stmt) CompileError!*Function {
        for (stmts) |stmt| {
            switch (stmt.*) {
                .var_decl => |decl| try self.global_names.put(decl.name, {}),
                .fn_decl => |decl| try self.global_names.put(decl.name, {}),
                else => {},
            }
        }
        try self.collectFunctionGlobalRefs(stmts);

        const fn_obj = try self.allocator.create(Function);
        fn_obj.* = .{
            .name = "<script>",
            .arity = 0,
            .local_slot_count = Compiler.scopeSlotCount(stmts),
            .param_slots = &.{},
            .chunk = Chunk.init(),
        };

        self.in_script = true;
        self.lexical_depth = 0;
        try self.resetScopeTracking();
        for (stmts) |stmt| {
            try self.compileStmt(fn_obj, stmt);
        }

        const null_idx = try fn_obj.chunk.addConst(self.allocator, .null_val);
        try fn_obj.chunk.emitPushConst(self.allocator, null_idx);
        try fn_obj.chunk.emitOp(self.allocator, .ret);
        return fn_obj;
    }

    fn compileStmt(self: *Compiler, func: *Function, stmt: *Stmt) CompileError!void {
        switch (stmt.*) {
            .expr_stmt => |expr| {
                try self.compileExpr(func, expr);
                try func.chunk.emitOp(self.allocator, .pop);
            },
            .print_stmt => |expr| {
                try self.compileExpr(func, expr);
                try func.chunk.emitOp(self.allocator, .print);
            },
            .var_decl => |decl| {
                try self.compileExpr(func, decl.initializer);
                try self.emitDefineBinding(func, decl.name, decl.resolved_slot, decl.is_const);
            },
            .assignment => |assign| {
                try self.compileExpr(func, assign.value);
                try self.emitSetBinding(func, assign.name, assign.resolved);
            },
            .block => |stmts| {
                const slots = Compiler.scopeSlotCount(stmts);
                const materialized = slots != 0;
                if (materialized) {
                    try func.chunk.emitOp(self.allocator, .enter_scope);
                    try func.chunk.emitU16(self.allocator, slots);
                }
                try self.enterLexicalScope(materialized);
                errdefer self.exitLexicalScope();
                for (stmts) |s| try self.compileStmt(func, s);
                self.exitLexicalScope();
                if (materialized) {
                    try func.chunk.emitOp(self.allocator, .exit_scope);
                }
            },
            .if_stmt => |if_stmt| {
                try self.compileExpr(func, if_stmt.condition);
                const jfalse_pos = try func.chunk.emitJumpPlaceholder(self.allocator, .jump_if_false);
                try func.chunk.emitOp(self.allocator, .pop);

                const then_slots = Compiler.scopeSlotCount(if_stmt.then_branch);
                const then_materialized = then_slots != 0;
                if (then_materialized) {
                    try func.chunk.emitOp(self.allocator, .enter_scope);
                    try func.chunk.emitU16(self.allocator, then_slots);
                }
                try self.enterLexicalScope(then_materialized);
                errdefer self.exitLexicalScope();
                for (if_stmt.then_branch) |s| try self.compileStmt(func, s);
                self.exitLexicalScope();
                if (then_materialized) {
                    try func.chunk.emitOp(self.allocator, .exit_scope);
                }

                const jend_pos = try func.chunk.emitJumpPlaceholder(self.allocator, .jump);
                const else_target: u32 = @intCast(func.chunk.code.items.len);
                func.chunk.patchU32At(jfalse_pos, else_target);
                try func.chunk.emitOp(self.allocator, .pop);

                if (if_stmt.else_branch) |else_branch| {
                    const else_slots = Compiler.scopeSlotCount(else_branch);
                    const else_materialized = else_slots != 0;
                    if (else_materialized) {
                        try func.chunk.emitOp(self.allocator, .enter_scope);
                        try func.chunk.emitU16(self.allocator, else_slots);
                    }
                    try self.enterLexicalScope(else_materialized);
                    errdefer self.exitLexicalScope();
                    for (else_branch) |s| try self.compileStmt(func, s);
                    self.exitLexicalScope();
                    if (else_materialized) {
                        try func.chunk.emitOp(self.allocator, .exit_scope);
                    }
                }

                const end_target: u32 = @intCast(func.chunk.code.items.len);
                func.chunk.patchU32At(jend_pos, end_target);
            },
            .while_stmt => |while_stmt| {
                const loop_start: u32 = @intCast(func.chunk.code.items.len);
                try self.compileExpr(func, while_stmt.condition);
                const jexit_pos = try func.chunk.emitJumpPlaceholder(self.allocator, .jump_if_false);
                try func.chunk.emitOp(self.allocator, .pop);

                const body_slots = Compiler.scopeSlotCount(while_stmt.body);
                const body_materialized = body_slots != 0;
                if (body_materialized) {
                    try func.chunk.emitOp(self.allocator, .enter_scope);
                    try func.chunk.emitU16(self.allocator, body_slots);
                }
                try self.enterLexicalScope(body_materialized);
                errdefer self.exitLexicalScope();
                for (while_stmt.body) |s| try self.compileStmt(func, s);
                self.exitLexicalScope();
                if (body_materialized) {
                    try func.chunk.emitOp(self.allocator, .exit_scope);
                }

                try func.chunk.emitOp(self.allocator, .jump);
                _ = try func.chunk.emitU32(self.allocator, loop_start);

                const exit_target: u32 = @intCast(func.chunk.code.items.len);
                func.chunk.patchU32At(jexit_pos, exit_target);
                try func.chunk.emitOp(self.allocator, .pop);
            },
            .fn_decl => |fn_decl| {
                const fn_value = try self.compileFunction(fn_decl);
                const fn_idx = try func.chunk.addConst(self.allocator, .{ .function = fn_value });
                try func.chunk.emitPushConst(self.allocator, fn_idx);
                try self.emitDefineBinding(func, fn_decl.name, fn_decl.resolved_slot, true);
            },
            .return_stmt => |ret| {
                if (ret.value) |value_expr| {
                    try self.compileExpr(func, value_expr);
                } else {
                    const null_idx = try func.chunk.addConst(self.allocator, .null_val);
                    try func.chunk.emitPushConst(self.allocator, null_idx);
                }
                try func.chunk.emitOp(self.allocator, .ret);
            },
        }
    }

    fn compileFunction(self: *Compiler, fn_decl: Stmt.FnDecl) CompileError!*Function {
        const saved_in_script = self.in_script;
        const saved_depth = self.lexical_depth;
        const saved_runtime_scope_stack = self.runtime_scope_stack;
        self.runtime_scope_stack = .empty;
        defer {
            self.runtime_scope_stack.deinit(self.allocator);
            self.runtime_scope_stack = saved_runtime_scope_stack;
            self.in_script = saved_in_script;
            self.lexical_depth = saved_depth;
        }

        const fn_obj = try self.allocator.create(Function);
        const param_slots = try self.allocator.alloc(u16, fn_decl.params.len);
        for (fn_decl.params, 0..) |param, i| {
            const slot = param.resolved_slot orelse return error.UnsupportedFeature;
            param_slots[i] = slot;
        }

        fn_obj.* = .{
            .name = fn_decl.name,
            .arity = @intCast(fn_decl.params.len),
            .local_slot_count = fn_decl.local_slot_count,
            .param_slots = param_slots,
            .chunk = Chunk.init(),
        };

        self.in_script = false;
        self.lexical_depth = 0;
        try self.resetScopeTracking();
        for (fn_decl.body) |s| try self.compileStmt(fn_obj, s);

        const null_idx = try fn_obj.chunk.addConst(self.allocator, .null_val);
        try fn_obj.chunk.emitPushConst(self.allocator, null_idx);
        try fn_obj.chunk.emitOp(self.allocator, .ret);

        return fn_obj;
    }

    fn compileExpr(self: *Compiler, func: *Function, expr: *Expr) CompileError!void {
        switch (expr.*) {
            .integer_literal => |v| {
                const idx = try func.chunk.addConst(self.allocator, .{ .int = v });
                try func.chunk.emitPushConst(self.allocator, idx);
            },
            .float_literal => |v| {
                const idx = try func.chunk.addConst(self.allocator, .{ .float = v });
                try func.chunk.emitPushConst(self.allocator, idx);
            },
            .string_literal => |v| {
                const idx = try func.chunk.addConst(self.allocator, .{ .string = v });
                try func.chunk.emitPushConst(self.allocator, idx);
            },
            .bool_literal => |v| {
                const idx = try func.chunk.addConst(self.allocator, .{ .boolean = v });
                try func.chunk.emitPushConst(self.allocator, idx);
            },
            .null_literal => {
                const idx = try func.chunk.addConst(self.allocator, .null_val);
                try func.chunk.emitPushConst(self.allocator, idx);
            },
            .identifier => |id| try self.emitLoadBinding(func, id.name, id.resolved),
            .grouping => |inner| try self.compileExpr(func, inner),
            .unary => |u| {
                try self.compileExpr(func, u.operand);
                switch (u.operator) {
                    .minus => try func.chunk.emitOp(self.allocator, .neg),
                    .bang => try func.chunk.emitOp(self.allocator, .not),
                    else => return error.UnsupportedFeature,
                }
            },
            .binary => |b| {
                switch (b.operator) {
                    .amp_amp => {
                        try self.compileExpr(func, b.left);
                        const jfalse_pos = try func.chunk.emitJumpPlaceholder(self.allocator, .jump_if_false);
                        try func.chunk.emitOp(self.allocator, .pop);
                        try self.compileExpr(func, b.right);
                        const end: u32 = @intCast(func.chunk.code.items.len);
                        func.chunk.patchU32At(jfalse_pos, end);
                    },
                    .pipe_pipe => {
                        try self.compileExpr(func, b.left);
                        const jtrue_pos = try func.chunk.emitJumpPlaceholder(self.allocator, .jump_if_true);
                        try func.chunk.emitOp(self.allocator, .pop);
                        try self.compileExpr(func, b.right);
                        const end: u32 = @intCast(func.chunk.code.items.len);
                        func.chunk.patchU32At(jtrue_pos, end);
                    },
                    else => {
                        try self.compileExpr(func, b.left);
                        try self.compileExpr(func, b.right);
                        const op = switch (b.operator) {
                            .plus => OpCode.add,
                            .minus => OpCode.sub,
                            .star => OpCode.mul,
                            .slash => OpCode.div,
                            .percent => OpCode.mod,
                            .equal => OpCode.equal,
                            .not_equal => OpCode.not_equal,
                            .less => OpCode.less,
                            .greater => OpCode.greater,
                            .less_equal => OpCode.less_equal,
                            .greater_equal => OpCode.greater_equal,
                            else => return error.UnsupportedFeature,
                        };
                        try func.chunk.emitOp(self.allocator, op);
                    },
                }
            },
            .call => |c| {
                try self.emitLoadBinding(func, c.callee, c.callee_resolved);
                for (c.args) |arg| try self.compileExpr(func, arg);
                try func.chunk.emitOp(self.allocator, .call);
                try func.chunk.emitU16(self.allocator, @intCast(c.args.len));
            },
        }
    }

    fn emitLoadBinding(self: *Compiler, func: *Function, name: []const u8, resolved: ?ResolvedSlot) CompileError!void {
        switch (try self.classifyBinding(name, resolved)) {
            .local => |r| {
                const runtime_depth = try self.runtimeDepthForResolved(r);
                if (runtime_depth == 0) {
                    try func.chunk.emitOp(self.allocator, .load_frame_local);
                    try func.chunk.emitU16(self.allocator, r.slot);
                } else {
                    try func.chunk.emitOp(self.allocator, .load_local);
                    try func.chunk.emitU16(self.allocator, runtime_depth);
                    try func.chunk.emitU16(self.allocator, r.slot);
                }
            },
            .global => {
                const intern_id = try self.vm.internName(name);
                try func.chunk.emitOp(self.allocator, .load_global);
                _ = try func.chunk.emitU32(self.allocator, intern_id);
            },
        }
    }

    fn emitDefineBinding(self: *Compiler, func: *Function, name: []const u8, resolved_slot: ?u16, is_const: bool) CompileError!void {
        if (resolved_slot) |slot| {
            const should_export_global = self.in_script and
                self.lexical_depth == 0 and
                self.function_global_refs.contains(name);
            if (should_export_global) {
                // Keep script-level vars/functions fast as slots, but also publish
                // them to globals for function bodies (no closures yet).
                try func.chunk.emitOp(self.allocator, .dup);
            }
            try func.chunk.emitOp(self.allocator, .define_local);
            try func.chunk.emitU16(self.allocator, slot);
            try func.chunk.emitU8(self.allocator, if (is_const) 1 else 0);

            if (should_export_global) {
                const intern_id = try self.vm.internName(name);
                try func.chunk.emitOp(self.allocator, .define_global);
                _ = try func.chunk.emitU32(self.allocator, intern_id);
                try func.chunk.emitU8(self.allocator, if (is_const) 1 else 0);
            }
        } else {
            const intern_id = try self.vm.internName(name);
            try func.chunk.emitOp(self.allocator, .define_global);
            _ = try func.chunk.emitU32(self.allocator, intern_id);
            try func.chunk.emitU8(self.allocator, if (is_const) 1 else 0);
        }
    }

    fn emitSetBinding(self: *Compiler, func: *Function, name: []const u8, resolved: ?ResolvedSlot) CompileError!void {
        switch (try self.classifyBinding(name, resolved)) {
            .local => |r| {
                const current_depth: u16 = @intCast(self.lexical_depth);
                const should_export_global = self.in_script and
                    r.depth == current_depth and
                    self.function_global_refs.contains(name);
                if (should_export_global) {
                    try func.chunk.emitOp(self.allocator, .dup);
                }
                const runtime_depth = try self.runtimeDepthForResolved(r);
                if (runtime_depth == 0) {
                    try func.chunk.emitOp(self.allocator, .set_frame_local);
                    try func.chunk.emitU16(self.allocator, r.slot);
                } else {
                    try func.chunk.emitOp(self.allocator, .set_local);
                    try func.chunk.emitU16(self.allocator, runtime_depth);
                    try func.chunk.emitU16(self.allocator, r.slot);
                }
                if (should_export_global) {
                    const intern_id = try self.vm.internName(name);
                    try func.chunk.emitOp(self.allocator, .set_global);
                    _ = try func.chunk.emitU32(self.allocator, intern_id);
                }
            },
            .global => {
                const intern_id = try self.vm.internName(name);
                try func.chunk.emitOp(self.allocator, .set_global);
                _ = try func.chunk.emitU32(self.allocator, intern_id);
            },
        }
    }

    const Binding = union(enum) {
        local: ResolvedSlot,
        global,
    };

    fn classifyBinding(self: *Compiler, name: []const u8, resolved: ?ResolvedSlot) CompileError!Binding {
        if (resolved) |r| {
            const current_depth: u16 = @intCast(self.lexical_depth);
            if (self.in_script) {
                if (r.depth <= current_depth) return .{ .local = r };
                return error.UnsupportedFeature;
            }

            if (r.depth <= current_depth) return .{ .local = r };
            if (r.depth == current_depth + 1 and self.global_names.contains(name)) return .global;
            return error.UnsupportedFeature;
        }
        return .global;
    }

    fn scopeSlotCount(stmts: []*Stmt) u16 {
        var max_slot: i32 = -1;
        for (stmts) |stmt| {
            switch (stmt.*) {
                .var_decl => |decl| {
                    if (decl.resolved_slot) |slot| {
                        if (@as(i32, slot) > max_slot) max_slot = slot;
                    }
                },
                .fn_decl => |decl| {
                    if (decl.resolved_slot) |slot| {
                        if (@as(i32, slot) > max_slot) max_slot = slot;
                    }
                },
                else => {},
            }
        }
        if (max_slot < 0) return 0;
        return @intCast(max_slot + 1);
    }

    fn resetScopeTracking(self: *Compiler) CompileError!void {
        self.runtime_scope_stack.clearRetainingCapacity();
        try self.runtime_scope_stack.append(self.allocator, true);
    }

    fn enterLexicalScope(self: *Compiler, materialized: bool) CompileError!void {
        self.lexical_depth += 1;
        try self.runtime_scope_stack.append(self.allocator, materialized);
    }

    fn exitLexicalScope(self: *Compiler) void {
        self.lexical_depth -= 1;
        _ = self.runtime_scope_stack.pop();
    }

    fn runtimeDepthForResolved(self: *Compiler, resolved: ResolvedSlot) CompileError!u16 {
        const current_depth: u16 = @intCast(self.lexical_depth);
        if (resolved.depth > current_depth) return error.UnsupportedFeature;

        const target_depth = current_depth - resolved.depth;
        var runtime_depth: usize = 0;
        var lexical_depth = current_depth;
        while (lexical_depth > target_depth) : (lexical_depth -= 1) {
            const idx: usize = @intCast(lexical_depth);
            if (idx >= self.runtime_scope_stack.items.len) return error.UnsupportedFeature;
            if (self.runtime_scope_stack.items[idx]) {
                runtime_depth += 1;
            }
        }
        if (runtime_depth > std.math.maxInt(u16)) return error.UnsupportedFeature;
        return @intCast(runtime_depth);
    }

    fn isFunctionGlobalRef(self: *Compiler, function_depth: u16, resolved: ResolvedSlot, name: []const u8) bool {
        return resolved.depth == function_depth + 1 and self.global_names.contains(name);
    }

    fn collectFunctionGlobalRefs(self: *Compiler, stmts: []*Stmt) CompileError!void {
        for (stmts) |stmt| {
            try self.collectGlobalRefsInStmt(stmt, false, 0);
        }
    }

    fn collectGlobalRefsInStmt(self: *Compiler, stmt: *Stmt, in_function: bool, function_depth: u16) CompileError!void {
        switch (stmt.*) {
            .expr_stmt => |expr| try self.collectGlobalRefsInExpr(expr, in_function, function_depth),
            .print_stmt => |expr| try self.collectGlobalRefsInExpr(expr, in_function, function_depth),
            .var_decl => |decl| try self.collectGlobalRefsInExpr(decl.initializer, in_function, function_depth),
            .assignment => |assign| {
                try self.collectGlobalRefsInExpr(assign.value, in_function, function_depth);
                if (in_function) {
                    if (assign.resolved) |resolved| {
                        if (self.isFunctionGlobalRef(function_depth, resolved, assign.name)) {
                            try self.function_global_refs.put(assign.name, {});
                        }
                    }
                }
            },
            .block => |stmts| {
                for (stmts) |child| {
                    try self.collectGlobalRefsInStmt(child, in_function, function_depth + 1);
                }
            },
            .if_stmt => |if_stmt| {
                try self.collectGlobalRefsInExpr(if_stmt.condition, in_function, function_depth);
                for (if_stmt.then_branch) |child| {
                    try self.collectGlobalRefsInStmt(child, in_function, function_depth + 1);
                }
                if (if_stmt.else_branch) |else_branch| {
                    for (else_branch) |child| {
                        try self.collectGlobalRefsInStmt(child, in_function, function_depth + 1);
                    }
                }
            },
            .while_stmt => |while_stmt| {
                try self.collectGlobalRefsInExpr(while_stmt.condition, in_function, function_depth);
                for (while_stmt.body) |child| {
                    try self.collectGlobalRefsInStmt(child, in_function, function_depth + 1);
                }
            },
            .fn_decl => |fn_decl| {
                for (fn_decl.body) |child| {
                    try self.collectGlobalRefsInStmt(child, true, 0);
                }
            },
            .return_stmt => |ret| {
                if (ret.value) |value| {
                    try self.collectGlobalRefsInExpr(value, in_function, function_depth);
                }
            },
        }
    }

    fn collectGlobalRefsInExpr(self: *Compiler, expr: *Expr, in_function: bool, function_depth: u16) CompileError!void {
        switch (expr.*) {
            .integer_literal,
            .float_literal,
            .string_literal,
            .bool_literal,
            .null_literal,
            => {},
            .identifier => |identifier| {
                if (in_function) {
                    if (identifier.resolved) |resolved| {
                        if (self.isFunctionGlobalRef(function_depth, resolved, identifier.name)) {
                            try self.function_global_refs.put(identifier.name, {});
                        }
                    }
                }
            },
            .grouping => |inner| try self.collectGlobalRefsInExpr(inner, in_function, function_depth),
            .unary => |unary| try self.collectGlobalRefsInExpr(unary.operand, in_function, function_depth),
            .binary => |binary| {
                try self.collectGlobalRefsInExpr(binary.left, in_function, function_depth);
                try self.collectGlobalRefsInExpr(binary.right, in_function, function_depth);
            },
            .call => |call| {
                if (in_function) {
                    if (call.callee_resolved) |resolved| {
                        if (self.isFunctionGlobalRef(function_depth, resolved, call.callee)) {
                            try self.function_global_refs.put(call.callee, {});
                        }
                    }
                }
                for (call.args) |arg| {
                    try self.collectGlobalRefsInExpr(arg, in_function, function_depth);
                }
            },
        }
    }
};

const GlobalEntry = struct {
    value: Value,
    is_const: bool,
};

const ScopeState = struct {
    base: usize,
    len: usize,
};

const Frame = struct {
    func: *Function,
    ip: usize,
    stack_base: usize,
    scope_base: usize,
    locals_base: usize,
};

const LocalSlot = struct {
    value: Value,
    is_set: bool,
    is_const: bool,
};

pub const Vm = struct {
    allocator: std.mem.Allocator,
    globals: std.AutoHashMap(u32, GlobalEntry),
    intern_map: std.StringHashMap(u32),
    intern_strings: std.ArrayList([]const u8),
    stack: std.ArrayList(Value),
    frames: std.ArrayList(Frame),
    scope_stack: std.ArrayList(ScopeState),
    locals: std.ArrayList(LocalSlot),
    output: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Vm {
        return .{
            .allocator = allocator,
            .globals = std.AutoHashMap(u32, GlobalEntry).init(allocator),
            .intern_map = std.StringHashMap(u32).init(allocator),
            .intern_strings = .empty,
            .stack = .empty,
            .frames = .empty,
            .scope_stack = .empty,
            .locals = .empty,
            .output = .empty,
        };
    }

    fn internName(self: *Vm, name: []const u8) error{OutOfMemory}!u32 {
        if (self.intern_map.get(name)) |id| return id;
        const id: u32 = @intCast(self.intern_strings.items.len);
        try self.intern_strings.append(self.allocator, name);
        try self.intern_map.put(name, id);
        return id;
    }

    pub fn hasGlobal(self: *const Vm, name: []const u8) bool {
        const id = self.intern_map.get(name) orelse return false;
        return self.globals.contains(id);
    }

    pub fn runProgram(self: *Vm, stmts: []*Stmt) VmError!?Value {
        var compiler = Compiler.init(self.allocator, self);
        const script = compiler.compileProgram(stmts) catch |err| return err;

        try self.pushFrame(script, 0);
        return self.execute();
    }

    fn pushFrame(self: *Vm, func: *Function, stack_base: usize) RuntimeError!void {
        const scope_base = self.scope_stack.items.len;
        const locals_base = self.locals.items.len;
        self.frames.append(self.allocator, .{
            .func = func,
            .ip = 0,
            .stack_base = stack_base,
            .scope_base = scope_base,
            .locals_base = locals_base,
        }) catch return error.RuntimeError;

        try self.pushScope(func.local_slot_count);
    }

    fn pop(self: *Vm) RuntimeError!Value {
        if (self.stack.items.len == 0) return error.RuntimeError;
        const val = self.stack.items[self.stack.items.len - 1];
        self.stack.items.len -= 1;
        return val;
    }

    fn push(self: *Vm, v: Value) RuntimeError!void {
        self.stack.append(self.allocator, v) catch return error.RuntimeError;
    }

    fn frame(self: *Vm) *Frame {
        return &self.frames.items[self.frames.items.len - 1];
    }

    fn pushScope(self: *Vm, slot_count_u16: u16) RuntimeError!void {
        const slot_count: usize = @intCast(slot_count_u16);
        const base = self.locals.items.len;

        if (slot_count != 0) {
            self.locals.resize(self.allocator, base + slot_count) catch return error.RuntimeError;
            @memset(self.locals.items[base..base + slot_count], LocalSlot{ .value = .null_val, .is_set = false, .is_const = false });
        }

        self.scope_stack.append(self.allocator, .{ .base = base, .len = slot_count }) catch return error.RuntimeError;
    }

    fn popScope(self: *Vm, fr: *Frame) RuntimeError!void {
        if (self.scope_stack.items.len == fr.scope_base) return error.RuntimeError;
        const scope = self.scope_stack.pop().?;
        if (scope.len != 0) {
            self.locals.shrinkRetainingCapacity(scope.base);
        }
    }

    fn currentScope(self: *Vm, fr: *Frame) RuntimeError!ScopeState {
        if (self.scope_stack.items.len == fr.scope_base) return error.RuntimeError;
        return self.scope_stack.items[self.scope_stack.items.len - 1];
    }

    fn scopeAtDepth(self: *Vm, fr: *Frame, depth: u16) RuntimeError!ScopeState {
        const d: usize = @intCast(depth);
        if (self.scope_stack.items.len <= fr.scope_base) return error.RuntimeError;
        const scope_count = self.scope_stack.items.len - fr.scope_base;
        if (d >= scope_count) return error.RuntimeError;
        const idx = self.scope_stack.items.len - 1 - d;
        return self.scope_stack.items[idx];
    }

    fn constAt(fr: *Frame, idx: u32) RuntimeError!Value {
        const i: usize = @intCast(idx);
        if (i >= fr.func.chunk.constants.items.len) return error.RuntimeError;
        return fr.func.chunk.constants.items[i];
    }

    fn readU8(self: *Vm, fr: *Frame) RuntimeError!u8 {
        _ = self;
        if (fr.ip >= fr.func.chunk.code.items.len) return error.RuntimeError;
        const b = fr.func.chunk.code.items[fr.ip];
        fr.ip += 1;
        return b;
    }

    fn readU16(self: *Vm, fr: *Frame) RuntimeError!u16 {
        _ = self;
        if (fr.ip + 2 > fr.func.chunk.code.items.len) return error.RuntimeError;
        var buf: [2]u8 = undefined;
        @memcpy(&buf, fr.func.chunk.code.items[fr.ip .. fr.ip + 2]);
        const v = std.mem.readInt(u16, &buf, .little);
        fr.ip += 2;
        return v;
    }

    fn readU32(self: *Vm, fr: *Frame) RuntimeError!u32 {
        _ = self;
        if (fr.ip + 4 > fr.func.chunk.code.items.len) return error.RuntimeError;
        var buf: [4]u8 = undefined;
        @memcpy(&buf, fr.func.chunk.code.items[fr.ip .. fr.ip + 4]);
        const v = std.mem.readInt(u32, &buf, .little);
        fr.ip += 4;
        return v;
    }

    fn execute(self: *Vm) RuntimeError!?Value {
        self.stack.ensureTotalCapacity(self.allocator, 1024) catch return error.RuntimeError;

        while (self.frames.items.len > 0) {
            var fr = self.frame();
            const op_byte = try self.readU8(fr);
            const op: OpCode = @enumFromInt(op_byte);

            switch (op) {
                .push_const => {
                    const idx = try self.readU32(fr);
                    try self.push(try constAt(fr, idx));
                },
                .dup => {
                    if (self.stack.items.len == 0) return error.RuntimeError;
                    const v = self.stack.items[self.stack.items.len - 1];
                    try self.push(v);
                },
                .pop => _ = try self.pop(),

                .load_global => {
                    const intern_id = try self.readU32(fr);
                    const entry = self.globals.get(intern_id) orelse return error.UndefinedVariable;
                    try self.push(entry.value);
                },
                .define_global => {
                    const intern_id = try self.readU32(fr);
                    const is_const = (try self.readU8(fr)) != 0;
                    const v = try self.pop();
                    self.globals.put(intern_id, .{ .value = v, .is_const = is_const }) catch return error.RuntimeError;
                },
                .set_global => {
                    const intern_id = try self.readU32(fr);
                    const v = try self.pop();
                    const entry = self.globals.getPtr(intern_id) orelse return error.UndefinedVariable;
                    if (entry.is_const) return error.ConstAssignment;
                    entry.value = v;
                },

                .enter_scope => {
                    const slots = try self.readU16(fr);
                    try self.pushScope(slots);
                },
                .exit_scope => try self.popScope(fr),

                .load_local => {
                    const depth = try self.readU16(fr);
                    const slot = try self.readU16(fr);
                    const scope = try self.scopeAtDepth(fr, depth);
                    const i: usize = @intCast(slot);
                    if (i >= scope.len) return error.UndefinedVariable;
                    const idx = scope.base + i;
                    const local = self.locals.items[idx];
                    if (!local.is_set) return error.UndefinedVariable;
                    try self.push(local.value);
                },
                .define_local => {
                    const slot = try self.readU16(fr);
                    const is_const = (try self.readU8(fr)) != 0;
                    const scope = try self.currentScope(fr);
                    const i: usize = @intCast(slot);
                    if (i >= scope.len) return error.RuntimeError;
                    const v = try self.pop();
                    const idx = scope.base + i;
                    self.locals.items[idx] = .{ .value = v, .is_set = true, .is_const = is_const };
                },
                .set_local => {
                    const depth = try self.readU16(fr);
                    const slot = try self.readU16(fr);
                    const scope = try self.scopeAtDepth(fr, depth);
                    const i: usize = @intCast(slot);
                    if (i >= scope.len) return error.UndefinedVariable;
                    const idx = scope.base + i;
                    const local = &self.locals.items[idx];
                    if (!local.is_set) return error.UndefinedVariable;
                    if (local.is_const) return error.ConstAssignment;
                    const v = try self.pop();
                    local.value = v;
                },
                .load_frame_local => {
                    const slot = try self.readU16(fr);
                    const idx = fr.locals_base + @as(usize, slot);
                    if (idx >= self.locals.items.len) return error.UndefinedVariable;
                    try self.push(self.locals.items[idx].value);
                },
                .set_frame_local => {
                    const slot = try self.readU16(fr);
                    const idx = fr.locals_base + @as(usize, slot);
                    if (idx >= self.locals.items.len) return error.UndefinedVariable;
                    const local = &self.locals.items[idx];
                    if (!local.is_set) return error.UndefinedVariable;
                    if (local.is_const) return error.ConstAssignment;
                    const v = try self.pop();
                    local.value = v;
                },

                .add => {
                    const len = self.stack.items.len;
                    if (len >= 2) {
                        const l = self.stack.items[len - 2];
                        const r = self.stack.items[len - 1];
                        if (l == .int and r == .int) {
                            const ov = @addWithOverflow(l.int, r.int);
                            if (ov[1] != 0) return error.IntegerOverflow;
                            self.stack.items[len - 2] = .{ .int = ov[0] };
                            self.stack.items.len = len - 1;
                            continue;
                        }
                    }
                    try self.binArithAdd();
                },
                .sub => {
                    const len = self.stack.items.len;
                    if (len >= 2) {
                        const l = self.stack.items[len - 2];
                        const r = self.stack.items[len - 1];
                        if (l == .int and r == .int) {
                            const ov = @subWithOverflow(l.int, r.int);
                            if (ov[1] != 0) return error.IntegerOverflow;
                            self.stack.items[len - 2] = .{ .int = ov[0] };
                            self.stack.items.len = len - 1;
                            continue;
                        }
                    }
                    try self.binArith(.sub);
                },
                .mul => {
                    const len = self.stack.items.len;
                    if (len >= 2) {
                        const l = self.stack.items[len - 2];
                        const r = self.stack.items[len - 1];
                        if (l == .int and r == .int) {
                            const ov = @mulWithOverflow(l.int, r.int);
                            if (ov[1] != 0) return error.IntegerOverflow;
                            self.stack.items[len - 2] = .{ .int = ov[0] };
                            self.stack.items.len = len - 1;
                            continue;
                        }
                    }
                    try self.binArith(.mul);
                },
                .div => {
                    const len = self.stack.items.len;
                    if (len >= 2) {
                        const l = self.stack.items[len - 2];
                        const r = self.stack.items[len - 1];
                        if (l == .int and r == .int) {
                            if (r.int == 0) return error.DivisionByZero;
                            if (l.int == std.math.minInt(i64) and r.int == -1) return error.IntegerOverflow;
                            self.stack.items[len - 2] = .{ .int = @divTrunc(l.int, r.int) };
                            self.stack.items.len = len - 1;
                            continue;
                        }
                    }
                    try self.binArith(.div);
                },
                .mod => {
                    const len = self.stack.items.len;
                    if (len >= 2) {
                        const l = self.stack.items[len - 2];
                        const r = self.stack.items[len - 1];
                        if (l == .int and r == .int) {
                            if (r.int == 0) return error.DivisionByZero;
                            self.stack.items[len - 2] = .{ .int = @mod(l.int, r.int) };
                            self.stack.items.len = len - 1;
                            continue;
                        }
                    }
                    try self.binArith(.mod);
                },
                .neg => {
                    if (self.stack.items.len == 0) return error.RuntimeError;
                    const v = &self.stack.items[self.stack.items.len - 1];
                    switch (v.*) {
                        .int => |iv| v.* = .{ .int = std.math.negate(iv) catch return error.IntegerOverflow },
                        .float => |fv| v.* = .{ .float = -fv },
                        else => return error.TypeError,
                    }
                },
                .not => {
                    if (self.stack.items.len == 0) return error.RuntimeError;
                    const v = &self.stack.items[self.stack.items.len - 1];
                    v.* = .{ .boolean = !v.isTruthy() };
                },
                .truthy => {
                    if (self.stack.items.len == 0) return error.RuntimeError;
                    const v = &self.stack.items[self.stack.items.len - 1];
                    v.* = .{ .boolean = v.isTruthy() };
                },
                .equal => {
                    const len = self.stack.items.len;
                    if (len >= 2) {
                        const l = self.stack.items[len - 2];
                        const r = self.stack.items[len - 1];
                        if (l == .int and r == .int) {
                            self.stack.items[len - 2] = .{ .boolean = l.int == r.int };
                            self.stack.items.len = len - 1;
                            continue;
                        }
                    }
                    try self.binCompare(.eq);
                },
                .not_equal => {
                    const len = self.stack.items.len;
                    if (len >= 2) {
                        const l = self.stack.items[len - 2];
                        const r = self.stack.items[len - 1];
                        if (l == .int and r == .int) {
                            self.stack.items[len - 2] = .{ .boolean = l.int != r.int };
                            self.stack.items.len = len - 1;
                            continue;
                        }
                    }
                    try self.binCompare(.neq);
                },
                .less => {
                    const len = self.stack.items.len;
                    if (len >= 2) {
                        const l = self.stack.items[len - 2];
                        const r = self.stack.items[len - 1];
                        if (l == .int and r == .int) {
                            self.stack.items[len - 2] = .{ .boolean = l.int < r.int };
                            self.stack.items.len = len - 1;
                            continue;
                        }
                    }
                    try self.binCompare(.lt);
                },
                .greater => {
                    const len = self.stack.items.len;
                    if (len >= 2) {
                        const l = self.stack.items[len - 2];
                        const r = self.stack.items[len - 1];
                        if (l == .int and r == .int) {
                            self.stack.items[len - 2] = .{ .boolean = l.int > r.int };
                            self.stack.items.len = len - 1;
                            continue;
                        }
                    }
                    try self.binCompare(.gt);
                },
                .less_equal => {
                    const len = self.stack.items.len;
                    if (len >= 2) {
                        const l = self.stack.items[len - 2];
                        const r = self.stack.items[len - 1];
                        if (l == .int and r == .int) {
                            self.stack.items[len - 2] = .{ .boolean = l.int <= r.int };
                            self.stack.items.len = len - 1;
                            continue;
                        }
                    }
                    try self.binCompare(.le);
                },
                .greater_equal => {
                    const len = self.stack.items.len;
                    if (len >= 2) {
                        const l = self.stack.items[len - 2];
                        const r = self.stack.items[len - 1];
                        if (l == .int and r == .int) {
                            self.stack.items[len - 2] = .{ .boolean = l.int >= r.int };
                            self.stack.items.len = len - 1;
                            continue;
                        }
                    }
                    try self.binCompare(.ge);
                },

                .jump_if_false => {
                    const target = try self.readU32(fr);
                    const cond = self.stack.items[self.stack.items.len - 1];
                    if (!cond.isTruthy()) fr.ip = @intCast(target);
                },
                .jump_if_true => {
                    const target = try self.readU32(fr);
                    const cond = self.stack.items[self.stack.items.len - 1];
                    if (cond.isTruthy()) fr.ip = @intCast(target);
                },
                .jump => {
                    const target = try self.readU32(fr);
                    fr.ip = @intCast(target);
                },

                .print => {
                    const v = try self.pop();
                    const s = v.toString(self.allocator);
                    defer self.allocator.free(s);
                    self.output.appendSlice(self.allocator, s) catch return error.RuntimeError;
                    self.output.append(self.allocator, '\n') catch return error.RuntimeError;
                },
                .call => {
                    const argc_u16 = try self.readU16(fr);
                    const argc: usize = @intCast(argc_u16);
                    if (self.stack.items.len < argc + 1) return error.RuntimeError;
                    const callee_idx = self.stack.items.len - argc - 1;
                    const callee = self.stack.items[callee_idx];
                    const fn_obj = switch (callee) {
                        .function => |f| f,
                        else => return error.TypeError,
                    };
                    if (argc != fn_obj.arity) return error.ArityMismatch;

                    // Ensure stack capacity for the called function's expressions
                    self.stack.ensureUnusedCapacity(self.allocator, 256) catch return error.RuntimeError;
                    try self.pushFrame(fn_obj, callee_idx);
                    const new_fr = self.frame();
                    const locals_base = new_fr.locals_base;
                    for (fn_obj.param_slots, 0..) |slot, i| {
                        const idx = locals_base + @as(usize, slot);
                        self.locals.items[idx] = .{ .value = self.stack.items[callee_idx + 1 + i], .is_set = true, .is_const = false };
                    }
                },
                .ret => {
                    if (self.stack.items.len == 0) return error.RuntimeError;
                    const ret_val = self.stack.items[self.stack.items.len - 1];
                    const finished = self.frames.pop().?;
                    self.scope_stack.items.len = finished.scope_base;
                    self.locals.items.len = finished.locals_base;
                    if (self.frames.items.len == 0) {
                        return ret_val;
                    }
                    self.stack.items[finished.stack_base] = ret_val;
                    self.stack.items.len = finished.stack_base + 1;
                },
            }
        }

        return null;
    }

    fn binArithAdd(self: *Vm) RuntimeError!void {
        const right = try self.pop();
        const left = try self.pop();

        if (left == .string and right == .string) {
            const out = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ left.string, right.string }) catch return error.RuntimeError;
            try self.push(.{ .string = out });
            return;
        }

        try self.binArithWithVals(left, right, .add);
    }

    fn binArith(self: *Vm, op: ArithOp) RuntimeError!void {
        const right = try self.pop();
        const left = try self.pop();
        try self.binArithWithVals(left, right, op);
    }

    fn binArithWithVals(self: *Vm, left: Value, right: Value, op: ArithOp) RuntimeError!void {
        switch (left) {
            .int => |lv| switch (right) {
                .int => |rv| {
                    const out = switch (op) {
                        .add => blk: {
                            const r = @addWithOverflow(lv, rv);
                            if (r[1] != 0) return error.IntegerOverflow;
                            break :blk Value{ .int = r[0] };
                        },
                        .sub => blk: {
                            const r = @subWithOverflow(lv, rv);
                            if (r[1] != 0) return error.IntegerOverflow;
                            break :blk Value{ .int = r[0] };
                        },
                        .mul => blk: {
                            const r = @mulWithOverflow(lv, rv);
                            if (r[1] != 0) return error.IntegerOverflow;
                            break :blk Value{ .int = r[0] };
                        },
                        .div => blk: {
                            if (rv == 0) return error.DivisionByZero;
                            if (lv == std.math.minInt(i64) and rv == -1) return error.IntegerOverflow;
                            break :blk Value{ .int = @divTrunc(lv, rv) };
                        },
                        .mod => blk: {
                            if (rv == 0) return error.DivisionByZero;
                            break :blk Value{ .int = @mod(lv, rv) };
                        },
                    };
                    try self.push(out);
                },
                else => return error.TypeError,
            },
            .float => |lv| switch (right) {
                .float => |rv| {
                    const out = switch (op) {
                        .add => Value{ .float = lv + rv },
                        .sub => Value{ .float = lv - rv },
                        .mul => Value{ .float = lv * rv },
                        .div => blk: {
                            if (rv == 0.0) return error.DivisionByZero;
                            break :blk Value{ .float = lv / rv };
                        },
                        .mod => blk: {
                            if (rv == 0.0) return error.DivisionByZero;
                            break :blk Value{ .float = @mod(lv, rv) };
                        },
                    };
                    try self.push(out);
                },
                else => return error.TypeError,
            },
            else => return error.TypeError,
        }
    }

    fn binCompare(self: *Vm, op: enum { eq, neq, lt, gt, le, ge }) RuntimeError!void {
        const right = try self.pop();
        const left = try self.pop();

        if (op == .eq or op == .neq) {
            const eq = valuesEqual(left, right);
            try self.push(.{ .boolean = if (op == .eq) eq else !eq });
            return;
        }

        switch (left) {
            .int => |lv| switch (right) {
                .int => |rv| {
                    const b = switch (op) {
                        .lt => lv < rv,
                        .gt => lv > rv,
                        .le => lv <= rv,
                        .ge => lv >= rv,
                        else => unreachable,
                    };
                    try self.push(.{ .boolean = b });
                },
                else => return error.TypeError,
            },
            .float => |lv| switch (right) {
                .float => |rv| {
                    const b = switch (op) {
                        .lt => lv < rv,
                        .gt => lv > rv,
                        .le => lv <= rv,
                        .ge => lv >= rv,
                        else => unreachable,
                    };
                    try self.push(.{ .boolean = b });
                },
                else => return error.TypeError,
            },
            else => return error.TypeError,
        }
    }

    fn valuesEqual(a: Value, b: Value) bool {
        return switch (a) {
            .int => |av| switch (b) {
                .int => |bv| av == bv,
                else => false,
            },
            .float => |av| switch (b) {
                .float => |bv| av == bv,
                else => false,
            },
            .string => |av| switch (b) {
                .string => |bv| std.mem.eql(u8, av, bv),
                else => false,
            },
            .boolean => |av| switch (b) {
                .boolean => |bv| av == bv,
                else => false,
            },
            .null_val => switch (b) {
                .null_val => true,
                else => false,
            },
            .function => false,
        };
    }
};

test "vm: pop on empty stack returns runtime error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var vm = Vm.init(allocator);
    try std.testing.expectError(error.RuntimeError, vm.pop());
}

test "vm: load_frame_local out-of-bounds returns undefined variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var vm = Vm.init(allocator);

    const func = try allocator.create(Function);
    func.* = .{
        .name = "<test>",
        .arity = 0,
        .local_slot_count = 0,
        .param_slots = &.{},
        .chunk = Chunk.init(),
    };
    try func.chunk.emitOp(allocator, .load_frame_local);
    try func.chunk.emitU16(allocator, 1);
    try func.chunk.emitOp(allocator, .ret);

    try vm.pushFrame(func, 0);
    try std.testing.expectError(error.UndefinedVariable, vm.execute());
}

test "vm: set_frame_local respects const assignment checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var vm = Vm.init(allocator);

    const func = try allocator.create(Function);
    func.* = .{
        .name = "<test>",
        .arity = 0,
        .local_slot_count = 1,
        .param_slots = &.{},
        .chunk = Chunk.init(),
    };

    const one_idx = try func.chunk.addConst(allocator, .{ .int = 1 });
    const two_idx = try func.chunk.addConst(allocator, .{ .int = 2 });

    try func.chunk.emitPushConst(allocator, one_idx);
    try func.chunk.emitOp(allocator, .define_local);
    try func.chunk.emitU16(allocator, 0);
    try func.chunk.emitU8(allocator, 1);

    try func.chunk.emitPushConst(allocator, two_idx);
    try func.chunk.emitOp(allocator, .set_frame_local);
    try func.chunk.emitU16(allocator, 0);

    try func.chunk.emitOp(allocator, .ret);

    try vm.pushFrame(func, 0);
    try std.testing.expectError(error.ConstAssignment, vm.execute());
}

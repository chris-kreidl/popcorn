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

    pub fn toString(self: Value, allocator: std.mem.Allocator) []const u8 {
        return switch (self) {
            .int => |v| std.fmt.allocPrint(allocator, "{d}", .{v}) catch @panic("OOM"),
            .float => |v| std.fmt.allocPrint(allocator, "{d}", .{v}) catch @panic("OOM"),
            .string => |v| v,
            .boolean => |v| if (v) "true" else "false",
            .null_val => "null",
            .function => |f| std.fmt.allocPrint(allocator, "<fn {s}>", .{f.name}) catch @panic("OOM"),
        };
    }
};

const OpCode = enum(u8) {
    push_const,
    pop,

    load_global,
    define_global,
    set_global,

    load_local,
    define_local,
    set_local,
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
    global_names: std.StringHashMap(void),
    in_script: bool,
    lexical_depth: usize,
    runtime_scope_stack: std.ArrayList(bool),

    pub fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .allocator = allocator,
            .global_names = std.StringHashMap(void).init(allocator),
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

        const fn_obj = try self.allocator.create(Function);
        fn_obj.* = .{
            .name = "<script>",
            .arity = 0,
            .local_slot_count = 0,
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
                try func.chunk.emitOp(self.allocator, .truthy);
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
                try func.chunk.emitOp(self.allocator, .truthy);
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
                        try func.chunk.emitOp(self.allocator, .truthy);
                        const jfalse_pos = try func.chunk.emitJumpPlaceholder(self.allocator, .jump_if_false);
                        try func.chunk.emitOp(self.allocator, .pop);
                        try self.compileExpr(func, b.right);
                        try func.chunk.emitOp(self.allocator, .truthy);
                        const end: u32 = @intCast(func.chunk.code.items.len);
                        func.chunk.patchU32At(jfalse_pos, end);
                    },
                    .pipe_pipe => {
                        try self.compileExpr(func, b.left);
                        try func.chunk.emitOp(self.allocator, .truthy);
                        const jtrue_pos = try func.chunk.emitJumpPlaceholder(self.allocator, .jump_if_true);
                        try func.chunk.emitOp(self.allocator, .pop);
                        try self.compileExpr(func, b.right);
                        try func.chunk.emitOp(self.allocator, .truthy);
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
                try func.chunk.emitOp(self.allocator, .load_local);
                try func.chunk.emitU16(self.allocator, runtime_depth);
                try func.chunk.emitU16(self.allocator, r.slot);
            },
            .global => {
                const idx = try func.chunk.addConst(self.allocator, .{ .string = name });
                try func.chunk.emitOp(self.allocator, .load_global);
                _ = try func.chunk.emitU32(self.allocator, idx);
            },
        }
    }

    fn emitDefineBinding(self: *Compiler, func: *Function, name: []const u8, resolved_slot: ?u16, is_const: bool) CompileError!void {
        if (resolved_slot) |slot| {
            if (self.in_script and self.lexical_depth == 0) {
                const idx = try func.chunk.addConst(self.allocator, .{ .string = name });
                try func.chunk.emitOp(self.allocator, .define_global);
                _ = try func.chunk.emitU32(self.allocator, idx);
                try func.chunk.emitU8(self.allocator, if (is_const) 1 else 0);
                return;
            }
            try func.chunk.emitOp(self.allocator, .define_local);
            try func.chunk.emitU16(self.allocator, slot);
            try func.chunk.emitU8(self.allocator, if (is_const) 1 else 0);
        } else {
            const idx = try func.chunk.addConst(self.allocator, .{ .string = name });
            try func.chunk.emitOp(self.allocator, .define_global);
            _ = try func.chunk.emitU32(self.allocator, idx);
            try func.chunk.emitU8(self.allocator, if (is_const) 1 else 0);
        }
    }

    fn emitSetBinding(self: *Compiler, func: *Function, name: []const u8, resolved: ?ResolvedSlot) CompileError!void {
        switch (try self.classifyBinding(name, resolved)) {
            .local => |r| {
                const runtime_depth = try self.runtimeDepthForResolved(r);
                try func.chunk.emitOp(self.allocator, .set_local);
                try func.chunk.emitU16(self.allocator, runtime_depth);
                try func.chunk.emitU16(self.allocator, r.slot);
            },
            .global => {
                const idx = try func.chunk.addConst(self.allocator, .{ .string = name });
                try func.chunk.emitOp(self.allocator, .set_global);
                _ = try func.chunk.emitU32(self.allocator, idx);
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
                if (r.depth == current_depth) return .global;
                return .{ .local = r };
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

pub const Vm = struct {
    allocator: std.mem.Allocator,
    globals: std.StringHashMap(GlobalEntry),
    stack: std.ArrayList(Value),
    frames: std.ArrayList(Frame),
    scope_stack: std.ArrayList(ScopeState),
    local_values: std.ArrayList(Value),
    local_set: std.ArrayList(bool),
    local_const: std.ArrayList(bool),
    output: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Vm {
        return .{
            .allocator = allocator,
            .globals = std.StringHashMap(GlobalEntry).init(allocator),
            .stack = .empty,
            .frames = .empty,
            .scope_stack = .empty,
            .local_values = .empty,
            .local_set = .empty,
            .local_const = .empty,
            .output = .empty,
        };
    }

    pub fn runProgram(self: *Vm, stmts: []*Stmt) VmError!?Value {
        var compiler = Compiler.init(self.allocator);
        const script = compiler.compileProgram(stmts) catch |err| return err;

        try self.pushFrame(script, 0);
        return self.execute();
    }

    fn pushFrame(self: *Vm, func: *Function, stack_base: usize) RuntimeError!void {
        const scope_base = self.scope_stack.items.len;
        const locals_base = self.local_values.items.len;
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
        return self.stack.pop().?;
    }

    fn push(self: *Vm, v: Value) RuntimeError!void {
        self.stack.append(self.allocator, v) catch return error.RuntimeError;
    }

    fn frame(self: *Vm) *Frame {
        return &self.frames.items[self.frames.items.len - 1];
    }

    fn pushScope(self: *Vm, slot_count_u16: u16) RuntimeError!void {
        const slot_count: usize = @intCast(slot_count_u16);
        const base = self.local_values.items.len;

        // Many control-flow scopes contain no declarations; keep those scopes
        // cheap by avoiding local-array resize/zero-fill work.
        if (slot_count != 0) {
            self.local_values.resize(self.allocator, base + slot_count) catch return error.RuntimeError;
            self.local_set.resize(self.allocator, base + slot_count) catch return error.RuntimeError;
            self.local_const.resize(self.allocator, base + slot_count) catch return error.RuntimeError;

            for (base..base + slot_count) |i| {
                self.local_values.items[i] = .null_val;
                self.local_set.items[i] = false;
                self.local_const.items[i] = false;
            }
        }

        self.scope_stack.append(self.allocator, .{ .base = base, .len = slot_count }) catch return error.RuntimeError;
    }

    fn popScope(self: *Vm, fr: *Frame) RuntimeError!void {
        if (self.scope_stack.items.len == fr.scope_base) return error.RuntimeError;
        const scope = self.scope_stack.pop().?;
        if (scope.len != 0) {
            self.local_values.shrinkRetainingCapacity(scope.base);
            self.local_set.shrinkRetainingCapacity(scope.base);
            self.local_const.shrinkRetainingCapacity(scope.base);
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
        while (self.frames.items.len > 0) {
            var fr = self.frame();
            const op_byte = try self.readU8(fr);
            const op: OpCode = @enumFromInt(op_byte);

            switch (op) {
                .push_const => {
                    const idx = try self.readU32(fr);
                    try self.push(try constAt(fr, idx));
                },
                .pop => _ = try self.pop(),

                .load_global => {
                    const name_idx = try self.readU32(fr);
                    const c = try constAt(fr, name_idx);
                    const name = switch (c) {
                        .string => |s| s,
                        else => return error.RuntimeError,
                    };
                    const entry = self.globals.get(name) orelse return error.UndefinedVariable;
                    try self.push(entry.value);
                },
                .define_global => {
                    const name_idx = try self.readU32(fr);
                    const is_const = (try self.readU8(fr)) != 0;
                    const c = try constAt(fr, name_idx);
                    const name = switch (c) {
                        .string => |s| s,
                        else => return error.RuntimeError,
                    };
                    const v = try self.pop();
                    self.globals.put(name, .{ .value = v, .is_const = is_const }) catch return error.RuntimeError;
                },
                .set_global => {
                    const name_idx = try self.readU32(fr);
                    const c = try constAt(fr, name_idx);
                    const name = switch (c) {
                        .string => |s| s,
                        else => return error.RuntimeError,
                    };
                    const v = try self.pop();
                    const entry = self.globals.getPtr(name) orelse return error.UndefinedVariable;
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
                    if (!self.local_set.items[idx]) return error.UndefinedVariable;
                    try self.push(self.local_values.items[idx]);
                },
                .define_local => {
                    const slot = try self.readU16(fr);
                    const is_const = (try self.readU8(fr)) != 0;
                    const scope = try self.currentScope(fr);
                    const i: usize = @intCast(slot);
                    if (i >= scope.len) return error.RuntimeError;
                    const v = try self.pop();
                    const idx = scope.base + i;
                    self.local_values.items[idx] = v;
                    self.local_set.items[idx] = true;
                    self.local_const.items[idx] = is_const;
                },
                .set_local => {
                    const depth = try self.readU16(fr);
                    const slot = try self.readU16(fr);
                    const scope = try self.scopeAtDepth(fr, depth);
                    const i: usize = @intCast(slot);
                    if (i >= scope.len) return error.UndefinedVariable;
                    const idx = scope.base + i;
                    if (!self.local_set.items[idx]) return error.UndefinedVariable;
                    if (self.local_const.items[idx]) return error.ConstAssignment;
                    const v = try self.pop();
                    self.local_values.items[idx] = v;
                },

                .add => try self.binArithAdd(),
                .sub => try self.binArith(.sub),
                .mul => try self.binArith(.mul),
                .div => try self.binArith(.div),
                .mod => try self.binArith(.mod),
                .neg => {
                    const v = try self.pop();
                    switch (v) {
                        .int => |iv| try self.push(.{ .int = std.math.negate(iv) catch return error.IntegerOverflow }),
                        .float => |fv| try self.push(.{ .float = -fv }),
                        else => return error.TypeError,
                    }
                },
                .not => {
                    const v = try self.pop();
                    try self.push(.{ .boolean = !v.isTruthy() });
                },
                .truthy => {
                    const v = try self.pop();
                    try self.push(.{ .boolean = v.isTruthy() });
                },
                .equal => try self.binCompare(.eq),
                .not_equal => try self.binCompare(.neq),
                .less => try self.binCompare(.lt),
                .greater => try self.binCompare(.gt),
                .less_equal => try self.binCompare(.le),
                .greater_equal => try self.binCompare(.ge),

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

                    try self.pushFrame(fn_obj, callee_idx);
                    const new_fr = self.frame();
                    for (fn_obj.param_slots, 0..) |slot, i| {
                        const root_scope = try self.currentScope(new_fr);
                        const slot_i: usize = @intCast(slot);
                        if (slot_i >= root_scope.len) return error.RuntimeError;
                        const idx = root_scope.base + slot_i;
                        const arg_val = self.stack.items[callee_idx + 1 + i];
                        self.local_values.items[idx] = arg_val;
                        self.local_set.items[idx] = true;
                        self.local_const.items[idx] = false;
                    }
                },
                .ret => {
                    const ret_val = try self.pop();
                    const finished = self.frames.pop().?;
                    self.scope_stack.shrinkRetainingCapacity(finished.scope_base);
                    self.local_values.shrinkRetainingCapacity(finished.locals_base);
                    self.local_set.shrinkRetainingCapacity(finished.locals_base);
                    self.local_const.shrinkRetainingCapacity(finished.locals_base);
                    self.stack.shrinkRetainingCapacity(finished.stack_base);
                    if (self.frames.items.len == 0) {
                        return ret_val;
                    }
                    try self.push(ret_val);
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

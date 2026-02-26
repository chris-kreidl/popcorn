const std = @import("std");
const ast = @import("ast.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const TokenType = @import("token.zig").TokenType;

pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    null_val,
    function: Function,

    pub const Function = struct {
        name: []const u8,
        params: []const Stmt.Param,
        body: []const *Stmt,
        closure: *Environment,
    };

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

    // Returns a displayable string. Some arms return borrowed/static slices,
    // others allocate via the (arena) allocator. Callers must not free the result.
    pub fn toString(self: Value, allocator: std.mem.Allocator) []const u8 {
        return switch (self) {
            .int => |v| std.fmt.allocPrint(allocator, "{d}", .{v}) catch @panic("OOM"),
            .float => |v| std.fmt.allocPrint(allocator, "{d}", .{v}) catch @panic("OOM"),
            .string => |v| v,
            .boolean => |v| if (v) "true" else "false",
            .null_val => "null",
            .function => |v| std.fmt.allocPrint(allocator, "<fn {s}>", .{v.name}) catch @panic("OOM"),
        };
    }
};

// Environments are arena-allocated; freed in bulk when the arena is torn down.
// No individual deinit is needed.
pub const Environment = struct {
    values: std.StringHashMap(Entry),
    parent: ?*Environment,
    allocator: std.mem.Allocator,

    const Entry = struct {
        value: Value,
        is_const: bool,
    };

    pub fn init(allocator: std.mem.Allocator, parent: ?*Environment) !*Environment {
        const env = try allocator.create(Environment);
        env.* = .{
            .values = std.StringHashMap(Entry).init(allocator),
            .parent = parent,
            .allocator = allocator,
        };
        return env;
    }

    pub fn define(self: *Environment, name: []const u8, value: Value, is_const: bool) !void {
        try self.values.put(name, .{ .value = value, .is_const = is_const });
    }

    pub fn get(self: *Environment, name: []const u8) ?Value {
        if (self.values.get(name)) |entry| {
            return entry.value;
        }
        if (self.parent) |p| {
            return p.get(name);
        }
        return null;
    }

    pub fn set(self: *Environment, name: []const u8, value: Value) !void {
        if (self.values.getPtr(name)) |entry| {
            if (entry.is_const) {
                return error.ConstAssignment;
            }
            entry.value = value;
            return;
        }
        if (self.parent) |p| {
            return p.set(name, value);
        }
        return error.UndefinedVariable;
    }
};

pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    global_env: *Environment,
    output: std.ArrayList(u8),
    return_value: Value = .null_val,

    pub fn init(allocator: std.mem.Allocator) !Interpreter {
        const env = try Environment.init(allocator, null);
        return .{
            .allocator = allocator,
            .global_env = env,
            .output = .empty,
        };
    }

    pub fn interpret(self: *Interpreter, stmts: []const *Stmt) !?Value {
        return self.executeStmts(stmts, self.global_env);
    }

    fn executeStmts(self: *Interpreter, stmts: []const *Stmt, env: *Environment) !?Value {
        var last_value: ?Value = null;
        for (stmts) |stmt| {
            last_value = try self.executeStmt(stmt, env);
        }
        return last_value;
    }

    fn executeStmt(self: *Interpreter, stmt: *const Stmt, env: *Environment) InterpreterError!?Value {
        switch (stmt.*) {
            .expr_stmt => |expr| {
                const val = try self.evalExpr(expr, env);
                return val;
            },
            .print_stmt => |expr| {
                const val = try self.evalExpr(expr, env);
                const str = val.toString(self.allocator);
                self.output.appendSlice(self.allocator, str) catch return error.RuntimeError;
                self.output.append(self.allocator, '\n') catch return error.RuntimeError;
                return null;
            },
            .var_decl => |decl| {
                const val = try self.evalExpr(decl.initializer, env);
                env.define(decl.name, val, decl.is_const) catch return error.RuntimeError;
                return null;
            },
            .assignment => |assign| {
                const val = try self.evalExpr(assign.value, env);
                env.set(assign.name, val) catch |err| switch (err) {
                    error.ConstAssignment => return error.ConstAssignment,
                    error.UndefinedVariable => return error.UndefinedVariable,
                };
                return null;
            },
            .block => |stmts| {
                const block_env = Environment.init(self.allocator, env) catch return error.RuntimeError;
                return self.executeStmts(stmts, block_env);
            },
            .if_stmt => |if_s| {
                const cond = try self.evalExpr(if_s.condition, env);
                if (cond.isTruthy()) {
                    return self.executeBlock(if_s.then_branch, env);
                } else if (if_s.else_branch) |else_b| {
                    return self.executeBlock(else_b, env);
                }
                return null;
            },
            .while_stmt => |while_s| {
                while (true) {
                    const cond = try self.evalExpr(while_s.condition, env);
                    if (!cond.isTruthy()) break;
                    _ = self.executeBlock(while_s.body, env) catch |err| {
                        if (err == error.ReturnSignal) return err;
                        return err;
                    };
                }
                return null;
            },
            .fn_decl => |fn_d| {
                const func = Value{ .function = .{
                    .name = fn_d.name,
                    .params = fn_d.params,
                    .body = fn_d.body,
                    .closure = env,
                } };
                env.define(fn_d.name, func, true) catch return error.RuntimeError;
                return null;
            },
            .return_stmt => |ret| {
                if (ret.value) |val_expr| {
                    const val = try self.evalExpr(val_expr, env);
                    self.return_value = val;
                } else {
                    self.return_value = .null_val;
                }
                return error.ReturnSignal;
            },
        }
    }

    fn executeBlock(self: *Interpreter, stmts: []const *Stmt, parent: *Environment) InterpreterError!?Value {
        const block_env = Environment.init(self.allocator, parent) catch return error.RuntimeError;
        return self.executeStmts(stmts, block_env);
    }

    fn evalExpr(self: *Interpreter, expr: *const Expr, env: *Environment) InterpreterError!Value {
        return switch (expr.*) {
            .integer_literal => |v| Value{ .int = v },
            .float_literal => |v| Value{ .float = v },
            .string_literal => |v| Value{ .string = v },
            .bool_literal => |v| Value{ .boolean = v },
            .null_literal => Value.null_val,
            .identifier => |name| {
                return env.get(name) orelse error.UndefinedVariable;
            },
            .grouping => |inner| self.evalExpr(inner, env),
            .unary => |u| self.evalUnary(u, env),
            .binary => |b| self.evalBinary(b, env),
            .call => |c| self.evalCall(c, env),
        };
    }

    fn evalUnary(self: *Interpreter, u: Expr.Unary, env: *Environment) InterpreterError!Value {
        const operand = try self.evalExpr(u.operand, env);
        return switch (u.operator) {
            .minus => switch (operand) {
                .int => |v| Value{ .int = std.math.negate(v) catch return error.IntegerOverflow },
                .float => |v| Value{ .float = -v },
                else => error.TypeError,
            },
            .bang => Value{ .boolean = !operand.isTruthy() },
            else => error.RuntimeError,
        };
    }

    fn evalBinary(self: *Interpreter, b: Expr.Binary, env: *Environment) InterpreterError!Value {
        const left = try self.evalExpr(b.left, env);
        // Short-circuit for logical operators
        if (b.operator == .amp_amp) {
            if (!left.isTruthy()) return Value{ .boolean = false };
            const right = try self.evalExpr(b.right, env);
            return Value{ .boolean = right.isTruthy() };
        }
        if (b.operator == .pipe_pipe) {
            if (left.isTruthy()) return Value{ .boolean = true };
            const right = try self.evalExpr(b.right, env);
            return Value{ .boolean = right.isTruthy() };
        }

        const right = try self.evalExpr(b.right, env);

        // Equality works on all types
        if (b.operator == .equal or b.operator == .not_equal) {
            const eq = valuesEqual(left, right);
            return Value{ .boolean = if (b.operator == .equal) eq else !eq };
        }

        // String concatenation
        if (b.operator == .plus) {
            if (left == .string and right == .string) {
                const result = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ left.string, right.string }) catch return error.RuntimeError;
                return Value{ .string = result };
            }
        }

        // Arithmetic: int op int, float op float
        return switch (left) {
            .int => |lv| switch (right) {
                .int => |rv| intArith(lv, rv, b.operator),
                else => error.TypeError,
            },
            .float => |lv| switch (right) {
                .float => |rv| floatArith(lv, rv, b.operator),
                else => error.TypeError,
            },
            else => error.TypeError,
        };
    }

    fn checkedInt(a: i64, b: i64, comptime op: enum { add, sub, mul }) InterpreterError!Value {
        const result = switch (op) {
            .add => @addWithOverflow(a, b),
            .sub => @subWithOverflow(a, b),
            .mul => @mulWithOverflow(a, b),
        };
        if (result[1] != 0) return error.IntegerOverflow;
        return Value{ .int = result[0] };
    }

    fn intArith(l: i64, r: i64, op: TokenType) InterpreterError!Value {
        return switch (op) {
            .plus => checkedInt(l, r, .add),
            .minus => checkedInt(l, r, .sub),
            .star => checkedInt(l, r, .mul),
            .slash => {
                if (r == 0) return error.DivisionByZero;
                return Value{ .int = @divTrunc(l, r) };
            },
            .percent => {
                if (r == 0) return error.DivisionByZero;
                return Value{ .int = @mod(l, r) };
            },
            .less => Value{ .boolean = l < r },
            .greater => Value{ .boolean = l > r },
            .less_equal => Value{ .boolean = l <= r },
            .greater_equal => Value{ .boolean = l >= r },
            else => error.RuntimeError,
        };
    }

    fn floatArith(l: f64, r: f64, op: TokenType) InterpreterError!Value {
        return switch (op) {
            .plus => Value{ .float = l + r },
            .minus => Value{ .float = l - r },
            .star => Value{ .float = l * r },
            .slash => {
                if (r == 0.0) return error.DivisionByZero;
                return Value{ .float = l / r };
            },
            .percent => {
                if (r == 0.0) return error.DivisionByZero;
                return Value{ .float = @mod(l, r) };
            },
            .less => Value{ .boolean = l < r },
            .greater => Value{ .boolean = l > r },
            .less_equal => Value{ .boolean = l <= r },
            .greater_equal => Value{ .boolean = l >= r },
            else => error.RuntimeError,
        };
    }

    fn evalCall(self: *Interpreter, c: Expr.Call, env: *Environment) InterpreterError!Value {
        const callee_val = env.get(c.callee) orelse return error.UndefinedVariable;
        const func = switch (callee_val) {
            .function => |f| f,
            else => return error.TypeError,
        };

        if (c.args.len != func.params.len) {
            return error.ArityMismatch;
        }

        const call_env = Environment.init(self.allocator, func.closure) catch return error.RuntimeError;
        for (func.params, c.args) |param, arg_expr| {
            const val = try self.evalExpr(arg_expr, env);
            call_env.define(param.name, val, false) catch return error.RuntimeError;
        }

        // Execute function body, catching ReturnSignal
        for (func.body) |stmt| {
            _ = self.executeStmt(stmt, call_env) catch |err| {
                if (err == error.ReturnSignal) {
                    return self.return_value;
                }
                return err;
            };
        }
        return Value.null_val;
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

    pub const InterpreterError = error{
        RuntimeError,
        TypeError,
        UndefinedVariable,
        ConstAssignment,
        DivisionByZero,
        IntegerOverflow,
        ArityMismatch,
        ReturnSignal,
    };
};

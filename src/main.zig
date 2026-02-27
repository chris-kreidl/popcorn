const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Resolver = @import("resolver.zig").Resolver;
const Interpreter = @import("interpreter.zig").Interpreter;
const Value = @import("interpreter.zig").Value;
const Vm = @import("vm.zig").Vm;
const File = std.fs.File;
const RunStatus = enum { ok, language_error };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const base_allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        try runFile(allocator, args[1]);
    } else {
        try runRepl(allocator);
    }
}

fn writeAll(file: File, bytes: []const u8) !void {
    try file.writeAll(bytes);
}

fn printFmt(allocator: std.mem.Allocator, file: File, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    try writeAll(file, msg);
}

fn vmEnabled(allocator: std.mem.Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "POPCORN_VM") catch return false;
    defer allocator.free(value);
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

fn runFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const source = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
        printFmt(allocator, File.stderr(), "Error: Could not read file '{s}': {}\n", .{ path, err }) catch {};
        std.process.exit(1);
    };
    defer allocator.free(source);

    var interp = try Interpreter.init(allocator);
    const status = try run(allocator, source, &interp, false);
    if (status == .language_error) {
        std.process.exit(1);
    }
}

fn runRepl(allocator: std.mem.Allocator) !void {
    const stdout = File.stdout();
    const stdin = File.stdin().deprecatedReader();

    try writeAll(stdout, "Popcorn v0.1.0\n");
    try writeAll(stdout, "Type expressions or statements. Ctrl+D to exit.\n");

    var interp = try Interpreter.init(allocator);

    while (true) {
        try writeAll(stdout, ">> ");
        // Per-input temporary storage; parser clones any source slices the AST needs.
        var line_arena = std.heap.ArenaAllocator.init(allocator);
        defer line_arena.deinit();
        const line_allocator = line_arena.allocator();

        const line = stdin.readUntilDelimiterAlloc(line_allocator, '\n', 4096) catch |err| {
            if (err == error.EndOfStream) {
                try writeAll(stdout, "\nBye!\n");
                break;
            }
            return err;
        };

        if (line.len == 0) continue;

        _ = try run(allocator, line, &interp, true);
    }
}

fn run(allocator: std.mem.Allocator, source: []const u8, interp: *Interpreter, is_repl: bool) !RunStatus {
    const stderr = File.stderr();
    const stdout = File.stdout();

    var parser = Parser.init(allocator, source);
    const stmts = parser.parse() catch {
        const line = parser.current.line;
        const msg = parser.error_msg orelse "Unknown error";
        try printFmt(allocator, stderr, "[line {d}] Error: {s}\n", .{ line, msg });
        return .language_error;
    };

    var resolver = Resolver.init(allocator);
    defer resolver.deinit();
    resolver.resolve(stmts) catch |err| {
        switch (err) {
            error.TooManyVariablesInScope => {
                try writeAll(stderr, "Error: Function has more than 65,535 local variables\n");
                return .language_error;
            },
            error.ScopeNestingTooDeep => {
                try writeAll(stderr, "Error: Scope nesting exceeds 65,535 levels\n");
                return .language_error;
            },
            else => return err,
        }
    };

    if (vmEnabled(allocator)) {
        var vm = Vm.init(allocator);
        const vm_result = vm.runProgram(stmts) catch |err| switch (err) {
            error.UnsupportedFeature => blk: {
                try writeAll(stderr, "Warning: VM encountered unsupported feature; falling back to interpreter\n");
                break :blk null;
            },
            error.TypeError => {
                try printFmt(allocator, stderr, "Error: Type error\n", .{});
                return .language_error;
            },
            error.UndefinedVariable => {
                try printFmt(allocator, stderr, "Error: Undefined variable\n", .{});
                return .language_error;
            },
            error.ConstAssignment => {
                try printFmt(allocator, stderr, "Error: Cannot assign to const variable\n", .{});
                return .language_error;
            },
            error.DivisionByZero => {
                try printFmt(allocator, stderr, "Error: Division by zero\n", .{});
                return .language_error;
            },
            error.IntegerOverflow => {
                try printFmt(allocator, stderr, "Error: Integer overflow\n", .{});
                return .language_error;
            },
            error.ArityMismatch => {
                try printFmt(allocator, stderr, "Error: Wrong number of arguments\n", .{});
                return .language_error;
            },
            error.RuntimeError => {
                try printFmt(allocator, stderr, "Error: Runtime error\n", .{});
                return .language_error;
            },
            error.ReturnOutsideFunction => {
                try printFmt(allocator, stderr, "Error: Return outside of function\n", .{});
                return .language_error;
            },
            else => return err,
        };

        if (vm_result) |result| {
            if (vm.output.items.len > 0) {
                try writeAll(stdout, vm.output.items);
            }

            if (is_repl) {
                switch (result) {
                    .null_val => {},
                    else => {
                        const str = result.toString(allocator);
                        defer allocator.free(str);
                        try writeAll(stdout, str);
                        try writeAll(stdout, "\n");
                    },
                }
            }
            return .ok;
        }
    }

    const result = interp.interpret(stmts) catch |err| {
        const msg: []const u8 = switch (err) {
            error.TypeError => "Type error",
            error.UndefinedVariable => "Undefined variable",
            error.ConstAssignment => "Cannot assign to const variable",
            error.DivisionByZero => "Division by zero",
            error.IntegerOverflow => "Integer overflow",
            error.ArityMismatch => "Wrong number of arguments",
            error.RuntimeError => "Runtime error",
            error.ReturnSignal => "Return outside of function",
        };
        try printFmt(allocator, stderr, "Error: {s}\n", .{msg});
        return .language_error;
    };

    // Flush interpreter output
    if (interp.output.items.len > 0) {
        try writeAll(stdout, interp.output.items);
        interp.output.clearRetainingCapacity();
    }

    // In REPL mode, print expression results
    if (is_repl) {
        if (result) |val| {
            switch (val) {
                .null_val => {},
                else => {
                    const str = val.toString(allocator);
                    try writeAll(stdout, str);
                    try writeAll(stdout, "\n");
                },
            }
        }
    }

    return .ok;
}

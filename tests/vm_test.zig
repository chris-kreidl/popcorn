const std = @import("std");
const Parser = @import("../src/parser.zig").Parser;
const Resolver = @import("../src/resolver.zig").Resolver;
const Vm = @import("../src/vm.zig").Vm;
const Value = @import("../src/vm.zig").Value;
const Stmt = @import("../src/ast.zig").Stmt;

fn parseAndResolve(allocator: std.mem.Allocator, source: []const u8) ![]*Stmt {
    var parser = Parser.init(allocator, source);
    const stmts = try parser.parse();

    var resolver = Resolver.init(allocator);
    defer resolver.deinit();
    try resolver.resolve(stmts);
    return stmts;
}

test "vm: arithmetic and while loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\var i: int = 0;
        \\var sum: int = 0;
        \\while i < 5 {
        \\    sum = sum + i;
        \\    i = i + 1;
        \\}
        \\print(sum);
    ;

    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    _ = try vm.runProgram(stmts);
    try std.testing.expectEqualStrings("10\n", vm.output.items);
}

test "vm: global function call and recursion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn fib(n: int): int {
        \\    if n <= 1 {
        \\        return n;
        \\    }
        \\    return fib(n - 1) + fib(n - 2);
        \\}
        \\print(fib(8));
    ;

    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    _ = try vm.runProgram(stmts);
    try std.testing.expectEqualStrings("21\n", vm.output.items);
}

test "vm: script locals stay fast and remain visible to functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\var x: int = 1;
        \\fn readX(): int {
        \\    return x;
        \\}
        \\x = 2;
        \\print(readX());
    ;

    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    _ = try vm.runProgram(stmts);
    try std.testing.expectEqualStrings("2\n", vm.output.items);
    try std.testing.expect(vm.hasGlobal("x"));
}

test "vm: nested function captures outer locals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn outer(a: int): int {
        \\    fn inner(b: int): int {
        \\        return a + b;
        \\    }
        \\    return inner(2);
        \\}
        \\print(outer(5));
    ;

    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    _ = try vm.runProgram(stmts);
    try std.testing.expectEqualStrings("7\n", vm.output.items);
}

test "vm: top-level vars are not exported when no function references them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\var i: int = 0;
        \\var sum: int = 0;
        \\while i < 3 {
        \\    sum = sum + i;
        \\    i = i + 1;
        \\}
        \\print(sum);
    ;

    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    _ = try vm.runProgram(stmts);
    try std.testing.expectEqualStrings("3\n", vm.output.items);
    try std.testing.expect(!vm.hasGlobal("i"));
    try std.testing.expect(!vm.hasGlobal("sum"));
}

test "vm: deep expression grows stack safely beyond initial capacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const depth: usize = 1500;

    var src = std.ArrayList(u8).empty;
    defer src.deinit(allocator);

    try src.appendSlice(allocator, "print(");
    for (0..depth) |_| {
        try src.appendSlice(allocator, "1 + (");
    }
    try src.appendSlice(allocator, "1");
    for (0..depth) |_| {
        try src.append(allocator, ')');
    }
    try src.appendSlice(allocator, ");");

    const stmts = try parseAndResolve(allocator, src.items);
    var vm = Vm.init(allocator);
    _ = try vm.runProgram(stmts);

    const expected = try std.fmt.allocPrint(allocator, "{d}\n", .{depth + 1});
    try std.testing.expectEqualStrings(expected, vm.output.items);
}

test "vm: globals persist across runProgram calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var vm = Vm.init(allocator);
    vm.setExportScriptGlobals(true);

    const source1 =
        \\var x: int = 41;
    ;
    const stmts1 = try parseAndResolve(allocator, source1);
    _ = try vm.runProgram(stmts1);

    const source2 =
        \\x = x + 1;
        \\print(x);
    ;
    const stmts2 = try parseAndResolve(allocator, source2);
    _ = try vm.runProgram(stmts2);
    try std.testing.expectEqualStrings("42\n", vm.output.items);
}

// The REPL must call setExportScriptGlobals(true) on its VM; without it
// globals from one input line are not visible on the next.
test "vm: globals do not persist without setExportScriptGlobals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var vm = Vm.init(allocator); // intentionally no setExportScriptGlobals

    const source1 =
        \\var x: int = 41;
    ;
    const stmts1 = try parseAndResolve(allocator, source1);
    _ = try vm.runProgram(stmts1);

    const source2 =
        \\x = x + 1;
        \\print(x);
    ;
    const stmts2 = try parseAndResolve(allocator, source2);
    try std.testing.expectError(error.UndefinedVariable, vm.runProgram(stmts2));
}

test "value: toString returns error.OutOfMemory instead of panicking" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();

    try std.testing.expectError(error.OutOfMemory, (Value{ .int = 42 }).toString(allocator));
    try std.testing.expectError(error.OutOfMemory, (Value{ .float = 3.14 }).toString(allocator));
    try std.testing.expectError(error.OutOfMemory, (Value{ .boolean = true }).toString(allocator));
    try std.testing.expectError(error.OutOfMemory, (Value{ .null_val = {} }).toString(allocator));
    try std.testing.expectError(error.OutOfMemory, (Value{ .string = "hi" }).toString(allocator));
}

// --- Runtime error paths via runProgram ---

test "vm: division by zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = \\print(10 / 0);
    ;
    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    try std.testing.expectError(error.DivisionByZero, vm.runProgram(stmts));
}

test "vm: integer overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\var x: int = 9223372036854775807;
        \\print(x + 1);
    ;
    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    try std.testing.expectError(error.IntegerOverflow, vm.runProgram(stmts));
}

test "vm: arity mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn f(a: int): int { return a; }
        \\print(f(1, 2));
    ;
    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    try std.testing.expectError(error.ArityMismatch, vm.runProgram(stmts));
}

test "vm: type error on incompatible binary operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = \\print(true + 1);
    ;
    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    try std.testing.expectError(error.TypeError, vm.runProgram(stmts));
}

test "vm: const assignment at script level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\const x: int = 1;
        \\x = 2;
    ;
    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    try std.testing.expectError(error.ConstAssignment, vm.runProgram(stmts));
}

// --- Non-integer value types ---

test "vm: print string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = \\print("hello");
    ;
    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    _ = try vm.runProgram(stmts);
    try std.testing.expectEqualStrings("hello\n", vm.output.items);
}

test "vm: print boolean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\print(true);
        \\print(false);
    ;
    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    _ = try vm.runProgram(stmts);
    try std.testing.expectEqualStrings("true\nfalse\n", vm.output.items);
}

test "vm: print null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = \\print(null);
    ;
    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    _ = try vm.runProgram(stmts);
    try std.testing.expectEqualStrings("null\n", vm.output.items);
}

test "vm: print float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = \\print(1.5);
    ;
    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    _ = try vm.runProgram(stmts);
    try std.testing.expectEqualStrings("1.5\n", vm.output.items);
}

// --- Block scope (enter_scope / exit_scope opcodes) ---

test "vm: block scope variable accessible within block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn f(): int {
        \\    {
        \\        var x: int = 42;
        \\        print(x);
        \\    }
        \\    return 0;
        \\}
        \\f();
    ;
    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    _ = try vm.runProgram(stmts);
    try std.testing.expectEqualStrings("42\n", vm.output.items);
}

test "vm: block scope variable does not outlive block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn f(): int {
        \\    {
        \\        var x: int = 42;
        \\    }
        \\    return x;
        \\}
        \\f();
    ;
    const stmts = try parseAndResolve(allocator, source);
    var vm = Vm.init(allocator);
    try std.testing.expectError(error.UndefinedVariable, vm.runProgram(stmts));
}

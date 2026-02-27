const std = @import("std");
const Parser = @import("../src/parser.zig").Parser;
const Resolver = @import("../src/resolver.zig").Resolver;
const Vm = @import("../src/vm.zig").Vm;
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

test "vm: closures currently unsupported" {
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
    try std.testing.expectError(error.UnsupportedFeature, vm.runProgram(stmts));
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

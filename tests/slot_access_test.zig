const std = @import("std");
const Parser = @import("../src/parser.zig").Parser;
const Resolver = @import("../src/resolver.zig").Resolver;
const Interpreter = @import("../src/interpreter.zig").Interpreter;
const Value = @import("../src/interpreter.zig").Value;
const Environment = @import("../src/interpreter.zig").Environment;
const Stmt = @import("../src/ast.zig").Stmt;

fn parseResolveRun(allocator: std.mem.Allocator, source: []const u8) !Interpreter {
    var parser = Parser.init(allocator, source);
    const stmts: []*Stmt = try parser.parse();

    var resolver = Resolver.init(allocator);
    defer resolver.deinit();
    try resolver.resolve(stmts);

    var interp = try Interpreter.init(allocator);
    _ = try interp.interpret(stmts);
    return interp;
}

test "slot access: local read and write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn f(): int {
        \\    var x: int = 1;
        \\    x = x + 4;
        \\    return x;
        \\}
        \\print(f());
    ;

    const interp = try parseResolveRun(allocator, source);
    try std.testing.expectEqualStrings("5\n", interp.output.items);
}

test "slot access: HashMap fallback for unresolved global" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\print(external_value);
    ;

    var parser = Parser.init(allocator, source);
    const stmts: []*Stmt = try parser.parse();

    var resolver = Resolver.init(allocator);
    defer resolver.deinit();
    try resolver.resolve(stmts);

    var interp = try Interpreter.init(allocator);
    try interp.global_env.define("external_value", Value{ .int = 41 }, true);
    _ = try interp.interpret(stmts);

    try std.testing.expectEqualStrings("41\n", interp.output.items);
}

test "slot access: const enforcement for resolved slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn f(): int {
        \\    const x: int = 1;
        \\    x = 2;
        \\    return x;
        \\}
        \\print(f());
    ;

    var parser = Parser.init(allocator, source);
    const stmts: []*Stmt = try parser.parse();

    var resolver = Resolver.init(allocator);
    defer resolver.deinit();
    try resolver.resolve(stmts);

    var interp = try Interpreter.init(allocator);
    const result = interp.interpret(stmts);
    try std.testing.expectError(error.ConstAssignment, result);
}

test "slot access: depth-based closure lookup" {
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

    const interp = try parseResolveRun(allocator, source);
    try std.testing.expectEqualStrings("7\n", interp.output.items);
}

test "slot access: 3-level deep closure execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn outer(a: int): int {
        \\    fn middle(b: int): int {
        \\        fn inner(c: int): int {
        \\            return a + b + c;
        \\        }
        \\        return inner(3);
        \\    }
        \\    return middle(2);
        \\}
        \\print(outer(1));
    ;

    const interp = try parseResolveRun(allocator, source);
    try std.testing.expectEqualStrings("6\n", interp.output.items);
}

test "slot access: block scope does not leak variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // x is declared inside a block; accessing it after the block should fail
    const source =
        \\fn f(): int {
        \\    {
        \\        var x: int = 42;
        \\        print(x);
        \\    }
        \\    return x;
        \\}
        \\print(f());
    ;

    var parser = Parser.init(allocator, source);
    const stmts: []*Stmt = try parser.parse();

    var resolver = Resolver.init(allocator);
    defer resolver.deinit();
    try resolver.resolve(stmts);

    var interp = try Interpreter.init(allocator);
    const result = interp.interpret(stmts);
    try std.testing.expectError(error.UndefinedVariable, result);
}

test "slot access: if/while body accesses outer variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn f(): int {
        \\    var x: int = 0;
        \\    if true {
        \\        x = x + 1;
        \\    }
        \\    while x < 3 {
        \\        x = x + 1;
        \\    }
        \\    return x;
        \\}
        \\print(f());
    ;

    const interp = try parseResolveRun(allocator, source);
    try std.testing.expectEqualStrings("3\n", interp.output.items);
}

test "slot access: uninitialized slot returns null/undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const env = try Environment.init(allocator, null);
    try std.testing.expect(env.getResolved(.{ .depth = 0, .slot = 0 }) == null);
    try std.testing.expectError(error.UndefinedVariable, env.setResolved(.{ .depth = 0, .slot = 0 }, Value{ .int = 1 }));
}

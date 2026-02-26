const std = @import("std");
const Parser = @import("../src/parser.zig").Parser;
const Resolver = @import("../src/resolver.zig").Resolver;
const Stmt = @import("../src/ast.zig").Stmt;

fn parseAndResolve(allocator: std.mem.Allocator, source: []const u8) ![]*Stmt {
    var parser = Parser.init(allocator, source);
    const stmts = try parser.parse();

    var resolver = Resolver.init(allocator);
    defer resolver.deinit();
    try resolver.resolve(stmts);
    return stmts;
}

test "resolver: nested scope and shadowing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\var x: int = 1;
        \\{
        \\    var y: int = x;
        \\    var x: int = 2;
        \\    print(y);
        \\}
    ;

    const stmts = try parseAndResolve(allocator, source);

    const global_x = stmts[0].*.var_decl;
    try std.testing.expectEqual(@as(u16, 0), global_x.resolved_slot.?);

    const block = stmts[1].*.block;
    const y_decl = block[0].*.var_decl;
    try std.testing.expectEqual(@as(u16, 0), y_decl.resolved_slot.?);

    const y_init_ident = y_decl.initializer.*.identifier;
    try std.testing.expectEqual(@as(u16, 1), y_init_ident.resolved.?.depth);
    try std.testing.expectEqual(@as(u16, 0), y_init_ident.resolved.?.slot);

    const inner_x = block[1].*.var_decl;
    try std.testing.expectEqual(@as(u16, 1), inner_x.resolved_slot.?);
}

test "resolver: function params and local slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn add(a: int, b: int): int {
        \\    var c: int = a + b;
        \\    return c;
        \\}
    ;

    const stmts = try parseAndResolve(allocator, source);
    const fn_decl = stmts[0].*.fn_decl;

    try std.testing.expectEqual(@as(u16, 0), fn_decl.params[0].resolved_slot.?);
    try std.testing.expectEqual(@as(u16, 1), fn_decl.params[1].resolved_slot.?);
    try std.testing.expectEqual(@as(u16, 3), fn_decl.local_slot_count);

    const c_decl = fn_decl.body[0].*.var_decl;
    try std.testing.expectEqual(@as(u16, 2), c_decl.resolved_slot.?);

    const init = c_decl.initializer.*.binary;
    const a_ident = init.left.*.identifier;
    const b_ident = init.right.*.identifier;
    try std.testing.expectEqual(@as(u16, 0), a_ident.resolved.?.depth);
    try std.testing.expectEqual(@as(u16, 0), a_ident.resolved.?.slot);
    try std.testing.expectEqual(@as(u16, 0), b_ident.resolved.?.depth);
    try std.testing.expectEqual(@as(u16, 1), b_ident.resolved.?.slot);
}

test "resolver: unbound global remains unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\print(external_value);
    ;

    const stmts = try parseAndResolve(allocator, source);
    const print_expr = stmts[0].*.print_stmt;
    const ident = print_expr.*.identifier;
    try std.testing.expect(ident.resolved == null);
}

test "resolver: closure captures outer variable with depth" {
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
    const outer_fn = stmts[0].*.fn_decl;
    const inner_fn = outer_fn.body[0].*.fn_decl;

    const ret_expr = inner_fn.body[0].*.return_stmt.value.?.*.binary;
    const a_ident = ret_expr.left.*.identifier;
    const b_ident = ret_expr.right.*.identifier;

    try std.testing.expectEqual(@as(u16, 1), a_ident.resolved.?.depth);
    try std.testing.expectEqual(@as(u16, 0), a_ident.resolved.?.slot);
    try std.testing.expectEqual(@as(u16, 0), b_ident.resolved.?.depth);
    try std.testing.expectEqual(@as(u16, 0), b_ident.resolved.?.slot);
}

test "resolver: too many variables in scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn f(): int {
        \\    var a: int = 1;
        \\    var b: int = 2;
        \\    var c: int = 3;
        \\    return a + b + c;
        \\}
    ;

    var parser = Parser.init(allocator, source);
    const stmts = try parser.parse();

    var resolver = Resolver.initWithLimits(allocator, 2, std.math.maxInt(u16));
    defer resolver.deinit();
    try std.testing.expectError(error.TooManyVariablesInScope, resolver.resolve(stmts));
}

test "resolver: scope nesting too deep" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\var x: int = 1;
        \\{
        \\    {
        \\        print(x);
        \\    }
        \\}
    ;

    var parser = Parser.init(allocator, source);
    const stmts = try parser.parse();

    var resolver = Resolver.initWithLimits(allocator, std.math.maxInt(u16), 1);
    defer resolver.deinit();
    try std.testing.expectError(error.ScopeNestingTooDeep, resolver.resolve(stmts));
}

test "resolver: 3-level deep closure captures correct depth" {
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

    const stmts = try parseAndResolve(allocator, source);
    const outer_fn = stmts[0].*.fn_decl;
    const middle_fn = outer_fn.body[0].*.fn_decl;
    const inner_fn = middle_fn.body[0].*.fn_decl;

    const ret_expr = inner_fn.body[0].*.return_stmt.value.?.*.binary;
    // a + b + c is parsed as (a + b) + c
    const ab_sum = ret_expr.left.*.binary;
    const a_ident = ab_sum.left.*.identifier;
    const b_ident = ab_sum.right.*.identifier;
    const c_ident = ret_expr.right.*.identifier;

    // a is 2 scopes up from inner
    try std.testing.expectEqual(@as(u16, 2), a_ident.resolved.?.depth);
    try std.testing.expectEqual(@as(u16, 0), a_ident.resolved.?.slot);
    // b is 1 scope up from inner
    try std.testing.expectEqual(@as(u16, 1), b_ident.resolved.?.depth);
    try std.testing.expectEqual(@as(u16, 0), b_ident.resolved.?.slot);
    // c is local to inner
    try std.testing.expectEqual(@as(u16, 0), c_ident.resolved.?.depth);
    try std.testing.expectEqual(@as(u16, 0), c_ident.resolved.?.slot);
}

test "resolver: variable in if/while body resolves to outer scope" {
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
    ;

    const stmts = try parseAndResolve(allocator, source);
    const fn_decl = stmts[0].*.fn_decl;

    // x declaration: slot 0 in function scope
    const x_decl = fn_decl.body[0].*.var_decl;
    try std.testing.expectEqual(@as(u16, 0), x_decl.resolved_slot.?);

    // if body: x = x + 1; assignment should resolve to depth 1 (up to fn scope)
    const if_body = fn_decl.body[1].*.if_stmt.then_branch;
    const if_assign = if_body[0].*.assignment;
    try std.testing.expectEqual(@as(u16, 1), if_assign.resolved.?.depth);
    try std.testing.expectEqual(@as(u16, 0), if_assign.resolved.?.slot);

    // while body: x = x + 1; assignment should also resolve to depth 1
    const while_body = fn_decl.body[2].*.while_stmt.body;
    const while_assign = while_body[0].*.assignment;
    try std.testing.expectEqual(@as(u16, 1), while_assign.resolved.?.depth);
    try std.testing.expectEqual(@as(u16, 0), while_assign.resolved.?.slot);
}

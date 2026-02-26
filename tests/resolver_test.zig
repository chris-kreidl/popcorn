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

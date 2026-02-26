const TokenType = @import("token.zig").TokenType;

pub const Expr = union(enum) {
    integer_literal: i64,
    float_literal: f64,
    string_literal: []const u8,
    bool_literal: bool,
    null_literal,
    identifier: []const u8,
    unary: Unary,
    binary: Binary,
    call: Call,
    grouping: *Expr,

    pub const Unary = struct {
        operator: TokenType,
        operand: *Expr,
    };

    pub const Binary = struct {
        left: *Expr,
        operator: TokenType,
        right: *Expr,
    };

    pub const Call = struct {
        callee: []const u8,
        args: []const *Expr,
    };
};

pub const Stmt = union(enum) {
    expr_stmt: *Expr,
    print_stmt: *Expr,
    var_decl: VarDecl,
    assignment: Assignment,
    block: []const *Stmt,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    fn_decl: FnDecl,
    return_stmt: ReturnStmt,

    pub const VarDecl = struct {
        name: []const u8,
        type_name: ?[]const u8,
        initializer: *Expr,
        is_const: bool,
    };

    pub const Assignment = struct {
        name: []const u8,
        value: *Expr,
    };

    pub const IfStmt = struct {
        condition: *Expr,
        then_branch: []const *Stmt,
        else_branch: ?[]const *Stmt,
    };

    pub const WhileStmt = struct {
        condition: *Expr,
        body: []const *Stmt,
    };

    pub const FnDecl = struct {
        name: []const u8,
        params: []const Param,
        return_type: ?[]const u8,
        body: []const *Stmt,
    };

    pub const Param = struct {
        name: []const u8,
        type_name: []const u8,
    };

    pub const ReturnStmt = struct {
        value: ?*Expr,
    };
};

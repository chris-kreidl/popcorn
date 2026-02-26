const TokenType = @import("token.zig").TokenType;

pub const ResolvedSlot = struct {
    depth: u16,
    slot: u16,
};

pub const Expr = union(enum) {
    integer_literal: i64,
    float_literal: f64,
    string_literal: []const u8,
    bool_literal: bool,
    null_literal,
    identifier: Identifier,
    unary: Unary,
    binary: Binary,
    call: Call,
    grouping: *Expr,

    pub const Identifier = struct {
        name: []const u8,
        resolved: ?ResolvedSlot = null,
    };

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
        callee_resolved: ?ResolvedSlot = null,
        args: []*Expr,
    };
};

pub const Stmt = union(enum) {
    expr_stmt: *Expr,
    print_stmt: *Expr,
    var_decl: VarDecl,
    assignment: Assignment,
    block: []*Stmt,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    fn_decl: FnDecl,
    return_stmt: ReturnStmt,

    pub const VarDecl = struct {
        name: []const u8,
        type_name: ?[]const u8,
        initializer: *Expr,
        is_const: bool,
        resolved_slot: ?u16 = null,
    };

    pub const Assignment = struct {
        name: []const u8,
        value: *Expr,
        resolved: ?ResolvedSlot = null,
    };

    pub const IfStmt = struct {
        condition: *Expr,
        then_branch: []*Stmt,
        else_branch: ?[]*Stmt,
    };

    pub const WhileStmt = struct {
        condition: *Expr,
        body: []*Stmt,
    };

    pub const FnDecl = struct {
        name: []const u8,
        params: []Param,
        return_type: ?[]const u8,
        body: []*Stmt,
        resolved_slot: ?u16 = null,
        local_slot_count: u16 = 0,
    };

    pub const Param = struct {
        name: []const u8,
        type_name: []const u8,
        resolved_slot: ?u16 = null,
    };

    pub const ReturnStmt = struct {
        value: ?*Expr,
    };
};

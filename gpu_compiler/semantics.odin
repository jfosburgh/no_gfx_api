
#+feature using-stmt
#+vet !unused-imports

package main

import "base:runtime"
import "core:fmt"

typecheck_ast :: proc(ast: ^Ast, input_path: string, allocator: runtime.Allocator) -> bool
{
    context.allocator = allocator

    c := Checker {
        ast = ast,
        input_path = input_path,
        scope = ast.scope,
        error = false,
        cur_proc = nil,
        proc_ret = nil,
    }

    add_intrinsics()

    for decl in ast.scope.decls
    {
        switch decl.type.kind
        {
            case .Poison: {}
            case .None: {}
            case .Unknown: {}
            case .Proc:
            {
                for arg in decl.type.args
                {
                    resolve_type(&c, arg.type)
                }

                if decl.type.ret != nil {
                    resolve_type(&c, decl.type.ret)
                }
            }
            case .Struct:
            {
                for member in decl.type.members
                {
                    resolve_type(&c, member.type)
                }
            }
            case .Label: {}
            case .Primitive: {}
            case .Pointer: {}
            case .Slice: {}
        }
    }

    for proc_def in ast.procs
    {
        c.cur_proc = proc_def

        for decl in proc_def.scope.decls
        {
            resolve_type(&c, decl.type)
            decl.glsl_name = ident_to_glsl(decl.name)

            if decl.attr != nil && decl.attr.?.type == .Data
            {
                if decl.type.kind != .Pointer && decl.type.kind != .Slice {
                    typecheck_error(&c, decl.token, "Variable declared with '@data' attribute must be of pointer or slice type.")
                }
            }
            if decl.attr != nil && decl.attr.?.type == .Indirect_Data
            {
                if decl.type.kind != .Pointer && decl.type.kind != .Slice {
                    typecheck_error(&c, decl.token, "Variable declared with '@indirect_data' attribute must be of pointer or slice type.")
                }
            }

            for decl_2 in proc_def.scope.decls
            {
                if decl_2.name == decl.name && raw_data(decl_2.token.text) < raw_data(decl.token.text)
                {
                    typecheck_error_redeclaration(&c, decl_2, decl)
                    break
                }
            }
        }

        old_scope := c.scope
        c.scope = proc_def.scope
        defer c.scope = old_scope

        c.proc_ret = nil

        for stmt in proc_def.statements {
            typecheck_statement(&c, stmt)
        }

        if c.proc_ret != nil && proc_def.decl.type.ret.kind == .None {
            typecheck_error(&c, c.proc_ret.token, "Unexpected return, procedure does not have a return type.")
        } else if c.proc_ret == nil && proc_def.decl.type.ret.kind != .None {
            typecheck_error(&c, proc_def.decl.token, "Missing return statement.")
        }
    }

    return !c.error
}

Checker :: struct #all_or_none
{
    ast: ^Ast,
    cur_proc: ^Ast_Proc_Def,
    scope: ^Ast_Scope,
    input_path: string,
    error: bool,
    proc_ret: ^Ast_Return,
}

typecheck_statement :: proc(using c: ^Checker, statement: ^Ast_Statement)
{
    switch stmt in statement.derived_statement
    {
        case ^Ast_Stmt_Expr:
        {
            typecheck_expr(c, stmt.expr)
        }
        case ^Ast_Assign:
        {
            typecheck_expr(c, stmt.lhs)
            typecheck_expr(c, stmt.rhs)

            if !type_implicit_convert(stmt.rhs.type, stmt.lhs.type) {
                typecheck_error_mismatching_types(c, stmt.token, stmt.lhs.type, stmt.rhs.type)
            }
        }
        case ^Ast_Define_Var:
        {
            typecheck_expr(c, stmt.expr)
            stmt.decl.glsl_name = ident_to_glsl(stmt.decl.name)

            if stmt.expr.type.kind == .None
            {
                typecheck_error(c, stmt.expr.token, "Expression does not return value.")
                stmt.decl.type = &POISON_TYPE
            }
            else if stmt.decl.type.kind == .Unknown
            {
                if stmt.expr.type.primitive_kind == .Untyped_Int {
                    stmt.decl.type = &INT_TYPE
                } else if stmt.expr.type.primitive_kind == .Untyped_Float {
                    stmt.decl.type = &FLOAT_TYPE
                } else {
                    stmt.decl.type = stmt.expr.type
                }
            }
            else
            {
                if !type_implicit_convert(stmt.expr.type, stmt.decl.type) {
                    typecheck_error_mismatching_types(c, stmt.token, stmt.decl.type, stmt.expr.type)
                }
            }
        }
        case ^Ast_If:
        {
            typecheck_expr(c, stmt.cond)
            if !type_implicit_convert(stmt.cond.type, &BOOL_TYPE) {
                typecheck_error_mismatching_types(c, stmt.token, stmt.cond.type, &BOOL_TYPE)
            }

            // Then
            {
                old_scope := scope
                scope = stmt.scope
                defer scope = old_scope

                resolve_scope_decls(c)
                typecheck_statement_list(c, stmt.statements)
            }
            // Else
            if stmt.else_is_present
            {
                old_scope := scope
                scope = stmt.scope
                defer scope = old_scope
                resolve_scope_decls(c)

                if stmt.else_is_single {
                    typecheck_statement(c, stmt.else_single)
                } else {
                    typecheck_statement_list(c, stmt.else_multi_statements)
                }
            }
        }
        case ^Ast_For:
        {
            old_scope := scope
            scope = stmt.scope
            defer scope = old_scope

            if stmt.define != nil do typecheck_statement(c, stmt.define)
            if stmt.cond != nil   do typecheck_expr(c, stmt.cond)
            if stmt.iter != nil   do typecheck_statement(c, stmt.iter)
            typecheck_statement_list(c, stmt.statements)
        }
        case ^Ast_Break:
        {
        }
        case ^Ast_Continue:
        {
        }
        case ^Ast_Discard:
        {
        }
        case ^Ast_Return:
        {
            c.proc_ret = stmt

            typecheck_expr(c, stmt.expr)
            if !type_implicit_convert(stmt.expr.type, cur_proc.decl.type.ret) {
                typecheck_error_mismatching_types(c, stmt.token, stmt.expr.type, cur_proc.decl.type.ret)
            }
        }
    }
}

typecheck_statement_list :: proc(using c: ^Checker, stmts: []^Ast_Statement)
{
    for stmt in stmts {
        typecheck_statement(c, stmt)
    }
}

typecheck_expr :: proc(using c: ^Checker, expression: ^Ast_Expr)
{
    expression.type = &POISON_TYPE

    expr_switch: switch expr in expression.derived_expr
    {
        case ^Ast_Binary_Expr:
        {
            typecheck_expr(c, expr.lhs)
            typecheck_expr(c, expr.rhs)

            expr.type = bin_op_result_type(expr.op, expr.lhs.type, expr.rhs.type)
            if expr.type == &POISON_TYPE {
                typecheck_error_mismatching_types(c, expr.token, expr.lhs.type, expr.rhs.type)
            }
        }
        case ^Ast_Unary_Expr:
        {
            typecheck_expr(c, expr.expr)

            scratch, _ := acquire_scratch()

            expr.type = unary_op_result_type(expr.op, expr.expr.type)
            if expr.type == &POISON_TYPE {
                typecheck_error(c, expr.token, "Can't apply operator '%v' on type '%v'.", expr.token.text, type_to_string(expr.expr.type, arena = scratch))
            }
        }
        case ^Ast_Ident_Expr:
        {
            decl := decl_lookup(c, expr.token)
            if decl == nil {
                typecheck_error(c, expr.token, "Undeclared identifier '%v'.", expr.token.text)
            } else {
                expr.type = decl.type
                expr.glsl_name = decl.glsl_name
            }
        }
        case ^Ast_Lit_Expr:
        {
            if expr.token.type == .IntLit {
                expr.type = &UNTYPED_INT_TYPE
            } else if expr.token.type == .FloatLit {
                expr.type = &UNTYPED_FLOAT_TYPE
            } else if expr.token.type == .StrLit {
                expr.type = &STRING_TYPE
            } else if expr.token.type == .True {
                expr.type = &BOOL_TYPE
            } else if expr.token.type == .False {
                expr.type = &BOOL_TYPE
            }
        }
        case ^Ast_Member_Access:
        {
            typecheck_expr(c, expr.target)

            if expr.member_name == "xyz"
            {
                expr.type = &VEC3_TYPE
                break
            }
            else if expr.member_name == "xy"
            {
                expr.type = &VEC2_TYPE
                break
            }
            else if expr.member_name == "x"
            {
                expr.type = &FLOAT_TYPE
                break
            }
            else if expr.member_name == "y"
            {
                expr.type = &FLOAT_TYPE
                break
            }
            else if expr.member_name == "z"
            {
                expr.type = &FLOAT_TYPE
                break
            }
            else if expr.member_name == "w"
            {
                expr.type = &FLOAT_TYPE
                break
            }

            base := type_get_base(expr.target.type)
            if base.kind != .Struct {
                typecheck_error(c, expr.token, "Can't access members on this type.")
            }

            field_type := &POISON_TYPE
            for field in base.members
            {
                if field.name == expr.member_name
                {
                    field_type = field.type
                    break
                }
            }

            if field_type == &POISON_TYPE {
                typecheck_error(c, expr.token, "Member '%v' not found.", expr.member_name)
            }

            expr.type = field_type
        }
        case ^Ast_Array_Access:
        {
            typecheck_expr(c, expr.target)
            typecheck_expr(c, expr.idx_expr)

            if expr.target.type.kind != .Slice {
                typecheck_error(c, expr.token, "Can't access array element of this type, it must be a slice.")
                expr.target.type = &POISON_TYPE
            }

            expr.type = expr.target.type.base
        }
        case ^Ast_Call:
        {
            for arg in expr.args {
                typecheck_expr(c, arg)
            }

            // Handle intrinsics
            target, is_ident := expr.target.derived_expr.(^Ast_Ident_Expr)
            if is_ident
            {
                // Try to resolve intrinsic overloads
                for intr in INTRINSICS
                {
                    if intr.name == target.token.text && intr.type.kind == .Proc
                    {
                        arg_count_matches := len(intr.type.args) == len(expr.args)
                        arg_count_matches |= intr.type.is_variadic && len(expr.args) >= len(intr.type.args)
                        if arg_count_matches
                        {
                            match := true
                            for i in 0..<len(intr.type.args)
                            {
                                arg := expr.args[i]
                                if !type_implicit_convert(arg.type, intr.type.args[i].type)
                                {
                                    match = false
                                    break
                                }
                            }

                            if match
                            {
                                expr.target.type = intr.type
                                expr.type = intr.type.ret

                                if target.token.text == "rayquery_init" ||
                                   target.token.text == "rayquery_proceed" ||
                                   target.token.text == "rayquery_candidate" ||
                                   target.token.text == "rayquery_accept" ||
                                   target.token.text == "rayquery_result" {
                                    ast.used_features += { .Raytracing }
                                }

                                if target.token.text == "printf"
                                {
                                    if !check_printf(c, expr) {
                                        return
                                    }
                                }

                                expr.glsl_name = intr.glsl_name
                                break expr_switch
                            }
                        }
                    }
                }
            }

            // Regular procedure calls

            typecheck_expr(c, expr.target)
            if expr.target.type.kind != .Proc {
                typecheck_error(c, expr.token, "Can't call this type, must be a procedure.")
            }

            if len(expr.target.type.args) != len(expr.args) {
                typecheck_error(c, expr.token, "Incorrect number of arguments, expecting '%v', got '%v'.", len(expr.target.type.args), len(expr.args))
                break
            }

            for arg, i in expr.args
            {
                proc_decl_arg_type := expr.target.type.args[i].type

                typecheck_expr(c, arg)

                if !type_implicit_convert(arg.type, proc_decl_arg_type) {
                    typecheck_error_mismatching_types(c, arg.token, arg.type, proc_decl_arg_type)
                }
            }

            expr.type = expr.target.type.ret
        }
    }
}

POISON_TYPE := Ast_Type { kind = .Poison }
FLOAT_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Float, name = { text = "float", line = {}, type = {}, col_start = {} } }
UINT_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Uint, name = { text = "uint", line = {}, type = {}, col_start = {} } }
UNTYPED_FLOAT_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Untyped_Float, name = { text = "untyped float", line = {}, type = {}, col_start = {} } }
UNTYPED_INT_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Untyped_Int, name = { text = "untyped int", line = {}, type = {}, col_start = {} } }
INT_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Int, name = { text = "int", line = {}, type = {}, col_start = {} } }
VEC2_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vec2, name = { text = "vec2", line = 0, type = {}, col_start = {} } }
VEC3_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vec3, name = { text = "vec3", line = 0, type = {}, col_start = {} } }
VEC4_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vec4, name = { text = "vec4", line = 0, type = {}, col_start = {} } }
BOOL_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Bool, name = { text = "bool", line = 0, type = {}, col_start = {} } }
TEXTUREID_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Texture_ID, name = { text = "textureid", line = {}, type = {}, col_start = {} } }
SAMPLERID_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Sampler_ID, name = { text = "samplerid", line = {}, type = {}, col_start = {} } }
BVH_ID_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .BVH_ID, name = { text = "bvh_id", line = {}, type = {}, col_start = {} } }
MAT4_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Mat4, name = { text = "mat4", line = 0, type = {}, col_start = {} } }
STRING_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .String, name = { text = "string", line = 0, type = {}, col_start = {} } }
RAYQUERY_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Ray_Query, name = { text = "Ray_Query", line = {}, type = {}, col_start = {} } }

same_type :: proc(type1: ^Ast_Type, type2: ^Ast_Type) -> bool
{
    if type1.kind == .Poison || type2.kind == .Poison do return false
    if type1 == nil || type2 == nil do return false
    if type1.kind != type2.kind do return false
    if type1.primitive_kind != type2.primitive_kind do return false
    if type1.name.text != type2.name.text do return false

    has_base := type1.kind != .Primitive && type1.kind != .Label
    if has_base && !same_type(type1.base, type2.base) do return false
    return true
}

type_get_base :: proc(type: ^Ast_Type) -> ^Ast_Type
{
    if type.kind == .Poison do return &POISON_TYPE
    if type.base == nil do return type
    return type_get_base(type.base)
}

decl_lookup :: proc(using c: ^Checker, token: Token) -> ^Ast_Decl
{
    cur_scope := scope
    for cur_scope != nil
    {
        is_global_scope := cur_scope.enclosing_scope == nil

        for decl in cur_scope.decls
        {
            ignore_order := is_global_scope || decl.type.kind == .Struct || decl.type.kind == .Proc
            if !ignore_order && raw_data(decl.token.text) > raw_data(token.text) {
                continue
            }
            if decl.name == token.text do return decl
        }

        cur_scope = cur_scope.enclosing_scope
    }

    for intr in INTRINSICS
    {
        ignore_order := intr.type.kind == .Struct || intr.type.kind == .Proc
        if !ignore_order && raw_data(intr.token.text) > raw_data(token.text) {
            continue
        }
        if intr.name == token.text do return intr
    }

    return nil
}

resolve_type :: proc(using c: ^Checker, type: ^Ast_Type)
{
    base := type_get_base(type)
    if base.kind == .Label
    {
        type_decl := decl_lookup(c, base.name)
        if type_decl == nil {
            typecheck_error(c, base.name, "Undeclared identifier '%v'.", base.name.text)
        } else {
            base.base = type_decl.type
        }
    }
}

typecheck_error :: proc(using c: ^Checker, token: Token, fmt_str: string, args: ..any)
{
    if error do return

    error_msg(input_path, token, fmt_str, ..args)
    error = true
}

typecheck_error_mismatching_types :: proc(using c: ^Checker, token: Token, type1: ^Ast_Type, type2: ^Ast_Type)
{
    if error do return

    scratch, _ := acquire_scratch()
    type1_str := type_to_string(type1, arena = scratch)
    type2_str := type_to_string(type2, arena = scratch)
    error_msg(input_path, token, "Incompatible types: '%v' and '%v'", type1_str, type2_str)
    error = true
}

typecheck_error_redeclaration :: proc(using c: ^Checker, decl_before: ^Ast_Decl, decl_after: ^Ast_Decl)
{
    if error do return

    error_msg(input_path, decl_after.token, "Redeclaration of '%v' in this scope.", decl_after.name)
    error = true
}

INTRINSICS: [dynamic]^Ast_Decl

// TODO: These should all just be declared in a .musl file.
add_intrinsics :: proc()
{
    // Resource access
    add_intrinsic("texture_sample", { &TEXTUREID_TYPE, &SAMPLERID_TYPE, &VEC2_TYPE }, { "tex_idx", "sampler_idx", "uv" }, &VEC4_TYPE)
    add_intrinsic("texture_store", { &TEXTUREID_TYPE, &VEC2_TYPE, &VEC4_TYPE }, { "tex_idx", "coord", "value" }, nil)
    add_intrinsic("texture_load", { &TEXTUREID_TYPE, &VEC2_TYPE }, { "tex_idx", "coord" }, &VEC4_TYPE)

    // Raytracing
    ray_result_type := add_intrinsic_struct("Ray_Result", { &UINT_TYPE, &FLOAT_TYPE, &UINT_TYPE, &UINT_TYPE, &VEC2_TYPE, &BOOL_TYPE, &MAT4_TYPE, &MAT4_TYPE }, { "kind", "t", "instance_idx", "primitive_idx", "barycentrics", "front_face", "object_to_world", "world_to_object" })
    ray_desc_type := add_intrinsic_struct("Ray_Desc", { &UINT_TYPE, &UINT_TYPE, &FLOAT_TYPE, &FLOAT_TYPE, &VEC3_TYPE, &VEC3_TYPE }, { "flags", "cull_mask", "t_min", "t_max", "origin", "dir" })
    add_intrinsic("rayquery_init", { ray_desc_type, &BVH_ID_TYPE }, { "desc", "bvh" }, &RAYQUERY_TYPE)
    add_intrinsic("rayquery_proceed", { &RAYQUERY_TYPE }, { "rq" }, &BOOL_TYPE)
    add_intrinsic("rayquery_candidate", { &RAYQUERY_TYPE }, { "rq" }, ray_result_type)
    add_intrinsic("rayquery_accept", { &RAYQUERY_TYPE }, { "rq" }, nil)
    add_intrinsic("rayquery_result", { &RAYQUERY_TYPE }, { "rq" }, ray_result_type)

    // Conversion
    add_intrinsic("float_bits_to_int", { &FLOAT_TYPE }, { "x" }, &UINT_TYPE, glsl_name = "floatBitsToInt")

    // Constructors
    add_intrinsic("uint", { &FLOAT_TYPE }, { "x" }, &UINT_TYPE)
    add_intrinsic("int", { &FLOAT_TYPE }, { "x" }, &INT_TYPE)
    add_intrinsic("float", { &INT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("float", { &UINT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("float", { &BOOL_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("vec2", { &FLOAT_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("vec2", { &FLOAT_TYPE, &FLOAT_TYPE }, { "x", "y" }, &VEC2_TYPE)
    add_intrinsic("vec2", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("vec3", { &FLOAT_TYPE, &FLOAT_TYPE, &FLOAT_TYPE }, { "x", "y", "z" }, &VEC3_TYPE)
    add_intrinsic("vec3", { &VEC2_TYPE, &FLOAT_TYPE }, { "x", "y" }, &VEC3_TYPE)
    add_intrinsic("vec3", { &FLOAT_TYPE, &VEC2_TYPE }, { "x", "y" }, &VEC3_TYPE)
    add_intrinsic("vec3", { &FLOAT_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("vec3", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("vec4", { &FLOAT_TYPE, &FLOAT_TYPE, &FLOAT_TYPE, &FLOAT_TYPE }, { "x", "y", "z", "w" }, &VEC4_TYPE)
    add_intrinsic("vec4", { &VEC3_TYPE, &FLOAT_TYPE }, { "x", "y" }, &VEC4_TYPE)
    add_intrinsic("vec4", { &FLOAT_TYPE, &VEC3_TYPE }, { "x", "y" }, &VEC4_TYPE)
    add_intrinsic("vec4", { &VEC2_TYPE, &VEC2_TYPE }, { "x", "y" }, &VEC4_TYPE)
    add_intrinsic("vec4", { &FLOAT_TYPE, &FLOAT_TYPE, &VEC2_TYPE }, { "x", "y", "z" }, &VEC4_TYPE)
    add_intrinsic("vec4", { &VEC2_TYPE, &FLOAT_TYPE, &FLOAT_TYPE }, { "x", "y", "z" }, &VEC4_TYPE)
    add_intrinsic("vec4", { &FLOAT_TYPE, &VEC2_TYPE, &FLOAT_TYPE }, { "x", "y", "z" }, &VEC4_TYPE)
    add_intrinsic("vec4", { &FLOAT_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("mat4", { &VEC4_TYPE, &VEC4_TYPE, &VEC4_TYPE, &VEC4_TYPE }, { "x", "y", "z", "w" }, &MAT4_TYPE)

    // Math functions - these work on float, vec2, vec3, vec4 (component-wise)
    add_intrinsic("pow", { &FLOAT_TYPE, &FLOAT_TYPE }, { "x", "y" }, &FLOAT_TYPE)
    add_intrinsic("pow", { &VEC2_TYPE, &VEC2_TYPE }, { "x", "y" }, &VEC2_TYPE)
    add_intrinsic("pow", { &VEC3_TYPE, &VEC3_TYPE }, { "x", "y" }, &VEC3_TYPE)
    add_intrinsic("pow", { &VEC4_TYPE, &VEC4_TYPE }, { "x", "y" }, &VEC4_TYPE)
    add_intrinsic("sqrt", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("sqrt", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("sqrt", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("sqrt", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("sin", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("sin", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("sin", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("sin", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("cos", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("cos", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("cos", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("cos", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("acos", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("acos", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("acos", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("acos", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("tan", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("tan", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("tan", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("tan", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("atan", { &FLOAT_TYPE, &FLOAT_TYPE }, { "x", "y" }, &FLOAT_TYPE)
    add_intrinsic("atan", { &VEC2_TYPE, &VEC2_TYPE }, { "x", "y" }, &VEC2_TYPE)
    add_intrinsic("atan", { &VEC3_TYPE, &VEC3_TYPE }, { "x", "y" }, &VEC3_TYPE)
    add_intrinsic("atan", { &VEC4_TYPE, &VEC4_TYPE }, { "x", "y" }, &VEC4_TYPE)
    add_intrinsic("tanh", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("tanh", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("tanh", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("tanh", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("fract", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("fract", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("fract", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("fract", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("abs", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("abs", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("abs", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("abs", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("dot", { &VEC2_TYPE, &VEC2_TYPE }, { "a", "b" }, &FLOAT_TYPE)
    add_intrinsic("dot", { &VEC3_TYPE, &VEC3_TYPE }, { "a", "b" }, &FLOAT_TYPE)
    add_intrinsic("dot", { &VEC4_TYPE, &VEC4_TYPE }, { "a", "b" }, &FLOAT_TYPE)
    add_intrinsic("length", { &VEC2_TYPE }, { "v" }, &FLOAT_TYPE)
    add_intrinsic("length", { &VEC3_TYPE }, { "v" }, &FLOAT_TYPE)
    add_intrinsic("length", { &VEC4_TYPE }, { "v" }, &FLOAT_TYPE)
    add_intrinsic("min", { &FLOAT_TYPE, &FLOAT_TYPE }, { "a", "b" }, &FLOAT_TYPE)
    add_intrinsic("min", { &VEC2_TYPE, &VEC2_TYPE }, { "a", "b" }, &VEC2_TYPE)
    add_intrinsic("min", { &VEC3_TYPE, &VEC3_TYPE }, { "a", "b" }, &VEC3_TYPE)
    add_intrinsic("min", { &VEC4_TYPE, &VEC4_TYPE }, { "a", "b" }, &VEC4_TYPE)
    add_intrinsic("max", { &FLOAT_TYPE, &FLOAT_TYPE }, { "a", "b" }, &FLOAT_TYPE)
    add_intrinsic("max", { &VEC2_TYPE, &VEC2_TYPE }, { "a", "b" }, &VEC2_TYPE)
    add_intrinsic("max", { &VEC3_TYPE, &VEC3_TYPE }, { "a", "b" }, &VEC3_TYPE)
    add_intrinsic("max", { &VEC4_TYPE, &VEC4_TYPE }, { "a", "b" }, &VEC4_TYPE)
    add_intrinsic("normalize", { &VEC2_TYPE }, { "v" }, &VEC2_TYPE)
    add_intrinsic("normalize", { &VEC3_TYPE }, { "v" }, &VEC3_TYPE)
    add_intrinsic("normalize", { &VEC4_TYPE }, { "v" }, &VEC4_TYPE)
    add_intrinsic("mix", { &FLOAT_TYPE, &FLOAT_TYPE, &FLOAT_TYPE }, { "a", "b", "t" }, &FLOAT_TYPE)
    add_intrinsic("mix", { &VEC2_TYPE, &VEC2_TYPE, &VEC2_TYPE }, { "a", "b", "t" }, &VEC2_TYPE)
    add_intrinsic("mix", { &VEC3_TYPE, &VEC3_TYPE, &VEC3_TYPE }, { "a", "b", "t" }, &VEC3_TYPE)
    add_intrinsic("mix", { &VEC4_TYPE, &VEC4_TYPE, &VEC4_TYPE }, { "a", "b", "t" }, &VEC4_TYPE)
    add_intrinsic("clamp", { &FLOAT_TYPE, &FLOAT_TYPE, &FLOAT_TYPE }, { "a", "b", "t" }, &FLOAT_TYPE)
    add_intrinsic("clamp", { &VEC2_TYPE, &VEC2_TYPE, &VEC2_TYPE }, { "a", "b", "t" }, &VEC2_TYPE)
    add_intrinsic("clamp", { &VEC3_TYPE, &VEC3_TYPE, &VEC3_TYPE }, { "a", "b", "t" }, &VEC3_TYPE)
    add_intrinsic("clamp", { &VEC4_TYPE, &VEC4_TYPE, &VEC4_TYPE }, { "a", "b", "t" }, &VEC4_TYPE)
    add_intrinsic("dfdx_coarse", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE, glsl_name = "dFdxCoarse")
    add_intrinsic("dfdx_coarse", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE, glsl_name = "dFdxCoarse")
    add_intrinsic("dfdx_coarse", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE, glsl_name = "dFdxCoarse")
    add_intrinsic("dfdx_coarse", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE, glsl_name = "dFdxCoarse")
    add_intrinsic("dfdx_fine", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE, glsl_name = "dFdxFine")
    add_intrinsic("dfdx_fine", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE, glsl_name = "dFdxFine")
    add_intrinsic("dfdx_fine", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE, glsl_name = "dFdxFine")
    add_intrinsic("dfdx_fine", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE, glsl_name = "dFdxFine")
    add_intrinsic("dfdy_coarse", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE, glsl_name = "dFdyCoarse")
    add_intrinsic("dfdy_coarse", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE, glsl_name = "dFdyCoarse")
    add_intrinsic("dfdy_coarse", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE, glsl_name = "dFdyCoarse")
    add_intrinsic("dfdy_coarse", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE, glsl_name = "dFdyCoarse")
    add_intrinsic("dfdy_fine", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE, glsl_name = "dFdyFine")
    add_intrinsic("dfdy_fine", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE, glsl_name = "dFdyFine")
    add_intrinsic("dfdy_fine", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE, glsl_name = "dFdyFine")
    add_intrinsic("dfdy_fine", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE, glsl_name = "dFdyFine")

    // Matrix manipulation
    add_intrinsic("transpose", { &MAT4_TYPE }, { "m" }, &MAT4_TYPE)

    // Misc
    add_intrinsic("printf", { &STRING_TYPE }, { "fmt" }, is_variadic = true)
}

add_intrinsic :: proc(name: string, args: []^Ast_Type, names: []string, ret: ^Ast_Type = nil, glsl_name := "", is_variadic := false)
{
    assert(len(args) == len(names))

    arg_decls := make([]^Ast_Decl, len(args))
    for &arg, i in arg_decls
    {
        arg = new(Ast_Decl)
        arg.type = args[i]
        arg.name = names[i]
    }

    decl := new(Ast_Decl)
    decl.name = name
    decl.type = new(Ast_Type)
    decl.type.kind = .Proc
    decl.type.args = arg_decls
    decl.type.ret = ret
    decl.type.is_variadic = is_variadic
    decl.glsl_name = glsl_name
    append(&INTRINSICS, decl)
}

add_intrinsic_struct :: proc(name: string, members: []^Ast_Type, names: []string) -> ^Ast_Type
{
    assert(len(members) == len(names))

    member_decls := make([]^Ast_Decl, len(members))
    for &member, i in member_decls
    {
        member = new(Ast_Decl)
        member.type = members[i]
        member.name = names[i]
    }

    decl := new(Ast_Decl)
    decl.name = name
    decl.type = new(Ast_Type)
    decl.type.kind = .Struct
    decl.type.members = member_decls
    append(&INTRINSICS, decl)

    label_type := new(Ast_Type)
    label_type.kind = .Label
    label_type.name = { text = name, type = .Ident, col_start = 0, line = 0 }
    label_type.base = decl.type
    return label_type
}

// Returns &POISON_TYPE if the two types are not allowed
bin_op_result_type :: proc(op: Ast_Binary_Op, type1: ^Ast_Type, type2: ^Ast_Type) -> ^Ast_Type
{
    if op == .Mul && type1.primitive_kind == .Mat4
    {
        if type2.primitive_kind == .Vec4 do return &VEC4_TYPE
    }
    else if op == .Mul && type1.primitive_kind == .Vec4
    {
        if type2.primitive_kind == .Mat4 do return &VEC4_TYPE
    }

    is_bit_manip := op == .Bitwise_And ||
                  op == .Bitwise_Or ||
                  op == .Bitwise_Xor ||
                  op == .LShift ||
                  op == .RShift
    if is_bit_manip
    {
        if type_implicit_convert(type1, &UINT_TYPE) && type_implicit_convert(type2, &UINT_TYPE) do return &UINT_TYPE
        if type_implicit_convert(type1, &INT_TYPE) && type_implicit_convert(type2, &INT_TYPE) do return &INT_TYPE
        return &POISON_TYPE
    }

    is_compare := op == .Greater ||
                  op == .Less ||
                  op == .LE ||
                  op == .GE ||
                  op == .EQ ||
                  op == .NEQ
    if is_compare
    {
        if type_implicit_convert(type1, type2) || type_implicit_convert(type2, type1) do return &BOOL_TYPE
        else do return &POISON_TYPE
    }

    // Commutative properties here.
    for i in 0..<2
    {
        t1 := type1 if i == 0 else type2
        t2 := type2 if i == 0 else type1

        if (t1.primitive_kind == .Untyped_Float || t1.primitive_kind == .Untyped_Int) && t2.primitive_kind == .Float {
            return t2
        }
        if t1.primitive_kind == .Untyped_Int && (t2.primitive_kind == .Uint || t2.primitive_kind == .Int) {
            return t2
        }
        if type_implicit_convert(t1, &FLOAT_TYPE) && t2.primitive_kind == .Vec2 {
            return t2
        }
        if type_implicit_convert(t1, &FLOAT_TYPE) && t2.primitive_kind == .Vec3 {
            return t2
        }
        if type_implicit_convert(t1, &FLOAT_TYPE) && t2.primitive_kind == .Vec4 {
            return t2
        }
    }

    if same_type(type1, type2) do return type1
    return &POISON_TYPE
}

unary_op_result_type :: proc(op: Ast_Unary_Op, type: ^Ast_Type) -> ^Ast_Type
{
    is_boolean := op == .Not
    if is_boolean
    {
        if type_implicit_convert(type, &BOOL_TYPE) do return &BOOL_TYPE
    }

    is_arithmetic := op == .Minus || op == .Plus
    if is_arithmetic
    {
        if type_implicit_convert(type, &INT_TYPE) do return &INT_TYPE
        if type_implicit_convert(type, &UINT_TYPE) do return &UINT_TYPE
        if type_implicit_convert(type, &FLOAT_TYPE) do return &FLOAT_TYPE
        if type_implicit_convert(type, &VEC2_TYPE) do return &VEC2_TYPE
        if type_implicit_convert(type, &VEC3_TYPE) do return &VEC3_TYPE
        if type_implicit_convert(type, &VEC4_TYPE) do return &VEC4_TYPE
    }

    return &POISON_TYPE
}

// Returns true if "from" is implicitly convertible to "to"
type_implicit_convert :: proc(from: ^Ast_Type, to: ^Ast_Type) -> bool
{
    if (from.primitive_kind == .Untyped_Float || from.primitive_kind == .Untyped_Int) && to.primitive_kind == .Float {
        return true
    }
    if from.primitive_kind == .Untyped_Int && (to.primitive_kind == .Uint || to.primitive_kind == .Int) {
        return true
    }

    to_is_resource_id := to.primitive_kind == .Texture_ID || to.primitive_kind == .Sampler_ID || to.primitive_kind == .BVH_ID

    if from.primitive_kind == .Untyped_Int && to_is_resource_id {
        return true
    }

    return same_type(from, to)
}

resolve_scope_decls :: proc(using c: ^Checker)
{
    for decl in scope.decls
    {
        decl.glsl_name = ident_to_glsl(decl.name)
        resolve_type(c, decl.type)

        if decl.type.primitive_kind == .Ray_Query || decl.type.primitive_kind == .BVH_ID {
            ast.used_features += { .Raytracing }
        }

        for decl_2 in scope.decls
        {
            if decl_2.name == decl.name && raw_data(decl_2.token.text) < raw_data(decl.token.text)
            {
                typecheck_error_redeclaration(c, decl_2, decl)
                break
            }
        }
    }
}

check_printf :: proc(using c: ^Checker, call: ^Ast_Call) -> bool
{
    args := call.args
    fmt_str: string
    #partial switch arg in args[0].derived_expr
    {
        case ^Ast_Lit_Expr:
        {
            if args[0].type.primitive_kind != .String
            {
                typecheck_error(c, call.token, "First argument of printf must be a constant string.")
                return false
            }

            fmt_str = args[0].token.text
        }
        case:
        {
            typecheck_error(c, call.token, "First argument of printf must be a constant string.")
            return false
        }
    }

    fmt_arg_count := 0
    for c in fmt_str
    {
        // Add escape for '%'.
        if c == '%' {
            fmt_arg_count += 1
        }
    }

    if fmt_arg_count + 1 != len(call.args)
    {
        if fmt_arg_count == 1 {
            typecheck_error(c, call.token, "printf format string specifies %v argument, supplied %v.", fmt_arg_count, len(call.args) - 1)
        } else {
            typecheck_error(c, call.token, "printf format string specifies %v arguments, supplied %v.", fmt_arg_count, len(call.args) - 1)
        }
        return false
    }

    // TODO: Check for unallowed types in varargs.

    return true
}

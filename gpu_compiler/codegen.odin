
package main

import "core:fmt"
import vmem "core:mem/virtual"
import "core:strings"
import "base:runtime"
import "core:os/os2"

Shader_Type :: enum
{
    Vertex,
    Fragment,
    Compute
}

codegen :: proc(ast: Ast, shader_type: Shader_Type, input_path: string, output_path: string)
{
    writer.ast = ast
    writer.shader_type = shader_type

    write_preamble()

    arena_backing: vmem.Arena
    ok_a := vmem.arena_init_growing(&arena_backing)
    assert(ok_a == nil)
    codegen_arena := vmem.arena_allocator(&arena_backing)
    defer free_all(codegen_arena)

    context.allocator = codegen_arena

    for loc, &type in ast.used_out_locations {
        writefln("layout(location = %v) out %v _res_out_loc%v_;", loc, type_to_glsl(&type), loc)
    }
    for loc, &type in ast.used_in_locations {
        writefln("layout(location = %v) in %v _res_in_loc%v_;", loc, type_to_glsl(&type), loc)
    }

    writeln("")

    writefln("layout(buffer_reference) readonly buffer _res_ptr_void;")
    for &type in ast.used_types
    {
        if type.kind == .Pointer || type.kind == .Slice {
            writefln("layout(buffer_reference) readonly buffer %v;", type_to_glsl(&type))
        }
    }

    writeln("")

    // Generate all struct decls first (functions might use some of these structs) (can't forward-declare structs in GLSL)
    for decl in ast.scope.decls
    {
        #partial switch decl.type.kind
        {
            case .Struct:
            {
                writefln("struct %v", decl.name)
                writeln("{")
                if writer_scope()
                {
                    for field in decl.type.members
                    {
                        writefln("%v %v;", type_to_glsl(field.type), field.name)
                    }
                }
                writeln("};")
                writefln("%v %v_ZERO;", decl.name, decl.name)
            }
        }
    }

    // Generate all proc decls
    for decl in ast.scope.decls
    {
        #partial switch decl.type.kind
        {
            case .Proc:
            {
                is_main := decl.name == "main"

                write_begin("")
                ret_type_glsl := "void" if is_main else type_to_glsl(decl.type.ret)
                writef("%v %v(", ret_type_glsl, decl.name)
                for arg, i in decl.type.args
                {
                    if arg.attr != nil do continue

                    writef("%v %v", type_to_glsl(arg.type), arg.name)
                    if i < len(decl.type.args) - 1 {
                        write(", ")
                    }
                }
                writeln(");")
            }
        }
    }

    // Generate all global var decls
    for decl in ast.scope.decls
    {
        #partial switch decl.type.kind
        {
            case .Proc: {}
            case .Struct: {}
            case:
            {
                has_def := false
                for global in ast.global_vars
                {
                    if global.decl == decl
                    {
                        writef("%v %v", type_to_glsl(global.decl.type), global.decl.name)
                        write(" = ")
                        codegen_expr(global.expr)
                        writeln(";")

                        has_def = true
                        break
                    }
                }

                if !has_def
                {
                    writefln("%v %v;", type_to_glsl(decl.type), decl.name)
                }
            }
        }
    }


    writefln("layout(buffer_reference, scalar) readonly buffer _res_ptr_void {{ uint _res_void_; }};")
    for &type in ast.used_types
    {
        if type.kind == .Pointer {
            writefln("layout(buffer_reference, scalar) readonly buffer %v {{ %v _res_; }};", type_to_glsl(&type), type_to_glsl(type.base))
        }
        if type.kind == .Slice {
            writefln("layout(buffer_reference, scalar) readonly buffer %v {{ %v _res_[]; }};", type_to_glsl(&type), type_to_glsl(type.base))
        }
        // Prepare zero initialization for each used types
        if type.kind != .Primitive && type.kind != .Label {
            writefln("%v %v_ZERO;", type_to_glsl(&type), type_to_glsl_unique(&type))
        }
    }

    if ast.used_indirect_data_type != nil
    {
        assert(ast.used_indirect_data_type.kind == .Pointer)
        base := ast.used_indirect_data_type.base
        writefln("layout(buffer_reference, scalar) readonly buffer _res_indirect_array_%v {{ %v _res_[]; }};", type_to_glsl(base), type_to_glsl(base))
    }
    writeln("")

    // Generate bindings
    writeln("layout(set = 0, binding = 0) uniform texture2D _res_textures_[];")
    writeln("layout(set = 1, binding = 0) uniform image2D _res_textures_rw_[];")
    writeln("layout(set = 2, binding = 0) uniform sampler _res_samplers_[];")
    writeln("")

    indirect_data_type_glsl := "_res_ptr_void"
    if ast.used_indirect_data_type != nil {
        indirect_data_type_glsl = strings.concatenate({"_res_indirect_array_", type_to_glsl(ast.used_indirect_data_type.base)})
    }
    data_type_str := type_to_glsl(ast.used_data_type) if ast.used_data_type != nil else "_res_ptr_void"

    writeln("layout(push_constant, scalar) uniform Push")
    writeln("{")
    if writer_scope() {
        if shader_type == .Compute {
            writefln("%v _res_compute_data_;", data_type_str)
        } else {
            writefln("%v _res_vert_data_;", data_type_str)
            writefln("%v _res_frag_data_;", data_type_str)
            writefln("%v _res_indirect_data_;", indirect_data_type_glsl)
        }
    }
    writeln("};")
    writeln("")

    for proc_def in ast.procs
    {
        decl := proc_def.decl
        is_main := decl.name == "main"

        write_begin("")
        ret_type_glsl := "void" if is_main else type_to_glsl(decl.type.ret)
        writef("%v %v(", ret_type_glsl, decl.name)
        for arg, i in decl.type.args
        {
            if arg.attr != nil do continue

            arg.glsl_name = ident_to_glsl(arg.name)
            writef("%v %v", type_to_glsl(arg.type), arg.glsl_name)
            if i < len(decl.type.args) - 1 {
                write(", ")
            }
        }
        writeln(")")
        writeln("{")
        if writer_scope()
        {
            writer.proc_def = proc_def

            // Declare all variables
            for var_decl in proc_def.scope.decls
            {
                var_decl.glsl_name = ident_to_glsl(var_decl.name)

                // Skip function parameters without attributes - they're already declared in the signature
                if var_decl.attr == nil
                {
                    is_param := false
                    for param in proc_def.decl.type.args
                    {
                        if param.name == var_decl.name && param.attr == nil
                        {
                            is_param = true
                            break
                        }
                    }
                    if is_param do continue
                }

                if var_decl.attr == nil
                {
                    // It's not allowed to set rayquery objects like this, so we'll leave those uninitialized.
                    if var_decl.type.primitive_kind == .Ray_Query {
                        writefln("%v %v;", type_to_glsl(var_decl.type), var_decl.glsl_name)
                    } else {
                        writefln("%v %v = %v_ZERO;", type_to_glsl(var_decl.type), var_decl.glsl_name, type_to_glsl_unique(var_decl.type))
                    }
                }
                else
                {
                    attr_glsl := attribute_to_glsl(var_decl.attr.?, ast, shader_type)
                    if var_decl.attr.?.type == .Indirect_Data
                    {
                        // TODO: We just demote from pointer because on the GLSL side it's declared as value
                        var_decl.type^ = var_decl.type.base^
                    }

                    writefln("%v %v = %v;", type_to_glsl(var_decl.type), var_decl.glsl_name, attr_glsl)
                }
            }

            for statement in proc_def.statements
            {
                write_begin()
                codegen_statement(statement)
                write("\n")
            }
        }
        writeln("}")
        writeln("")
    }

    writer_output_to_file(output_path)
}

codegen_statement :: proc(statement: ^Ast_Statement, insert_semi := true)
{
    decl := writer.proc_def.decl
    is_main := decl.name == "main"
    ret_attr := decl.type.ret_attr

    switch stmt in statement.derived_statement
    {
        case ^Ast_Stmt_Expr:
        {
            codegen_expr(stmt.expr)
            if insert_semi do write(";")
        }
        case ^Ast_Assign:
        {
            // NOTE: In nosl we do rq := rayquery_init(...) but in GLSL we can't set the rayquery object.
            if stmt.lhs.type.primitive_kind == .Ray_Query
            {
                call, is_call := stmt.rhs.derived_expr.(^Ast_Call)
                if is_call
                {
                    call_ident, is_ident := call.target.derived_expr.(^Ast_Ident_Expr)
                    if is_ident
                    {
                        text := call_ident.token.text
                        if text == "rayquery_init"
                        {
                            write("rayquery(")
                            codegen_expr(stmt.lhs)
                            write(", ")
                            codegen_expr(call.args[0])
                            write(", ")
                            codegen_expr(call.args[1])
                            write(")")
                            if insert_semi do write(";")
                            break
                        }
                    }
                }
            }

            codegen_expr(stmt.lhs)
            writef(" %v ", stmt.token.text)
            codegen_expr(stmt.rhs)
            if insert_semi do write(";")
        }
        case ^Ast_Define_Var:
        {
            stmt.decl.glsl_name = ident_to_glsl(stmt.decl.name)

            // NOTE: In .nosl we do rq := rayquery_init(...) but in GLSL we can't set the rayquery object.
            if stmt.decl.type.primitive_kind == .Ray_Query
            {
                call, is_call := stmt.expr.derived_expr.(^Ast_Call)
                if is_call
                {
                    call_ident, is_ident := call.target.derived_expr.(^Ast_Ident_Expr)
                    if is_ident
                    {
                        text := call_ident.token.text
                        if text == "rayquery_init"
                        {
                            writef("rayquery_init(%v, ", stmt.decl.glsl_name)
                            codegen_expr(call.args[0])
                            write(", ")
                            codegen_expr(call.args[1])
                            write(")")
                            if insert_semi do write(";")
                            break
                        }
                    }
                }
            }

            write(stmt.decl.glsl_name)
            write(" = ")
            codegen_expr(stmt.expr)
            if insert_semi do write(";")
        }
        case ^Ast_If:
        {
            write("if(")
            codegen_expr(stmt.cond)
            write(")\n")
            writeln("{")
            if writer_scope()
            {
                codegen_scope_decls(stmt.scope)
                codegen_statement_list(stmt.statements)
            }
            writeln("}")
            if stmt.else_is_present
            {
                writeln("else")
                writeln("{")
                if writer_scope()
                {
                    codegen_scope_decls(stmt.else_scope)

                    if stmt.else_is_single
                    {
                        codegen_statement(stmt.else_single)
                    }
                    else
                    {
                        codegen_statement_list(stmt.else_multi_statements)
                        for else_stmt in stmt.else_multi_statements {
                            codegen_statement(else_stmt)
                        }
                    }
                }
                writeln("}")
            }
        }
        case ^Ast_For:
        {
            write("// for construct\n")
            writeln("{")
            if writer_scope()
            {
                codegen_scope_decls(stmt.scope)

                write_begin()
                writef("for(")
                if stmt.define != nil
                {
                    if stmt.define.decl.glsl_name != "" {
                        write(stmt.define.decl.glsl_name)
                    } else {
                        write(stmt.define.decl.name)
                    }
                    write(" = ")
                    codegen_expr(stmt.define.expr)
                }
                write("; ")
                if stmt.cond != nil do codegen_expr(stmt.cond)
                write("; ")
                if stmt.iter != nil do codegen_statement(stmt.iter, false)
                write(")\n")
                writeln("{")
                if writer_scope()
                {
                    codegen_statement_list(stmt.statements)
                }
                writeln("}")
            }
            writeln("}")
        }
        case ^Ast_Continue:
        {
            write("continue")
            if insert_semi do write(";")
        }
        case ^Ast_Break:
        {
            write("break")
            if insert_semi do write(";")
        }
        case ^Ast_Discard:
        {
            write("discard")
            if insert_semi do write(";")
        }
        case ^Ast_Return:
        {
            if is_main
            {
                type := stmt.expr.type
                if type.kind == .Label do type = type_get_base(type)

                if type.kind == .Struct
                {
                    for member in type.members
                    {
                        if member.attr == nil do continue
                        writef("%v = ", attribute_to_glsl(member.attr.?, writer.ast, writer.shader_type))
                        codegen_expr(stmt.expr)
                        writef(".%v; ", member.name)
                    }
                }
                else
                {
                    if ret_attr != nil && ret_attr.?.type == .Out_Loc
                    {
                        writef("%v = ", attribute_to_glsl(ret_attr.?, writer.ast, writer.shader_type))
                        codegen_expr(stmt.expr)
                        write(";")
                    }
                    else
                    {
                        panic("Not implemented!")
                    }
                }
            }
            else
            {
                write("return ")
                if stmt.expr != nil {
                    codegen_expr(stmt.expr)
                }
                write(";")
            }
        }
    }
}

codegen_statement_list :: proc(list: []^Ast_Statement)
{
    for block_stmt in list
    {
        write_begin()
        codegen_statement(block_stmt)
        write("\n")
    }
}

codegen_expr :: proc(expression: ^Ast_Expr)
{
    switch expr in expression.derived_expr
    {
        case ^Ast_Binary_Expr:
        {
            write("(")
            codegen_expr(expr.lhs)
            writef(" %v ", binary_op_to_glsl(expr.op))
            codegen_expr(expr.rhs)
            write(")")
        }
        case ^Ast_Unary_Expr:
        {
            write("(")
            write(unary_op_to_glsl(expr.op))
            codegen_expr(expr.expr)
            write(")")
        }
        case ^Ast_Ident_Expr:
        {
            if expr.glsl_name != "" {
                write(expr.glsl_name)
            } else {
                write(expr.token.text)
            }
        }
        case ^Ast_Lit_Expr:
        {
            write(expr.token.text)
        }
        case ^Ast_If_Expr:
        {
            write("(")
            codegen_expr(expr.cond_expr)
            write(") ? (")
            codegen_expr(expr.then_expr)
            write(") : (")
            codegen_expr(expr.else_expr)
            write(")")
        }
        case ^Ast_Cast:
        {
            writef("%v(", type_to_glsl(expr.cast_to))
            codegen_expr(expr.expr)
            write(")")
        }
        case ^Ast_Member_Access:
        {
            codegen_expr(expr.target)
            if expr.target.type.kind == .Pointer || expr.target.type.kind == .Slice {
                writef("._res_.%v", expr.member_name)
            } else {
                writef(".%v", expr.member_name)
            }
        }
        case ^Ast_Array_Access:
        {
            codegen_expr(expr.target)
            write("._res_[")
            codegen_expr(expr.idx_expr)
            write("]")
        }
        case ^Ast_Call:
        {
            // Check for intrinsics
            is_intrinsic := false
            call_ident, is_ident := expr.target.derived_expr.(^Ast_Ident_Expr)
            if is_ident
            {
                text := call_ident.token.text
                if text == "texture_sample"
                {
                    assert(len(expr.args) == 3)

                    write("texture(sampler2D(_res_textures_[nonuniformEXT(")
                    codegen_expr(expr.args[0])
                    write(")], _res_samplers_[nonuniformEXT(")
                    codegen_expr(expr.args[1])
                    write(")]), ")
                    codegen_expr(expr.args[2])
                    write(")")

                    is_intrinsic = true
                }
                else if text == "texture_store"
                {
                    assert(len(expr.args) == 3)

                    write("imageStore(_res_textures_rw_[nonuniformEXT(")
                    codegen_expr(expr.args[0])
                    write(")], ivec2(")
                    codegen_expr(expr.args[1])
                    write("), ")
                    codegen_expr(expr.args[2])
                    write(")")

                    is_intrinsic = true
                }
                else if text == "texture_load"
                {
                    assert(len(expr.args) == 2)

                    // For compute shaders, we can use direct indexing without nonuniformEXT
                    // since we're accessing by index from the data struct
                    write("imageLoad(_res_textures_rw_[nonuniformEXT(")
                    codegen_expr(expr.args[0])
                    write(")], ivec2(")
                    codegen_expr(expr.args[1])
                    write("))")

                    is_intrinsic = true
                }
                else if text == "printf"
                {
                    assert(len(expr.args) >= 1)

                    writef("debugPrintfEXT(\"%v\", ", printf_fmt_string_to_glsl(expr))
                    for arg, i in expr.args
                    {
                        if i == 0 do continue

                        codegen_expr(arg)
                        if i < len(expr.args) - 1 do write(", ")
                    }

                    write(")")

                    is_intrinsic = true
                }
            }

            if is_intrinsic do break

            if expr.glsl_name != "" {
                write(expr.glsl_name)
            } else {
                codegen_expr(expr.target)
            }
            write("(")
            for arg, i in expr.args
            {
                codegen_expr(arg)
                if i < len(expr.args) - 1 {
                    write(", ")
                }
            }
            write(")")
        }
    }
}

type_to_glsl :: proc(type: ^Ast_Type) -> string
{
    if type == nil do return "void"

    switch type.kind
    {
        case .Poison: return "<POISON>"
        case .None: return "void"
        case .Unknown: return "<UNKNOWN>"
        case .Label: return type.name.text
        case .Pointer: return strings.concatenate({ "_res_ptr_", type_to_glsl(type.base) })
        case .Slice: return strings.concatenate({ "_res_slice_", type_to_glsl(type.base) })
        case .Proc: panic("Translating proc type is not implemented.")
        case .Struct: panic("Translating struct type is not implemented.")
        case .Primitive:
        {
            switch type.primitive_kind
            {
                case .None: return "NONE"
                case .Untyped_Int: panic("Untyped int is not supposed to reach this stage.")
                case .Untyped_Float: panic("Untyped float is not supposed to reach this stage.")
                case .String: panic("String is not supposed to reach this stage.")
                case .Bool: return "bool"
                case .Float: return "float"
                case .Uint: return "uint"
                case .Int: return "int"
                case .Vec2: return "vec2"
                case .Vec3: return "vec3"
                case .Vec4: return "vec4"
                case .Texture_ID: return "uint"
                case .Sampler_ID: return "uint"
                case .Mat4: return "mat4"
                case .Ray_Query: return "rayQueryEXT"
                case .BVH_ID: return "uint"
            }
        }
    }
    return ""
}

// Used to get a glsl valid identifier for a type. (e.g. zero initialization)
type_to_glsl_unique :: proc(type: ^Ast_Type) -> string
{
    if type == nil do return "void"

    switch type.kind
    {
        case .Poison: return "<POISON>"
        case .None: return "void"
        case .Unknown: return "<UNKNOWN>"
        case .Label: return type.name.text
        case .Pointer: return strings.concatenate({ "_res_ptr_", type_to_glsl(type.base) })
        case .Slice: return strings.concatenate({ "_res_slice_", type_to_glsl(type.base) })
        case .Proc: panic("Translating proc type is not implemented.")
        case .Struct: panic("Translating struct type is not implemented.")
        case .Primitive:
        {
            switch type.primitive_kind
            {
                case .None: return "NONE"
                case .Untyped_Int: panic("Untyped int is not supposed to reach this stage.")
                case .Untyped_Float: panic("Untyped float is not supposed to reach this stage.")
                case .String: panic("String is not supposed to reach this stage.")
                case .Bool: return "bool"
                case .Float: return "float"
                case .Uint: return "uint"
                case .Int: return "int"
                case .Vec2: return "vec2"
                case .Vec3: return "vec3"
                case .Vec4: return "vec4"
                case .Texture_ID: return "texture_id"
                case .Sampler_ID: return "sampler_id"
                case .Mat4: return "mat4"
                case .Ray_Query: return "rayQueryEXT"
                case .BVH_ID: return "bvh_id"
            }
        }
    }
    return ""
}

binary_op_to_glsl :: proc(op: Ast_Binary_Op) -> string
{
    switch op
    {
        case .Add:         return "+"
        case .Minus:       return "-"
        case .Mul:         return "*"
        case .Div:         return "/"
        case .Bitwise_And: return "&"
        case .Bitwise_Or:  return "|"
        case .Bitwise_Xor: return "^"
        case .LShift:      return "<<"
        case .RShift:      return ">>"
        case .And:         return "&&"
        case .Or:          return "||"
        case .Greater:     return ">"
        case .Less:        return "<"
        case .LE:          return "<="
        case .GE:          return ">="
        case .EQ:          return "=="
        case .NEQ:         return "!="
    }
    return ""
}

unary_op_to_glsl :: proc(op: Ast_Unary_Op) -> string
{
    switch op
    {
        case .Not:   return "!"
        case .Plus:  return "+"
        case .Minus: return "-"
    }
    return ""
}

attribute_to_glsl :: proc(attribute: Ast_Attribute, ast: Ast, shader_type: Shader_Type) -> string
{
    val_str := runtime.cstring_to_string(fmt.caprint(attribute.arg, allocator = context.allocator))

    switch attribute.type
    {
        case .Vert_ID:       return "gl_VertexIndex"
        case .Position:     return "gl_Position"
        case .Data:
            // Data comes from push constants: _res_vert_data_ for vertex shader, _res_frag_data_ for fragment shader, _res_compute_data_ for compute shader
            if shader_type == .Vertex {
                return "_res_vert_data_"
            } else if shader_type == .Fragment {
                return "_res_frag_data_"
            } else {
                return "_res_compute_data_"
            }
        case .Instance_ID:  return "gl_InstanceID"
        case .Draw_ID:       return "gl_DrawID"
        case .Indirect_Data: return "_res_indirect_data_._res_[gl_DrawID]"
        case .Workgroup_ID: return "gl_WorkGroupID"
        case .Local_Invocation_ID: return "gl_LocalInvocationID"
        case .Group_Size: return "gl_WorkGroupSize"
        case .Global_Invocation_ID: return "gl_GlobalInvocationID"
        case .Out_Loc:  return strings.concatenate({"_res_out_loc", val_str, "_"})
        case .In_Loc:   return strings.concatenate({"_res_in_loc", val_str, "_"})
    }

    return {}
}

printf_fmt_string_to_glsl :: proc(call: ^Ast_Call) -> string
{
    scratch, _ := acquire_scratch()
    sb := strings.builder_make_none(allocator = scratch)

    vararg_idx := 0
    for c in call.args[0].token.text
    {
        if c == '%'
        {
            arg_type := call.args[vararg_idx+1].type.primitive_kind
            if arg_type == .Int {
                strings.write_string(&sb, "%d")
            } else if arg_type == .Uint {
                strings.write_string(&sb, "%u")
            } else if arg_type == .Float {
                strings.write_string(&sb, "%f")
            } else {
                panic("Type not supported for printf")
            }

            vararg_idx += 1
        }
        else do strings.write_rune(&sb, c)
    }

    return strings.clone(strings.to_string(sb))
}

ident_to_glsl :: proc(ident: string) -> string
{
    scratch, _ := acquire_scratch()
    sb := strings.builder_make_none(allocator = scratch)
    strings.write_string(&sb, ident)
    strings.write_rune(&sb, '_')
    return strings.clone(strings.to_string(sb))
}

codegen_scope_decls :: proc(scope: ^Ast_Scope)
{
    for decl in scope.decls {
        writefln("%v %v;", type_to_glsl(decl.type), ident_to_glsl(decl.name))
    }
}

Writer :: struct
{
    indentation: u32,
    builder: strings.Builder,
    ast: Ast,
    proc_def: ^Ast_Proc_Def,
    shader_type: Shader_Type,
}

@(private="file")
writer: Writer

@(deferred_in = writer_scope_end)
writer_scope :: proc() -> bool
{
    writer_scope_begin()
    return true
}

@(private="file")
writer_scope_begin :: proc()
{
    writer.indentation += 1
}

@(private="file")
writer_scope_end :: proc()
{
    writer.indentation -= 1
}

@(private="file")
write_preamble :: proc()
{
    writeln("#version 460")
    writeln("#extension GL_EXT_buffer_reference : require")
    writeln("#extension GL_EXT_buffer_reference2 : require")
    writeln("#extension GL_EXT_nonuniform_qualifier : require")
    writeln("#extension GL_EXT_scalar_block_layout : require")
    writeln("#extension GL_EXT_shader_image_load_formatted : require")
    writeln("#extension GL_EXT_debug_printf : require")
    if .Raytracing in writer.ast.used_features {
        writeln("#extension GL_EXT_ray_query : require")
    }

    if writer.shader_type == .Compute {
        writeln("layout(local_size_x_id = 13370, local_size_y_id = 13371, local_size_z_id = 13372) in;")
    }

    // Utility functions used for codegen
    if .Raytracing in writer.ast.used_features
    {
        writeln(RT_Intrinsics_Code)
    }

    // Zero initializations for primitive types
    writeln("bool bool_ZERO;")
    writeln("int int_ZERO;")
    writeln("uint uint_ZERO;")
    writeln("float float_ZERO;")
    writeln("vec2 vec2_ZERO;")
    writeln("vec3 vec3_ZERO;")
    writeln("vec4 vec4_ZERO;")
    writeln("mat4 mat4_ZERO;")
    writeln("uint textureid_ZERO;")
    writeln("uint samplerid_ZERO;")
    writeln("uint bvh_id_ZERO;")
    writeln("")
}

@(private="file")
writefln :: proc(fmt_str: string, args: ..any)
{
    write_indentation()
    fmt.sbprintfln(&writer.builder, fmt_str, ..args)
}

@(private="file")
writef :: proc(fmt_str: string, args: ..any)
{
    fmt.sbprintf(&writer.builder, fmt_str, ..args)
}

@(private="file")
writeln :: proc(strings: ..any)
{
    write_indentation()
    fmt.sbprintln(&writer.builder, ..strings)
}

@(private="file")
write_begin :: proc(strings: ..any)
{
    write_indentation()
    fmt.sbprint(&writer.builder, ..strings)
}

@(private="file")
write :: proc(strings: ..any)
{
    fmt.sbprint(&writer.builder, ..strings)
}

@(private="file")
write_indentation :: proc()
{
    for _ in 0..<4*writer.indentation {
        fmt.sbprint(&writer.builder, " ")
    }
}

@(private="file")
writer_output_to_file :: proc(path: string)
{
    err := os2.write_entire_file_from_string(path, strings.to_string(writer.builder))
    ensure(err == nil)
}

RT_Intrinsics_Code :: `
// Raytracing intrinsics:

layout(set = 3, binding = 0) uniform accelerationStructureEXT _res_bvhs_[];

mat4 _res_mat4_from_mat4x3(mat4x3 m)
{
    // GLSL is column-major: m[col][row]
    return mat4(
        vec4(m[0], 0.0),
        vec4(m[1], 0.0),
        vec4(m[2], 0.0),
        vec4(m[3], 1.0)
    );
}

struct Ray_Desc
{
    uint flags;
    uint cull_mask;
    float t_min;
    float t_max;
    vec3 origin;
    vec3 dir;
};
Ray_Desc Ray_Desc_ZERO;

struct Ray_Result
{
    uint kind;
    float t;
    uint instance_idx;
    uint primitive_idx;
    vec2 barycentrics;
    bool front_face;
    mat4 object_to_world;
    mat4 world_to_object;
};
Ray_Result Ray_Result_ZERO;

Ray_Result rayquery_result(rayQueryEXT rq)
{
    Ray_Result res;
    res.kind = rayQueryGetIntersectionTypeEXT(rq, true);
    res.t = rayQueryGetIntersectionTEXT(rq, true);
    res.instance_idx  = rayQueryGetIntersectionInstanceIdEXT(rq, true);
    res.primitive_idx = rayQueryGetIntersectionPrimitiveIndexEXT(rq, true);
    res.front_face    = rayQueryGetIntersectionFrontFaceEXT(rq, true);
    res.object_to_world = _res_mat4_from_mat4x3(rayQueryGetIntersectionObjectToWorldEXT(rq, true));
    res.world_to_object = _res_mat4_from_mat4x3(rayQueryGetIntersectionWorldToObjectEXT(rq, true));
    res.barycentrics    = rayQueryGetIntersectionBarycentricsEXT(rq, true);
    return res;
}

Ray_Result rayquery_candidate(rayQueryEXT rq)
{
    Ray_Result res;
    res.kind = rayQueryGetIntersectionTypeEXT(rq, false);
    res.t = rayQueryGetIntersectionTEXT(rq, false);
    res.instance_idx  = rayQueryGetIntersectionInstanceIdEXT(rq, false);
    res.primitive_idx = rayQueryGetIntersectionPrimitiveIndexEXT(rq, false);
    res.front_face    = rayQueryGetIntersectionFrontFaceEXT(rq, false);
    res.object_to_world = _res_mat4_from_mat4x3(rayQueryGetIntersectionObjectToWorldEXT(rq, false));
    res.world_to_object = _res_mat4_from_mat4x3(rayQueryGetIntersectionWorldToObjectEXT(rq, false));
    res.barycentrics    = rayQueryGetIntersectionBarycentricsEXT(rq, false);
    return res;
}

void rayquery_init(rayQueryEXT rq, Ray_Desc desc, uint bvh)
{
    rayQueryInitializeEXT(rq,
                          _res_bvhs_[nonuniformEXT(bvh)],
                          desc.flags,
                          desc.cull_mask,
                          desc.origin,
                          desc.t_min,
                          desc.dir,
                          desc.t_max);
}

bool rayquery_proceed(rayQueryEXT rq)
{
    return rayQueryProceedEXT(rq);
}

// Raytracing intrinsics end.
`

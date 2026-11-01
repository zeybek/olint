package olint

import "core:odin/ast"
import "core:strconv"
import "core:strings"

// Size and alignment used for types olint can't see (types from `core:` or `vendor:`
// packages, polymorphic parameters).
@(private = "file")
UNKNOWN_SIZE :: 8

@(private = "file")
_align_up :: proc "contextless" (n, align: int) -> int {
	if align <= 1 {
		return n
	}
	return (n + align - 1) / align * align
}

/*
Evaluates an integer constant expression made of literals, parentheses, `+ - * / << %`, and
names of integer constants declared at package level in `pkg_id` (`MAX :: 4`).
*/
@(require_results)
eval_const_int :: proc(
	ws: ^Workspace,
	pkg_id: int,
	expr: ^ast.Expr,
	depth := 0,
) -> (
	val: int,
	ok: bool,
) {
	if expr == nil || depth > 16 {
		return 0, false
	}
	#partial switch e in expr.derived {
	case ^ast.Basic_Lit:
		if e.tok.kind == .Integer {
			text := e.tok.text
			if strings.contains_rune(text, '_') {
				text, _ = strings.remove_all(text, "_", context.temp_allocator)
			}
			return strconv.parse_int(text)
		}
	case ^ast.Ident:
		if ws != nil && pkg_id >= 0 && pkg_id < len(ws.packages) {
			if c, found := ws.packages[pkg_id].constants[e.name]; found {
				return eval_const_int(ws, pkg_id, c, depth + 1)
			}
		}
	case ^ast.Paren_Expr:
		return eval_const_int(ws, pkg_id, e.expr, depth + 1)
	case ^ast.Binary_Expr:
		lhs := eval_const_int(ws, pkg_id, e.left, depth + 1) or_return
		rhs := eval_const_int(ws, pkg_id, e.right, depth + 1) or_return
		#partial switch e.op.kind {
		case .Add:
			return lhs + rhs, true
		case .Sub:
			return lhs - rhs, true
		case .Mul:
			return lhs * rhs, true
		case .Quo:
			if rhs != 0 {
				return lhs / rhs, true
			}
		case .Mod:
			if rhs != 0 {
				return lhs % rhs, true
			}
		case .Shl:
			if rhs >= 0 && rhs < 63 {
				return lhs << uint(rhs), true
			}
		}
	}
	return 0, false
}

@(private = "file")
_primitive_layout :: proc(name: string) -> (size, align: int, ok: bool) {
	switch name {
	case "bool", "b8", "u8", "i8", "byte":
		return 1, 1, true
	case "b16", "u16", "i16", "u16le", "u16be", "i16le", "i16be", "f16", "f16le", "f16be":
		return 2, 2, true
	case "b32", "u32", "i32", "u32le", "u32be", "i32le", "i32be", "f32", "f32le", "f32be", "rune":
		return 4, 4, true
	case "b64",
	     "u64",
	     "i64",
	     "u64le",
	     "u64be",
	     "i64le",
	     "i64be",
	     "f64",
	     "f64le",
	     "f64be",
	     "int",
	     "uint",
	     "uintptr",
	     "rawptr",
	     "typeid",
	     "cstring":
		return 8, 8, true
	case "u128", "i128", "u128le", "u128be", "i128le", "i128be":
		return 16, 16, true
	case "string", "any":
		return 16, 8, true
	case "complex32":
		return 4, 2, true
	case "complex64":
		return 8, 4, true
	case "complex128":
		return 16, 8, true
	case "quaternion64":
		return 8, 2, true
	case "quaternion128":
		return 16, 4, true
	case "quaternion256":
		return 32, 8, true
	}
	return 0, 0, false
}

// Layout of frequently embedded `base:runtime`/`core:` types, which olint doesn't parse.
@(private = "file")
_core_type_layout :: proc(name: string) -> (size, align: int, ok: bool) {
	switch name {
	case "Allocator", "Random_Generator":
		return 16, 8, true // procedure, data
	case "Source_Code_Location":
		return 40, 8, true // file_path, line, column, procedure
	case "Duration", "Time", "Tick":
		return 8, 8, true
	case "Logger":
		return 32, 8, true // procedure, data, lowest_level, options
	}
	return 0, 0, false
}

@(private = "file")
_named_type_layout :: proc(
	ws: ^Workspace,
	pkg_id: int,
	tid: int,
	depth: int,
) -> (
	size, align: int,
) {
	info := &ws.types[tid]
	if info.size_bytes >= 0 {
		return info.size_bytes, max(info.align, 1)
	}
	if info.size_bytes == -2 {
		return UNKNOWN_SIZE, UNKNOWN_SIZE // Recursive through a value: can't be sized
	}
	info.size_bytes = -2
	sz, al := type_layout(ws, info.pkg_id, info.type_expr, depth + 1)
	info = &ws.types[tid]
	info.size_bytes = sz
	info.align = al
	return sz, al
}

/*
Looks up the named type `name` (optionally qualified by import alias `qual`) as seen from
package `pkg_id`. Returns the index into `Workspace.types`, or -1.
*/
@(require_results)
lookup_type :: proc(ws: ^Workspace, pkg_id: int, qual: string, name: string) -> int {
	if pkg_id < 0 || pkg_id >= len(ws.packages) {
		return -1
	}
	if qual == "" {
		if tid, found := ws.packages[pkg_id].types[name]; found {
			return tid
		}
		return -1
	}
	for &imp in ws.packages[pkg_id].imports {
		if imp.alias == qual && imp.resolved_id >= 0 {
			if tid, found := ws.packages[imp.resolved_id].types[name]; found {
				return tid
			}
		}
	}
	return -1
}

/*
Estimates the size and alignment in bytes of `type_expr` as declared in package `pkg_id`,
following Odin's layout rules (field alignment and tail padding, `#packed`, `#raw_union`,
`#align`). Types olint can't resolve count as 8 bytes.
*/
@(require_results)
type_layout :: proc(
	ws: ^Workspace,
	pkg_id: int,
	type_expr: ^ast.Expr,
	depth := 0,
) -> (
	size, align: int,
) {
	if type_expr == nil || depth > 16 {
		return UNKNOWN_SIZE, UNKNOWN_SIZE
	}
	#partial switch t in type_expr.derived {
	case ^ast.Pointer_Type, ^ast.Multi_Pointer_Type, ^ast.Proc_Type:
		return 8, 8
	case ^ast.Paren_Expr:
		return type_layout(ws, pkg_id, t.expr, depth + 1)
	case ^ast.Distinct_Type:
		return type_layout(ws, pkg_id, t.type, depth + 1)
	case ^ast.Helper_Type:
		return type_layout(ws, pkg_id, t.type, depth + 1)
	case ^ast.Typeid_Type:
		return 8, 8
	case ^ast.Map_Type:
		return 32, 8 // data, len, allocator
	case ^ast.Dynamic_Array_Type:
		return 40, 8 // data, len, cap, allocator
	case ^ast.Fixed_Capacity_Dynamic_Array_Type:
		count, ok := eval_const_int(ws, pkg_id, t.capacity)
		elem_size, elem_align := type_layout(ws, pkg_id, t.elem, depth + 1)
		if !ok || count < 0 {
			return UNKNOWN_SIZE, UNKNOWN_SIZE
		}
		al := max(elem_align, 8)
		return _align_up(count * elem_size + 8, al), al
	case ^ast.Ident:
		if s, a, ok := _primitive_layout(t.name); ok {
			return s, a
		}
		if tid := lookup_type(ws, pkg_id, "", t.name); tid >= 0 {
			return _named_type_layout(ws, pkg_id, tid, depth)
		}
		return UNKNOWN_SIZE, UNKNOWN_SIZE
	case ^ast.Selector_Expr:
		if id, ok := t.expr.derived.(^ast.Ident); ok && t.field != nil {
			if tid := lookup_type(ws, pkg_id, id.name, t.field.name); tid >= 0 {
				return _named_type_layout(ws, pkg_id, tid, depth)
			}
			if s, a, known := _core_type_layout(t.field.name); known {
				return s, a
			}
		}
		return UNKNOWN_SIZE, UNKNOWN_SIZE
	case ^ast.Array_Type:
		if t.len == nil {
			return 16, 8 // slice: data, len
		}
		elem_size, elem_align := type_layout(ws, pkg_id, t.elem, depth + 1)
		count, ok := eval_const_int(ws, pkg_id, t.len)
		if !ok || count < 0 {
			// `[N]T` with a named constant: olint doesn't evaluate constants across declarations.
			return elem_size, elem_align
		}
		return count * elem_size, elem_align
	case ^ast.Matrix_Type:
		r, r_ok := eval_const_int(ws, pkg_id, t.row_count)
		c, c_ok := eval_const_int(ws, pkg_id, t.column_count)
		elem_size, elem_align := type_layout(ws, pkg_id, t.elem, depth + 1)
		if !r_ok || !c_ok || r <= 0 || c <= 0 {
			return UNKNOWN_SIZE, UNKNOWN_SIZE
		}
		return r * c * elem_size, elem_align
	case ^ast.Enum_Type:
		if t.base_type != nil {
			return type_layout(ws, pkg_id, t.base_type, depth + 1)
		}
		return 8, 8
	case ^ast.Bit_Set_Type:
		if t.underlying != nil {
			return type_layout(ws, pkg_id, t.underlying, depth + 1)
		}
		return 8, 8
	case ^ast.Bit_Field_Type:
		return type_layout(ws, pkg_id, t.backing_type, depth + 1)
	case ^ast.Union_Type:
		max_size, max_align := 0, 1
		for v in t.variants {
			s, a := type_layout(ws, pkg_id, v, depth + 1)
			max_size = max(max_size, s)
			max_align = max(max_align, a)
		}
		tag :=
			0 if t.kind == .no_nil && len(t.variants) == 1 else (1 if len(t.variants) < 256 else 2)
		if t.kind == .maybe && len(t.variants) == 1 {
			tag = 0 // Maybe(^T) and similar pointer-like unions
		}
		al := max_align
		if forced, ok := eval_const_int(ws, pkg_id, t.align); ok && forced > 0 {
			al = forced
		}
		return _align_up(_align_up(max_size, max(tag, 1)) + tag, al), al
	case ^ast.Struct_Type:
		if t.fields == nil {
			return 0, 1
		}
		total, struct_align := 0, 1
		for field in t.fields.list {
			if field == nil {
				continue
			}
			fsz, fal := type_layout(ws, pkg_id, field.type, depth + 1)
			if t.is_packed {
				fal = 1
			}
			for _ in 0 ..< max(len(field.names), 1) {
				if t.is_raw_union {
					total = max(total, fsz)
				} else {
					total = _align_up(total, fal) + fsz
				}
				struct_align = max(struct_align, fal)
			}
		}
		if forced, ok := eval_const_int(ws, pkg_id, t.align); ok && forced > 0 {
			struct_align = forced
		}
		return _align_up(total, struct_align), struct_align
	}
	return UNKNOWN_SIZE, UNKNOWN_SIZE
}

/*
Estimated size in bytes of `type_expr` as declared in package `pkg_id`. See `type_layout`.
*/
@(require_results)
estimate_type_size :: proc(ws: ^Workspace, pkg_id: int, type_expr: ^ast.Expr) -> int {
	size, _ := type_layout(ws, pkg_id, type_expr)
	return size
}

/*
Resolves the declared type of field `field_name` of the struct `base_type_expr` (a struct type,
a named struct, or a pointer to one) as seen from package `pkg_id`. Returns the package the
field's type expression belongs to.
*/
@(require_results)
resolve_struct_field_type :: proc(
	ws: ^Workspace,
	pkg_id: int,
	base_type_expr: ^ast.Expr,
	field_name: string,
	depth := 0,
) -> (
	field_type: ^ast.Expr,
	resolved_pkg_id: int,
) {
	if base_type_expr == nil || field_name == "" || depth > 8 {
		return nil, pkg_id
	}
	#partial switch t in base_type_expr.derived {
	case ^ast.Pointer_Type:
		return resolve_struct_field_type(ws, pkg_id, t.elem, field_name, depth + 1)
	case ^ast.Distinct_Type:
		return resolve_struct_field_type(ws, pkg_id, t.type, field_name, depth + 1)
	case ^ast.Helper_Type:
		return resolve_struct_field_type(ws, pkg_id, t.type, field_name, depth + 1)
	case ^ast.Ident:
		if tid := lookup_type(ws, pkg_id, "", t.name); tid >= 0 {
			info := &ws.types[tid]
			return resolve_struct_field_type(
				ws,
				info.pkg_id,
				info.type_expr,
				field_name,
				depth + 1,
			)
		}
	case ^ast.Selector_Expr:
		if id, ok := t.expr.derived.(^ast.Ident); ok && t.field != nil {
			if tid := lookup_type(ws, pkg_id, id.name, t.field.name); tid >= 0 {
				info := &ws.types[tid]
				return resolve_struct_field_type(
					ws,
					info.pkg_id,
					info.type_expr,
					field_name,
					depth + 1,
				)
			}
		}
	case ^ast.Struct_Type:
		if t.fields == nil {
			return nil, pkg_id
		}
		for f in t.fields.list {
			if f == nil {
				continue
			}
			for n_expr in f.names {
				if id, ok := n_expr.derived.(^ast.Ident); ok && id.name == field_name {
					return f.type, pkg_id
				}
			}
		}
	}
	return nil, pkg_id
}

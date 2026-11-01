package olint

import "core:fmt"
import "core:odin/ast"

/*
Runs `perf/large-value-copy` across `ws`, appending findings to `report`.

With Odin's default `"odin"` and `"contextless"` conventions, parameters are immutable and a
large aggregate is passed by an implicit pointer, so passing it costs nothing. Copies happen
when:

1. a procedure with a C ABI convention (`"c"`, `"system"`, `"stdcall"`, ...) takes an aggregate
   by value without `#by_ptr`,
2. a large parameter is copied into a local (`p := p`), or
3. a range loop binds each large element by value (`for v in items`). Unoptimized builds copy
   every element; optimized builds drop the copy unless the loop variable escapes (its address
   is taken, it is passed to a call, or it is assigned to).

This is the 64-bit ABI. On i386 the Odin conventions copy large parameters too, which the rule
doesn't report.
*/
run_perf_rules :: proc(ws: ^Workspace, #by_ptr cfg: Config, report: ^Report) {
	if .Large_Value_Copy not_in cfg.enabled_rules {
		return
	}
	threshold := cfg.large_copy_bytes if cfg.large_copy_bytes > 0 else DEFAULT_LARGE_COPY_BYTES

	for i in 0 ..< len(ws.procs) {
		pr := &ws.procs[i]
		if ws.packages[pr.pkg_id].is_dependency ||
		   is_rule_ignored(pr.annotations, .Large_Value_Copy) ||
		   is_rule_ignored(pr.file_annotations, .Large_Value_Copy) {
			continue
		}

		large_params := make(map[string]int, context.temp_allocator)
		for &pm in pr.params {
			if pm.by_ptr ||
			   pm.type_expr == nil ||
			   !_is_value_aggregate(ws, pr.pkg_id, pm.type_expr) {
				continue
			}
			sz := estimate_type_size(ws, pr.pkg_id, pm.type_expr)
			if sz < threshold {
				continue
			}
			if pm.name != "" {
				large_params[pm.name] = sz
			}
			if pr.is_c_abi {
				report_add_diagnostic(
					report,
					.Large_Value_Copy,
					.Warning,
					pr.pkg_name,
					pr.full_name,
					pm.location,
					fmt.tprintf(
						"C-ABI parameter '%s' of %s copies %d bytes on every call (threshold %d B); use ^T or #by_ptr",
						pm.name if pm.name != "" else "<unnamed>",
						pr.full_name,
						sz,
						threshold,
					),
				)
			}
		}

		if pr.lit == nil || pr.lit.body == nil {
			continue
		}
		c := _Copy_Check {
			ws           = ws,
			pr           = pr,
			threshold    = threshold,
			report       = report,
			local_types  = make(map[string]^ast.Expr, context.temp_allocator),
			large_params = &large_params,
		}
		for &pm in pr.params {
			if pm.name != "" && pm.type_expr != nil {
				c.local_types[pm.name] = pm.type_expr
			}
		}
		_check_body_copies(&c, pr.lit.body)
	}
}

@(private = "file")
_Copy_Check :: struct {
	ws:           ^Workspace,
	pr:           ^Proc_Info,
	threshold:    int,
	report:       ^Report,
	local_types:  map[string]^ast.Expr,
	large_params: ^map[string]int,
}

// Reports whether values of `type_expr` are aggregates that get copied (fixed arrays, matrices,
// structs, unions), as opposed to pointers, slices, strings, and other handles.
@(private = "file")
_is_value_aggregate :: proc(
	ws: ^Workspace,
	pkg_id: int,
	type_expr: ^ast.Expr,
	depth := 0,
) -> bool {
	if type_expr == nil || depth > 8 {
		return false
	}
	#partial switch t in type_expr.derived {
	case ^ast.Array_Type:
		return t.len != nil
	case ^ast.Matrix_Type,
	     ^ast.Struct_Type,
	     ^ast.Union_Type,
	     ^ast.Fixed_Capacity_Dynamic_Array_Type:
		return true
	case ^ast.Distinct_Type:
		return _is_value_aggregate(ws, pkg_id, t.type, depth + 1)
	case ^ast.Ident, ^ast.Selector_Expr:
		qual, name := call_target(type_expr)
		if tid := lookup_type(ws, pkg_id, qual, name); tid >= 0 {
			info := &ws.types[tid]
			return _is_value_aggregate(ws, info.pkg_id, info.type_expr, depth + 1)
		}
	}
	return false
}

// Element type of an iterable type (`[N]T`, `[]T`, `[dynamic]T`, `[dynamic; N]T`, or a
// pointer to one of these).
@(private = "file")
_elem_type :: proc(
	ws: ^Workspace,
	pkg_id: int,
	type_expr: ^ast.Expr,
	depth := 0,
) -> (
	^ast.Expr,
	int,
) {
	if type_expr == nil || depth > 8 {
		return nil, pkg_id
	}
	#partial switch t in type_expr.derived {
	case ^ast.Array_Type:
		return t.elem, pkg_id
	case ^ast.Dynamic_Array_Type:
		return t.elem, pkg_id
	case ^ast.Fixed_Capacity_Dynamic_Array_Type:
		return t.elem, pkg_id
	case ^ast.Pointer_Type:
		return _elem_type(ws, pkg_id, t.elem, depth + 1)
	case ^ast.Distinct_Type:
		return _elem_type(ws, pkg_id, t.type, depth + 1)
	case ^ast.Ident, ^ast.Selector_Expr:
		qual, name := call_target(type_expr)
		if tid := lookup_type(ws, pkg_id, qual, name); tid >= 0 {
			info := &ws.types[tid]
			return _elem_type(ws, info.pkg_id, info.type_expr, depth + 1)
		}
	}
	return nil, pkg_id
}

// Declared type of the iterated expression, for identifiers, `x.field`, slicing and
// dereferences.
@(private = "file")
_iterable_type :: proc(
	c: ^_Copy_Check,
	expr: ^ast.Expr,
) -> (
	type_expr: ^ast.Expr,
	pkg_id: int,
	label: string,
) {
	pkg_id = c.pr.pkg_id
	if expr == nil {
		return
	}
	#partial switch e in ast.unparen_expr(expr).derived {
	case ^ast.Ident:
		if t, found := c.local_types[e.name]; found {
			return t, pkg_id, e.name
		}
	case ^ast.Slice_Expr:
		return _iterable_type(c, e.expr)
	case ^ast.Deref_Expr:
		return _iterable_type(c, e.expr)
	case ^ast.Selector_Expr:
		if base_id, ok := ast.unparen_expr(e.expr).derived.(^ast.Ident); ok && e.field != nil {
			if base_type, found := c.local_types[base_id.name]; found {
				ft, fpkg := resolve_struct_field_type(c.ws, pkg_id, base_type, e.field.name)
				if ft != nil {
					return ft, fpkg, fmt.tprintf("%s.%s", base_id.name, e.field.name)
				}
			}
		}
	}
	return nil, pkg_id, ""
}

// Type of a value expression, when it is obvious from the syntax (`make(T, ...)`, `T{...}`).
@(private = "file")
_inferred_type :: proc(expr: ^ast.Expr) -> ^ast.Expr {
	if expr == nil {
		return nil
	}
	#partial switch e in ast.strip_or_return_expr(expr).derived {
	case ^ast.Call_Expr:
		if _, name := call_target(e.expr); name == "make" && len(e.args) > 0 {
			return e.args[0]
		}
	case ^ast.Comp_Lit:
		return e.type
	}
	return nil
}

// Variable an assignment target writes into: `v` for `v`, `v.field`, and `v[i].field`.
@(private = "file")
_assignment_root :: proc(target: ^ast.Expr) -> ^ast.Expr {
	root := target
	for root != nil {
		if sel, ok := root.derived.(^ast.Selector_Expr); ok {
			root = sel.expr
		} else if idx, ok2 := root.derived.(^ast.Index_Expr); ok2 {
			root = idx.expr
		} else {
			return root
		}
	}
	return root
}

// Reports whether `name` escapes in `body`: its address is taken, it is passed to a call, or it
// is assigned to. Optimized builds keep the per-iteration copy of an escaping loop variable.
@(private = "file")
_var_escapes :: proc(body: ^ast.Stmt, name: string) -> bool {
	State :: struct {
		name:    string,
		escapes: bool,
	}
	st := State {
		name = name,
	}
	is_name :: proc(e: ^ast.Expr, name: string) -> bool {
		if e == nil {
			return false
		}
		id, ok := ast.unparen_expr(e).derived.(^ast.Ident)
		return ok && id.name == name
	}
	v := ast.Visitor {
		data = &st,
		visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			s := (^State)(v.data)
			if node == nil || s.escapes {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Unary_Expr:
				if n.op.kind == .And && is_name(n.expr, s.name) {
					s.escapes = true
				}
			case ^ast.Call_Expr:
				for arg in n.args {
					value := arg
					if fv, ok := arg.derived.(^ast.Field_Value); ok {
						value = fv.value
					}
					if is_name(value, s.name) {
						s.escapes = true
					}
				}
			case ^ast.Assign_Stmt:
				for l in n.lhs {
					if is_name(_assignment_root(l), s.name) {
						s.escapes = true
					}
				}
			case ^ast.Value_Decl:
				for val in n.values {
					if is_name(val, s.name) {
						s.escapes = true
					}
				}
			}
			return v
		},
	}
	ast.walk(&v, body)
	return st.escapes
}

@(private = "file")
_check_range :: proc(c: ^_Copy_Check, s: ^ast.Range_Stmt) {
	if len(s.vals) == 0 || s.vals[0] == nil || s.expr == nil {
		return
	}
	val0 := s.vals[0]
	var_id, is_id := val0.derived.(^ast.Ident)
	if !is_id || var_id.name == "_" {
		return // `for &v in items` or a discarded value
	}
	arr_type, arr_pkg, label := _iterable_type(c, s.expr)
	elem, elem_pkg := _elem_type(c.ws, arr_pkg, arr_type)
	if elem == nil || !_is_value_aggregate(c.ws, elem_pkg, elem) {
		return
	}
	size := estimate_type_size(c.ws, elem_pkg, elem)
	if size < c.threshold {
		return
	}
	msg: string
	if _var_escapes(s.body, var_id.name) {
		msg = fmt.tprintf(
			"'for %s in %s' in %s copies a %d-byte element every iteration, also in optimized builds because '%s' escapes; use 'for &%s in %s'",
			var_id.name,
			label,
			c.pr.full_name,
			size,
			var_id.name,
			var_id.name,
			label,
		)
	} else {
		msg = fmt.tprintf(
			"'for %s in %s' in %s binds a %d-byte element by value (copied every iteration in unoptimized builds); use 'for &%s in %s'",
			var_id.name,
			label,
			c.pr.full_name,
			size,
			var_id.name,
			label,
		)
	}
	report_add_diagnostic(
		c.report,
		.Large_Value_Copy,
		.Warning,
		c.pr.pkg_name,
		c.pr.full_name,
		Location{c.pr.file_path, val0.pos.line, val0.pos.column},
		msg,
	)
}

@(private = "file")
_check_value_decl :: proc(c: ^_Copy_Check, s: ^ast.Value_Decl) {
	for name_expr, idx in s.names {
		id, ok := name_expr.derived.(^ast.Ident)
		if !ok || id.name == "_" {
			continue
		}
		if s.type != nil {
			c.local_types[id.name] = s.type
		} else if idx < len(s.values) {
			if t := _inferred_type(s.values[idx]); t != nil {
				c.local_types[id.name] = t
			}
		}
	}
	if !s.is_mutable || len(s.names) != 1 || len(s.values) != 1 || s.values[0] == nil {
		return
	}
	rhs_id, ok := ast.unparen_expr(s.values[0]).derived.(^ast.Ident)
	if !ok {
		return
	}
	size, is_large := c.large_params[rhs_id.name]
	if !is_large {
		return
	}
	report_add_diagnostic(
		c.report,
		.Large_Value_Copy,
		.Warning,
		c.pr.pkg_name,
		c.pr.full_name,
		Location{c.pr.file_path, s.pos.line, s.pos.column},
		fmt.tprintf(
			"local copy of parameter '%s' in %s copies %d bytes (threshold %d B); take ^T to modify the caller's value in place",
			rhs_id.name,
			c.pr.full_name,
			size,
			c.threshold,
		),
	)
}

@(private = "file")
_check_body_copies :: proc(c: ^_Copy_Check, stmt: ^ast.Stmt) {
	if stmt == nil {
		return
	}
	#partial switch s in stmt.derived {
	case ^ast.Block_Stmt:
		for child in s.stmts {
			_check_body_copies(c, child)
		}
	case ^ast.Value_Decl:
		_check_value_decl(c, s)
	case ^ast.Range_Stmt:
		_check_range(c, s)
		_check_body_copies(c, s.body)
	case ^ast.For_Stmt:
		_check_body_copies(c, s.init)
		_check_body_copies(c, s.body)
		_check_body_copies(c, s.post)
	case ^ast.If_Stmt:
		_check_body_copies(c, s.init)
		_check_body_copies(c, s.body)
		_check_body_copies(c, s.else_stmt)
	case ^ast.When_Stmt:
		_check_body_copies(c, s.body)
		_check_body_copies(c, s.else_stmt)
	case ^ast.Switch_Stmt:
		_check_body_copies(c, s.init)
		_check_body_copies(c, s.body)
	case ^ast.Type_Switch_Stmt:
		_check_body_copies(c, s.tag)
		_check_body_copies(c, s.body)
	case ^ast.Case_Clause:
		for child in s.body {
			_check_body_copies(c, child)
		}
	case ^ast.Defer_Stmt:
		_check_body_copies(c, s.stmt)
	case ^ast.Tag_Stmt:
		_check_body_copies(c, s.stmt)
	}
}

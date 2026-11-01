package olint

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

/*
Kind of default allocator used by a procedure's allocator parameter.
*/
Alloc_Param_Default :: enum {
	None,
	Heap, // `allocator := context.allocator`
	Temp, // `allocator := context.temp_allocator`
	Custom, // `allocator: runtime.Allocator` (no default or custom default)
}

/*
Source file loaded into a `Workspace`.
*/
Source_File :: struct {
	fullpath:    string,
	ast_file:    ^ast.File,
	annotations: Annotations, // From the comment above `package`; scoped to this file
	is_private:  bool,
}

/*
Import edge declared inside a package.
*/
Import_Entry :: struct {
	alias:       string,
	raw_path:    string, // e.g. "core:fmt" or "../other"
	resolved_id: int, // Index into `Workspace.packages`, or -1 if not loaded
	location:    Location,
}

/*
Type declaration recorded for value-copy size estimation and field lookup.
*/
Type_Decl_Info :: struct {
	pkg_id:     int,
	name:       string,
	type_expr:  ^ast.Expr,
	location:   Location,
	size_bytes: int, // -1 until computed, -2 while computing (cycle guard)
	align:      int,
}

/*
Parameter of a procedure declaration.
*/
Param_Info :: struct {
	name:          string,
	type_expr:     ^ast.Expr,
	default_value: ^ast.Expr,
	by_ptr:        bool,
	location:      Location,
}

/*
Procedure declaration discovered in a workspace package. Procedures declared inside another
procedure's body are recorded too, with `parent_id` set and a `full_name` such as
`pkg.outer.inner`.
*/
Proc_Info :: struct {
	id:                  int,
	pkg_id:              int,
	parent_id:           int, // -1 for package-level procedures
	pkg_name:            string,
	name:                string,
	full_name:           string, // `pkg.proc` or `pkg.outer.inner`
	file_path:           string,
	location:            Location,
	lit:                 ^ast.Proc_Lit,
	docs:                ^ast.Comment_Group, // Possibly nil
	annotations:         Annotations, // From the procedure's own doc comment
	file_annotations:    Annotations, // From the comment above `package` in its file
	local_procs:         map[string]int, // Procedures declared in this body -> Proc_Info.id
	is_private:          bool,
	is_contextless:      bool,
	is_c_abi:            bool,
	params:              [dynamic]Param_Info,
	alloc_param_name:    string,
	alloc_param_index:   int,
	alloc_param_default: Alloc_Param_Default,
}

/*
Procedure group whose members are resolved after every package is loaded, because members may
live in other packages (`dup :: proc{lib.dup_string, dup_bytes}`).
*/
Pending_Group :: struct {
	name:      string,
	file_path: string,
	members:   []^ast.Expr,
}

/*
Parsed Odin package inside a `Workspace`. Packages under the analyzed directory are reported on;
packages pulled in only because something imports them (`is_dependency`) take part in the call
and import graphs but get no diagnostics of their own.
*/
Package_Info :: struct {
	id:             int,
	name:           string,
	dir_path:       string,
	rel_dir:        string,
	is_dependency:  bool,
	annotations:    Annotations, // Union of the file-level annotations of every file
	files:          [dynamic]Source_File,
	imports:        [dynamic]Import_Entry,
	file_imports:   map[string][dynamic]Import_Entry, // file_path -> imports in that file
	procs:          map[string]int, // proc name -> Proc_Info.id
	proc_groups:    map[string][dynamic]int, // proc group name -> member Proc_Info.ids
	pending_groups: [dynamic]Pending_Group,
	types:          map[string]int, // type name -> Type_Decl_Info index
	constants:      map[string]^ast.Expr, // `NAME :: <expr>` value expressions, for array lengths
}

/*
In-memory source file used for testing without touching the filesystem.
*/
Virtual_File :: struct {
	path: string,
	src:  string,
}

/*
Collection of parsed packages, types, and procedures ready for static analysis.
*/
Workspace :: struct {
	allocator:          runtime.Allocator,
	ast_arena:          runtime.Arena,
	root_path:          string,
	target_name:        string,
	collections:        [dynamic]Collection,
	packages:           [dynamic]Package_Info,
	pkg_by_dir:         map[string]int,
	procs:              [dynamic]Proc_Info,
	types:              [dynamic]Type_Decl_Info,
	parse_errors:       [dynamic]string,
	files_count:        int,
	dependencies_count: int,
}

@(private = "file")
_Parser_Error_Sink :: struct {
	errors:    ^[dynamic]string,
	allocator: runtime.Allocator,
}

@(private = "file", thread_local)
_active_error_sink: ^_Parser_Error_Sink

@(private = "file")
_parser_error_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
	if _active_error_sink == nil {
		return
	}
	formatted := fmt.tprintf(msg, ..args)
	entry := fmt.aprintf(
		"%s(%d:%d): %s",
		pos.file,
		pos.line,
		pos.column,
		formatted,
		allocator = _active_error_sink.allocator,
	)
	append(_active_error_sink.errors, entry)
}

@(private = "file")
_parser_warn_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {}

/*
Initializes an empty `Workspace`.
*/
@(require_results)
workspace_create :: proc(
	root_path := "",
	allocator := context.allocator,
	loc := #caller_location,
) -> Workspace {
	target := filepath.base(root_path) if root_path != "" else "workspace"
	if target == "." || target == "/" || target == "" {
		target = "workspace"
	}
	return Workspace {
		allocator = allocator,
		ast_arena = runtime.Arena{backing_allocator = allocator},
		root_path = strings.clone(root_path, allocator, loc),
		target_name = strings.clone(target, allocator, loc),
		collections = make([dynamic]Collection, allocator, loc),
		packages = make([dynamic]Package_Info, allocator, loc),
		pkg_by_dir = make(map[string]int, allocator, loc),
		procs = make([dynamic]Proc_Info, allocator, loc),
		types = make([dynamic]Type_Decl_Info, allocator, loc),
		parse_errors = make([dynamic]string, allocator, loc),
	}
}

@(private = "file")
_destroy_imports :: proc(list: ^[dynamic]Import_Entry, alloc: runtime.Allocator) {
	for &imp in list {
		delete(imp.alias, alloc)
		delete(imp.raw_path, alloc)
		delete(imp.location.file_path, alloc)
	}
	delete(list^)
}

/*
Frees all memory owned by `ws`, including the AST arena.
*/
workspace_destroy :: proc(ws: ^Workspace) {
	alloc := ws.allocator
	delete(ws.root_path, alloc)
	delete(ws.target_name, alloc)
	for c in ws.collections {
		delete(c.name, alloc)
		delete(c.path, alloc)
	}
	delete(ws.collections)

	for &pkg in ws.packages {
		delete(pkg.name, alloc)
		delete(pkg.dir_path, alloc)
		delete(pkg.rel_dir, alloc)
		destroy_annotations(&pkg.annotations, alloc)
		for &sf in pkg.files {
			delete(sf.fullpath, alloc)
			destroy_annotations(&sf.annotations, alloc)
		}
		delete(pkg.files)
		_destroy_imports(&pkg.imports, alloc)
		for k, &list in pkg.file_imports {
			delete(k, alloc)
			_destroy_imports(&list, alloc)
		}
		delete(pkg.file_imports)
		for k in pkg.procs {
			delete(k, alloc)
		}
		delete(pkg.procs)
		for k, &grp in pkg.proc_groups {
			delete(k, alloc)
			delete(grp)
		}
		delete(pkg.proc_groups)
		for &pg in pkg.pending_groups {
			delete(pg.name, alloc)
			delete(pg.file_path, alloc)
		}
		delete(pkg.pending_groups)
		for k in pkg.types {
			delete(k, alloc)
		}
		delete(pkg.types)
		for k in pkg.constants {
			delete(k, alloc)
		}
		delete(pkg.constants)
	}
	delete(ws.packages)

	for k in ws.pkg_by_dir {
		delete(k, alloc)
	}
	delete(ws.pkg_by_dir)

	for &pr in ws.procs {
		delete(pr.pkg_name, alloc)
		delete(pr.name, alloc)
		delete(pr.full_name, alloc)
		delete(pr.file_path, alloc)
		delete(pr.location.file_path, alloc)
		delete(pr.alloc_param_name, alloc)
		destroy_annotations(&pr.annotations, alloc)
		destroy_annotations(&pr.file_annotations, alloc)
		for k in pr.local_procs {
			delete(k, alloc)
		}
		delete(pr.local_procs)
		for &pm in pr.params {
			delete(pm.name, alloc)
			delete(pm.location.file_path, alloc)
		}
		delete(pr.params)
	}
	delete(ws.procs)

	for &td in ws.types {
		delete(td.name, alloc)
		delete(td.location.file_path, alloc)
	}
	delete(ws.types)

	for msg in ws.parse_errors {
		delete(msg, alloc)
	}
	delete(ws.parse_errors)

	runtime.arena_destroy(&ws.ast_arena)
	ws^ = {}
}

@(private = "file")
_import_alias_and_path :: proc(imp: ^ast.Import_Decl) -> (alias: string, path: string) {
	path = strings.trim(imp.fullpath, "\"`")
	if imp.name.text != "" {
		return imp.name.text, path
	}
	base := path
	if colon := strings.last_index_byte(base, ':'); colon >= 0 {
		base = base[colon + 1:]
	}
	base = strings.trim_right(base, "/")
	if slash := strings.last_index_byte(base, '/'); slash >= 0 {
		base = base[slash + 1:]
	}
	return base, path
}

@(private = "file")
_merge_annotations :: proc(
	dst: ^Annotations,
	#by_ptr src: Annotations,
	allocator: runtime.Allocator,
) {
	dst.zero_alloc ||= src.zero_alloc
	dst.no_temp_alloc ||= src.no_temp_alloc
	dst.alloc_safe ||= src.alloc_safe
	dst.allocates_heap ||= src.allocates_heap
	dst.allocates_temp ||= src.allocates_temp
	dst.ignore_all ||= src.ignore_all
	dst.ignored_rules += src.ignored_rules
	if dst.layer == "" && src.layer != "" {
		dst.layer = src.layer
	}
	for item in src.forbid_imports {
		if !slice.contains(dst.forbid_imports[:], item) {
			append(&dst.forbid_imports, strings.clone(item, allocator))
		}
	}
}

@(private = "file")
_clone_annotations :: proc(#by_ptr src: Annotations, allocator: runtime.Allocator) -> Annotations {
	res := Annotations {
		zero_alloc     = src.zero_alloc,
		no_temp_alloc  = src.no_temp_alloc,
		alloc_safe     = src.alloc_safe,
		allocates_heap = src.allocates_heap,
		allocates_temp = src.allocates_temp,
		ignore_all     = src.ignore_all,
		ignored_rules  = src.ignored_rules,
		layer          = src.layer,
		forbid_imports = make([dynamic]string, 0, len(src.forbid_imports), allocator),
	}
	for item in src.forbid_imports {
		append(&res.forbid_imports, strings.clone(item, allocator))
	}
	return res
}

@(private = "file")
_has_private_attr :: proc(attrs: []^ast.Attribute) -> bool {
	for attr in attrs {
		if attr == nil {
			continue
		}
		for elem in attr.elems {
			if elem == nil {
				continue
			}
			#partial switch e in elem.derived {
			case ^ast.Ident:
				if e.name == "private" {
					return true
				}
			case ^ast.Field_Value:
				if id, ok := e.field.derived.(^ast.Ident); ok && id.name == "private" {
					return true
				}
			}
		}
	}
	return false
}

/*
Reports whether `expr` is the implicit `context` value.
*/
@(require_results)
is_context_expr :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil {
		return false
	}
	#partial switch e in expr.derived {
	case ^ast.Implicit:
		return e.tok.kind == .Context || e.tok.text == "context"
	case ^ast.Ident:
		return e.name == "context"
	}
	return false
}

@(private = "file")
_classify_alloc_default :: proc(type_expr: ^ast.Expr, def_expr: ^ast.Expr) -> Alloc_Param_Default {
	if def_expr != nil {
		#partial switch e in def_expr.derived {
		case ^ast.Selector_Expr:
			if is_context_expr(e.expr) && e.field != nil {
				switch e.field.name {
				case "allocator":
					return .Heap
				case "temp_allocator":
					return .Temp
				}
			}
		}
	}
	if type_expr != nil {
		#partial switch t in type_expr.derived {
		case ^ast.Ident:
			if t.name == "Allocator" {
				return .Custom
			}
		case ^ast.Selector_Expr:
			if t.field != nil && t.field.name == "Allocator" {
				return .Custom
			}
		}
	}
	return .None
}

// Calling conventions that don't pass an implicit `context`.
@(private = "file")
_is_contextless_convention :: proc(cc: string) -> bool {
	return cc != "" && cc != "odin"
}

// Calling conventions that follow the platform C ABI, where an aggregate parameter is copied
// unless it is passed by pointer or `#by_ptr`.
@(private = "file")
_is_c_abi_convention :: proc(cc: string) -> bool {
	switch cc {
	case "c", "cdecl", "std", "stdcall", "fast", "fastcall", "system", "win64", "sysv":
		return true
	}
	return false
}

// Registers one procedure literal and returns its id. `docs` and `attrs` come from its
// declaration.
@(private = "file")
_register_proc :: proc(
	ws: ^Workspace,
	pkg_id: int,
	file_path: string,
	file_ann: ^Annotations,
	file_private: bool,
	name: string,
	name_pos: tokenizer.Pos,
	docs: ^ast.Comment_Group,
	attrs: []^ast.Attribute,
	lit: ^ast.Proc_Lit,
	parent_id: int,
) -> int {
	alloc := ws.allocator
	pkg := &ws.packages[pkg_id]
	proc_id := len(ws.procs)

	params := make([dynamic]Param_Info, alloc)
	alloc_param_name := ""
	alloc_param_index := -1
	alloc_param_default := Alloc_Param_Default.None

	cc := ""
	if lit.type != nil {
		if s, is_str := lit.type.calling_convention.(string); is_str {
			cc = strings.trim(s, "\"`")
		}
	}

	if lit.type != nil && lit.type.params != nil {
		param_pos := 0
		for field in lit.type.params.list {
			if field == nil {
				continue
			}
			by_ptr := .By_Ptr in field.flags
			def_kind := _classify_alloc_default(field.type, field.default_value)
			if len(field.names) == 0 {
				append(
					&params,
					Param_Info {
						name = strings.clone("", alloc),
						type_expr = field.type,
						default_value = field.default_value,
						by_ptr = by_ptr,
						location = Location {
							file_path = strings.clone(file_path, alloc),
							line = field.pos.line,
							column = field.pos.column,
						},
					},
				)
				param_pos += 1
				continue
			}
			for pname_expr in field.names {
				pname := ""
				if pid, ok := pname_expr.derived.(^ast.Ident); ok {
					pname = pid.name
				}
				if def_kind != .None && alloc_param_index < 0 {
					alloc_param_name = pname
					alloc_param_index = param_pos
					alloc_param_default = def_kind
				}
				append(
					&params,
					Param_Info {
						name = strings.clone(pname, alloc),
						type_expr = field.type,
						default_value = field.default_value,
						by_ptr = by_ptr,
						location = Location {
							file_path = strings.clone(file_path, alloc),
							line = pname_expr.pos.line,
							column = pname_expr.pos.column,
						},
					},
				)
				param_pos += 1
			}
		}
	}

	full_name: string
	if parent_id >= 0 {
		full_name = fmt.aprintf("%s.%s", ws.procs[parent_id].full_name, name, allocator = alloc)
	} else {
		full_name = fmt.aprintf("%s.%s", pkg.name, name, allocator = alloc)
	}

	append(
		&ws.procs,
		Proc_Info {
			id = proc_id,
			pkg_id = pkg_id,
			parent_id = parent_id,
			pkg_name = strings.clone(pkg.name, alloc),
			name = strings.clone(name, alloc),
			full_name = full_name,
			file_path = strings.clone(file_path, alloc),
			location = Location {
				file_path = strings.clone(file_path, alloc),
				line = name_pos.line,
				column = name_pos.column,
			},
			lit = lit,
			docs = docs,
			annotations = parse_annotations(docs, attrs, alloc),
			file_annotations = _clone_annotations(file_ann^, alloc),
			local_procs = make(map[string]int, alloc),
			is_private = file_private || _has_private_attr(attrs),
			is_contextless = _is_contextless_convention(cc),
			is_c_abi = _is_c_abi_convention(cc),
			params = params,
			alloc_param_name = strings.clone(alloc_param_name, alloc),
			alloc_param_index = alloc_param_index,
			alloc_param_default = alloc_param_default,
		},
	)
	return proc_id
}

@(private = "file")
_Nested_Decl :: struct {
	name:  string,
	pos:   tokenizer.Pos,
	docs:  ^ast.Comment_Group,
	attrs: []^ast.Attribute,
	lit:   ^ast.Proc_Lit,
}

// Collects `name :: proc(...) {...}` declarations in `body`, without descending into nested
// procedure literals (each of those collects its own).
@(private = "file")
_find_nested_proc_decls :: proc(body: ^ast.Stmt) -> []_Nested_Decl {
	out := make([dynamic]_Nested_Decl, context.temp_allocator)
	if body == nil {
		return nil
	}
	v := ast.Visitor {
		data = &out,
		visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			list := (^[dynamic]_Nested_Decl)(v.data)
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Value_Decl:
				if n.is_mutable {
					return v
				}
				for name_expr, idx in n.names {
					if idx >= len(n.values) || n.values[idx] == nil {
						continue
					}
					ident, is_ident := name_expr.derived.(^ast.Ident)
					lit, is_lit := n.values[idx].derived.(^ast.Proc_Lit)
					if is_ident && is_lit && lit.body != nil && ident.name != "_" {
						append(
							list,
							_Nested_Decl {
								name = ident.name,
								pos = ident.pos,
								docs = n.docs,
								attrs = n.attributes[:],
								lit = lit,
							},
						)
					}
				}
				return nil
			}
			return v
		},
	}
	ast.walk(&v, body)
	return out[:]
}

@(private = "file")
_register_nested_procs :: proc(
	ws: ^Workspace,
	pkg_id: int,
	file_path: string,
	file_ann: ^Annotations,
	file_private: bool,
	parent_id: int,
) {
	decls := _find_nested_proc_decls(ws.procs[parent_id].lit.body)
	for d in decls {
		id := _register_proc(
			ws,
			pkg_id,
			file_path,
			file_ann,
			file_private,
			d.name,
			d.pos,
			d.docs,
			d.attrs,
			d.lit,
			parent_id,
		)
		parent := &ws.procs[parent_id]
		if _, exists := parent.local_procs[d.name]; !exists {
			parent.local_procs[strings.clone(d.name, ws.allocator)] = id
		}
		_register_nested_procs(ws, pkg_id, file_path, file_ann, file_private, id)
	}
}

@(private = "file")
_append_import :: proc(
	list: ^[dynamic]Import_Entry,
	alias, raw_path: string,
	loc: Location,
	alloc: runtime.Allocator,
) {
	append(
		list,
		Import_Entry {
			alias = strings.clone(alias, alloc),
			raw_path = strings.clone(raw_path, alloc),
			resolved_id = -1,
			location = Location {
				file_path = strings.clone(loc.file_path, alloc),
				line = loc.line,
				column = loc.column,
			},
		},
	)
}

@(private = "file")
_extract_package_declarations :: proc(ws: ^Workspace, pkg_id: int) {
	alloc := ws.allocator

	for file_idx in 0 ..< len(ws.packages[pkg_id].files) {
		pkg := &ws.packages[pkg_id]
		sf := &pkg.files[file_idx]
		file := sf.ast_file
		if file == nil {
			continue
		}
		file_path := sf.fullpath
		file_private := sf.is_private

		file_imps := make([dynamic]Import_Entry, alloc)
		for imp in file.imports {
			if imp == nil {
				continue
			}
			alias, raw_path := _import_alias_and_path(imp)
			loc := Location {
				file_path = file_path,
				line      = imp.pos.line,
				column    = imp.pos.column,
			}
			_append_import(&file_imps, alias, raw_path, loc, alloc)
			already := false
			for &existing in pkg.imports {
				if existing.raw_path == raw_path {
					already = true
					break
				}
			}
			if !already {
				_append_import(&pkg.imports, alias, raw_path, loc, alloc)
			}
		}
		pkg.file_imports[strings.clone(file_path, alloc)] = file_imps

		for stmt in file.decls {
			if stmt == nil {
				continue
			}
			vd, is_vd := stmt.derived.(^ast.Value_Decl)
			if !is_vd || vd.is_mutable || len(vd.names) == 0 || len(vd.values) == 0 {
				continue
			}

			for name_expr, idx in vd.names {
				if idx >= len(vd.values) || name_expr == nil || vd.values[idx] == nil {
					continue
				}
				ident, is_ident := name_expr.derived.(^ast.Ident)
				if !is_ident || ident.name == "" || ident.name == "_" {
					continue
				}
				val_expr := vd.values[idx]

				#partial switch v in val_expr.derived {
				case ^ast.Proc_Lit:
					if v.body == nil {
						continue
					}
					// `sf` may move when `ws.procs` grows; the annotations live in the package.
					file_ann := &ws.packages[pkg_id].files[file_idx].annotations
					proc_id := _register_proc(
						ws,
						pkg_id,
						file_path,
						file_ann,
						file_private,
						ident.name,
						ident.pos,
						vd.docs,
						vd.attributes[:],
						v,
						-1,
					)
					p := &ws.packages[pkg_id]
					if _, exists := p.procs[ident.name]; !exists {
						p.procs[strings.clone(ident.name, alloc)] = proc_id
					}
					_register_nested_procs(ws, pkg_id, file_path, file_ann, file_private, proc_id)

				case ^ast.Proc_Group:
					p := &ws.packages[pkg_id]
					append(
						&p.pending_groups,
						Pending_Group {
							name = strings.clone(ident.name, alloc),
							file_path = strings.clone(file_path, alloc),
							members = v.args,
						},
					)

				case ^ast.Struct_Type,
				     ^ast.Array_Type,
				     ^ast.Distinct_Type,
				     ^ast.Union_Type,
				     ^ast.Matrix_Type,
				     ^ast.Enum_Type,
				     ^ast.Bit_Set_Type,
				     ^ast.Bit_Field_Type,
				     ^ast.Map_Type,
				     ^ast.Dynamic_Array_Type,
				     ^ast.Fixed_Capacity_Dynamic_Array_Type,
				     ^ast.Pointer_Type,
				     ^ast.Proc_Type:
					type_idx := len(ws.types)
					append(
						&ws.types,
						Type_Decl_Info {
							pkg_id = pkg_id,
							name = strings.clone(ident.name, alloc),
							type_expr = val_expr,
							location = Location {
								file_path = strings.clone(file_path, alloc),
								line = ident.pos.line,
								column = ident.pos.column,
							},
							size_bytes = -1,
						},
					)
					p := &ws.packages[pkg_id]
					if _, exists := p.types[ident.name]; !exists {
						p.types[strings.clone(ident.name, alloc)] = type_idx
					}

				case ^ast.Basic_Lit, ^ast.Binary_Expr, ^ast.Paren_Expr, ^ast.Ident:
					p := &ws.packages[pkg_id]
					if _, exists := p.constants[ident.name]; !exists {
						p.constants[strings.clone(ident.name, alloc)] = val_expr
					}
				}
			}
		}
	}
}

/*
Finds the procedure (or procedure group members) that the call `qual.name` refers to from
`file_path` in package `pkg_id`. Unqualified names are looked up in the procedures declared in
`from_proc` and its enclosing procedures first, then in the package.
*/
@(require_results)
resolve_proc_ref :: proc(
	ws: ^Workspace,
	pkg_id: int,
	file_path: string,
	qual: string,
	name: string,
	from_proc := -1,
) -> (
	proc_id: int,
	group_ids: []int,
) {
	if pkg_id < 0 || pkg_id >= len(ws.packages) || name == "" {
		return -1, nil
	}
	pkg := &ws.packages[pkg_id]

	if qual == "" {
		for scope := from_proc; scope >= 0; scope = ws.procs[scope].parent_id {
			if pid, found := ws.procs[scope].local_procs[name]; found {
				return pid, nil
			}
		}
		if pid, found := pkg.procs[name]; found {
			return pid, nil
		}
		if gids, found := pkg.proc_groups[name]; found {
			return -1, gids[:]
		}
		return -1, nil
	}

	target := resolve_import_alias(ws, pkg_id, file_path, qual)
	if target < 0 {
		return -1, nil
	}
	tpkg := &ws.packages[target]
	if pid, found := tpkg.procs[name]; found {
		return pid, nil
	}
	if gids, found := tpkg.proc_groups[name]; found {
		return -1, gids[:]
	}
	return -1, nil
}

/*
Returns the package that import alias `alias` refers to in `file_path`, or -1 when the alias is
unknown or names a package that isn't loaded (such as `core:fmt`).
*/
@(require_results)
resolve_import_alias :: proc(
	ws: ^Workspace,
	pkg_id: int,
	file_path: string,
	alias: string,
) -> int {
	if pkg_id < 0 || pkg_id >= len(ws.packages) {
		return -1
	}
	pkg := &ws.packages[pkg_id]
	if flist, found := pkg.file_imports[file_path]; found {
		for &imp in flist {
			if imp.alias == alias {
				return imp.resolved_id
			}
		}
		return -1
	}
	for &imp in pkg.imports {
		if imp.alias == alias {
			return imp.resolved_id
		}
	}
	return -1
}

/*
Returns the raw import path that `alias` refers to in `file_path` (such as `"core:fmt"` or
`"../../obench"`), or `""` when the file has no such import.
*/
@(require_results)
import_path_of_alias :: proc(
	ws: ^Workspace,
	pkg_id: int,
	file_path: string,
	alias: string,
) -> string {
	if pkg_id < 0 || pkg_id >= len(ws.packages) {
		return ""
	}
	pkg := &ws.packages[pkg_id]
	if flist, found := pkg.file_imports[file_path]; found {
		for &imp in flist {
			if imp.alias == alias {
				return imp.raw_path
			}
		}
	}
	return ""
}

@(private = "file")
_resolve_pending_groups :: proc(ws: ^Workspace) {
	alloc := ws.allocator
	for pkg_id in 0 ..< len(ws.packages) {
		pkg := &ws.packages[pkg_id]
		for &pg in pkg.pending_groups {
			if _, exists := pkg.proc_groups[pg.name]; exists {
				continue
			}
			ids := make([dynamic]int, alloc)
			for member in pg.members {
				qual, name := "", ""
				#partial switch m in member.derived {
				case ^ast.Ident:
					name = m.name
				case ^ast.Selector_Expr:
					if id, ok := m.expr.derived.(^ast.Ident); ok && m.field != nil {
						qual, name = id.name, m.field.name
					}
				}
				pid, _ := resolve_proc_ref(ws, pkg_id, pg.file_path, qual, name)
				if pid >= 0 && !slice.contains(ids[:], pid) {
					append(&ids, pid)
				}
			}
			if len(ids) > 0 {
				pkg.proc_groups[strings.clone(pg.name, alloc)] = ids
			} else {
				delete(ids)
			}
		}
	}
}

@(private = "file")
_find_collection :: proc(ws: ^Workspace, name: string) -> (path: string, ok: bool) {
	for c in ws.collections {
		if c.name == name {
			return c.path, true
		}
	}
	return "", false
}

// Directory an import refers to, or "" when it is a `base:`, `core:`, or `vendor:` package or
// an unknown collection.
@(private = "file")
_import_dir :: proc(ws: ^Workspace, from_dir: string, raw_path: string) -> string {
	if colon := strings.index_byte(raw_path, ':'); colon >= 0 {
		col_name := raw_path[:colon]
		sub_path := raw_path[colon + 1:]
		switch col_name {
		case "base", "core", "vendor":
			return ""
		}
		root, ok := _find_collection(ws, col_name)
		if !ok {
			return ""
		}
		joined, _ := filepath.join({root, sub_path}, context.temp_allocator)
		return joined
	}
	joined, _ := filepath.join({from_dir, raw_path}, context.temp_allocator)
	return joined
}

@(private = "file")
_resolve_import_path :: proc(ws: ^Workspace, from_dir: string, raw_path: string) -> int {
	if dir := _import_dir(ws, from_dir, raw_path); dir != "" {
		if pid, found := ws.pkg_by_dir[dir]; found {
			return pid
		}
		return -1
	}
	// An unknown collection: fall back to a package of the workspace with that path or name.
	if colon := strings.index_byte(raw_path, ':'); colon >= 0 {
		col_name := raw_path[:colon]
		sub_path := raw_path[colon + 1:]
		switch col_name {
		case "base", "core", "vendor":
			return -1
		}
		for &pkg in ws.packages {
			if pkg.rel_dir == sub_path || pkg.name == sub_path {
				return pkg.id
			}
		}
	}
	return -1
}

@(private = "file")
_resolve_workspace_imports :: proc(ws: ^Workspace) {
	for &pkg in ws.packages {
		for &imp in pkg.imports {
			imp.resolved_id = _resolve_import_path(ws, pkg.dir_path, imp.raw_path)
		}
		for _, &flist in pkg.file_imports {
			for &imp in flist {
				imp.resolved_id = _resolve_import_path(ws, pkg.dir_path, imp.raw_path)
			}
		}
	}
	_resolve_pending_groups(ws)
	for i in 0 ..< len(ws.types) {
		info := &ws.types[i]
		if info.size_bytes < 0 {
			info.size_bytes, info.align = type_layout(ws, info.pkg_id, info.type_expr)
		}
	}
}

@(private = "file")
_should_skip_dir :: proc(name: string) -> bool {
	if name == "" || strings.has_prefix(name, ".") {
		return true
	}
	switch name {
	case "bin", "build", "node_modules", "vendor", "dist", "target":
		return true
	}
	return false
}

@(private = "file")
_file_declares_package :: proc(path: string, pkg_name: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return false
	}
	return strings.contains(string(data), fmt.tprintf("package %s", pkg_name))
}

// Reports whether `dir` is a vendored copy of the olint library (`libs/olint`) or of the whole
// repository (`libs/olint` containing `olint/` and `cmd/olint/`).
@(private = "file")
_is_vendored_olint_dir :: proc(dir: string) -> bool {
	cg_file, _ := filepath.join({dir, "callgraph.odin"}, context.temp_allocator)
	if _file_declares_package(cg_file, "olint") {
		return true
	}
	sub_lib, _ := filepath.join({dir, "olint", "callgraph.odin"}, context.temp_allocator)
	sub_cli, _ := filepath.join({dir, "cmd", "olint", "main.odin"}, context.temp_allocator)
	return _file_declares_package(sub_lib, "olint") && os.exists(sub_cli)
}

@(private = "file")
_collect_package_dirs :: proc(
	dir: string,
	is_root: bool,
	root_is_olint_repo: bool,
	include_tests: bool,
	out: ^[dynamic]string,
	alloc: runtime.Allocator,
) {
	if !is_root && !root_is_olint_repo && _is_vendored_olint_dir(dir) {
		return
	}

	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {
		return a.name < b.name
	})

	has_odin := false
	for &fi in entries {
		if fi.type == .Regular && strings.has_suffix(fi.name, ".odin") {
			if !include_tests && strings.has_suffix(fi.name, "_test.odin") {
				continue
			}
			has_odin = true
			break
		}
	}
	if has_odin {
		append(out, strings.clone(dir, alloc))
	}

	for &fi in entries {
		if fi.type == .Directory && !_should_skip_dir(fi.name) {
			child, _ := filepath.join({dir, fi.name}, context.temp_allocator)
			_collect_package_dirs(child, false, root_is_olint_repo, include_tests, out, alloc)
		}
	}
}

@(private = "file")
_new_package :: proc(ws: ^Workspace, dir: string, is_dependency: bool) -> Package_Info {
	alloc := ws.allocator
	return Package_Info {
		id = len(ws.packages),
		dir_path = strings.clone(dir, alloc),
		rel_dir = relative_display_path(ws.root_path, dir, alloc),
		is_dependency = is_dependency,
		annotations = Annotations{forbid_imports = make([dynamic]string, alloc)},
		files = make([dynamic]Source_File, alloc),
		imports = make([dynamic]Import_Entry, alloc),
		file_imports = make(map[string][dynamic]Import_Entry, alloc),
		procs = make(map[string]int, alloc),
		proc_groups = make(map[string][dynamic]int, alloc),
		pending_groups = make([dynamic]Pending_Group, alloc),
		types = make(map[string]int, alloc),
		constants = make(map[string]^ast.Expr, alloc),
	}
}

@(private = "file")
_discard_package :: proc(ws: ^Workspace, pkg: ^Package_Info) {
	alloc := ws.allocator
	destroy_annotations(&pkg.annotations, alloc)
	delete(pkg.name, alloc)
	delete(pkg.dir_path, alloc)
	delete(pkg.rel_dir, alloc)
	delete(pkg.files)
	delete(pkg.imports)
	delete(pkg.file_imports)
	delete(pkg.procs)
	delete(pkg.proc_groups)
	delete(pkg.pending_groups)
	delete(pkg.types)
	delete(pkg.constants)
}

// Parses `src` as file `path` of `pkg`. Returns false when the file isn't part of the build.
@(private = "file")
_add_source_file :: proc(
	ws: ^Workspace,
	p: ^parser.Parser,
	ast_pkg: ^ast.Package,
	pkg: ^Package_Info,
	path: string,
	src: string,
	check_build_tags: bool,
) -> bool {
	NO_POS :: tokenizer.Pos{}
	alloc := ws.allocator
	arena_alloc := runtime.arena_allocator(&ws.ast_arena)
	if strings.trim_space(src) == "" {
		return false
	}

	ast_file: ^ast.File
	parsed_ok: bool
	ftags: parser.File_Tags
	{
		context.allocator = arena_alloc
		ast_file = ast.new(ast.File, NO_POS, NO_POS)
		ast_file.pkg = ast_pkg
		ast_file.src = src
		ast_file.fullpath = strings.clone(path, arena_alloc)
		parsed_ok = parser.parse_file(p, ast_file)
		if parsed_ok {
			ftags = parser.parse_file_tags(ast_file^, arena_alloc)
		}
	}
	if !parsed_ok || ast_file.pkg_decl == nil {
		return false
	}
	if check_build_tags {
		target := parser.Build_Target {
			os   = ODIN_OS,
			arch = ODIN_ARCH,
		}
		if !parser.match_build_tags(ftags, target) {
			return false
		}
	}

	if pkg.name == "" {
		pkg.name = strings.clone(ast_file.pkg_decl.name, alloc)
		ast_pkg.name = pkg.name
	}

	file_ann := parse_annotations(ast_file.docs, nil, alloc)
	_merge_annotations(&pkg.annotations, file_ann, alloc)

	ws.files_count += 1
	append(
		&pkg.files,
		Source_File {
			fullpath = strings.clone(path, alloc),
			ast_file = ast_file,
			annotations = file_ann,
			is_private = ftags.private != .Public,
		},
	)
	return true
}

@(private = "file")
_load_package_from_dir :: proc(
	ws: ^Workspace,
	dir_path: string,
	#by_ptr cfg: Config,
	is_dependency: bool,
) {
	NO_POS :: tokenizer.Pos{}
	entries, err := os.read_all_directory_by_path(dir_path, context.temp_allocator)
	if err != nil {
		return
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {
		return a.name < b.name
	})

	odin_files := make([dynamic]string, context.temp_allocator)
	for &fi in entries {
		if fi.type != .Regular || !strings.has_suffix(fi.name, ".odin") {
			continue
		}
		if (is_dependency || !cfg.include_tests) && strings.has_suffix(fi.name, "_test.odin") {
			continue
		}
		append(&odin_files, fi.fullpath)
	}
	if len(odin_files) == 0 {
		return
	}

	arena_alloc := runtime.arena_allocator(&ws.ast_arena)
	sink := _Parser_Error_Sink {
		errors    = &ws.parse_errors,
		allocator = ws.allocator,
	}
	_active_error_sink = &sink
	defer _active_error_sink = nil

	p := parser.default_parser()
	p.err = _parser_error_handler
	p.warn = _parser_warn_handler

	ast_pkg: ^ast.Package
	{
		context.allocator = arena_alloc
		ast_pkg = ast.new(ast.Package, NO_POS, NO_POS)
		ast_pkg.fullpath = strings.clone(dir_path, arena_alloc)
	}

	pkg_info := _new_package(ws, dir_path, is_dependency)
	for fpath in odin_files {
		src_bytes, read_err := os.read_entire_file(fpath, arena_alloc)
		if read_err != nil {
			continue
		}
		_add_source_file(ws, &p, ast_pkg, &pkg_info, fpath, string(src_bytes), true)
	}

	if len(pkg_info.files) == 0 {
		_discard_package(ws, &pkg_info)
		return
	}

	pkg_id := pkg_info.id
	append(&ws.packages, pkg_info)
	ws.pkg_by_dir[strings.clone(dir_path, ws.allocator)] = pkg_id
	if is_dependency {
		ws.dependencies_count += 1
	}
	_extract_package_declarations(ws, pkg_id)
}

// Loads every package imported by a loaded package but not loaded yet (relative imports and
// imports through configured collections), until nothing new is found.
@(private = "file")
_load_dependencies :: proc(ws: ^Workspace, #by_ptr cfg: Config) {
	for i := 0; i < len(ws.packages); i += 1 {
		dir_path := ws.packages[i].dir_path
		for j := 0; j < len(ws.packages[i].imports); j += 1 {
			raw := ws.packages[i].imports[j].raw_path
			dir := _import_dir(ws, dir_path, raw)
			if dir == "" {
				continue
			}
			if _, loaded := ws.pkg_by_dir[dir]; loaded {
				continue
			}
			if !os.is_directory(dir) {
				continue
			}
			_load_package_from_dir(ws, dir, cfg, true)
		}
	}
}

@(private = "file")
_copy_collections :: proc(ws: ^Workspace, #by_ptr cfg: Config) {
	for c in cfg.collections {
		path := c.path
		if abs, err := os.get_absolute_path(c.path, context.temp_allocator); err == nil {
			path = abs
		}
		append(
			&ws.collections,
			Collection {
				name = strings.clone(c.name, ws.allocator),
				path = strings.clone(path, ws.allocator),
			},
		)
	}
}

/*
Loads all Odin packages under `root_dir` into a new `Workspace`, then the packages they import
from outside `root_dir` (relative imports and `cfg.collections`) as dependencies.
*/
@(require_results)
workspace_load_from_path :: proc(
	root_dir: string,
	#by_ptr cfg: Config,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	ws: Workspace,
	ok: bool,
) {
	abs_root, err := os.get_absolute_path(root_dir, context.temp_allocator)
	if err != nil || !os.is_directory(abs_root) {
		return {}, false
	}

	ws = workspace_create(abs_root, allocator, loc)
	_copy_collections(&ws, cfg)

	pkg_dirs := make([dynamic]string, context.temp_allocator)
	_collect_package_dirs(
		abs_root,
		true,
		_is_vendored_olint_dir(abs_root),
		cfg.include_tests,
		&pkg_dirs,
		context.temp_allocator,
	)
	for dir in pkg_dirs {
		_load_package_from_dir(&ws, dir, cfg, false)
	}
	_load_dependencies(&ws, cfg)
	_resolve_workspace_imports(&ws)
	return ws, true
}

/*
Loads a workspace from in-memory `Virtual_File` entries grouped by their directory path.
Designed for unit testing rules without creating temporary files on disk. Build tags are not
applied.
*/
@(require_results)
workspace_load_virtual :: proc(
	vfiles: []Virtual_File,
	#by_ptr cfg: Config,
	allocator := context.allocator,
	loc := #caller_location,
) -> Workspace {
	NO_POS :: tokenizer.Pos{}
	ws := workspace_create("/virtual", allocator, loc)
	_copy_collections(&ws, cfg)
	arena_alloc := runtime.arena_allocator(&ws.ast_arena)

	sink := _Parser_Error_Sink {
		errors    = &ws.parse_errors,
		allocator = ws.allocator,
	}
	_active_error_sink = &sink
	defer _active_error_sink = nil

	p := parser.default_parser()
	p.err = _parser_error_handler
	p.warn = _parser_warn_handler

	dirs := make([dynamic]string, context.temp_allocator)
	for vf in vfiles {
		dir := filepath.dir(vf.path)
		if !slice.contains(dirs[:], dir) {
			append(&dirs, dir)
		}
	}

	for dir in dirs {
		ast_pkg: ^ast.Package
		{
			context.allocator = arena_alloc
			ast_pkg = ast.new(ast.Package, NO_POS, NO_POS)
			ast_pkg.fullpath = strings.clone(dir, arena_alloc)
		}

		pkg_info := _new_package(&ws, dir, false)
		for vf in vfiles {
			if filepath.dir(vf.path) != dir {
				continue
			}
			src := strings.clone(vf.src, arena_alloc)
			_add_source_file(&ws, &p, ast_pkg, &pkg_info, vf.path, src, false)
		}

		if len(pkg_info.files) == 0 {
			_discard_package(&ws, &pkg_info)
			continue
		}
		pkg_id := pkg_info.id
		append(&ws.packages, pkg_info)
		ws.pkg_by_dir[strings.clone(dir, ws.allocator)] = pkg_id
		_extract_package_declarations(&ws, pkg_id)
	}

	_resolve_workspace_imports(&ws)
	return ws
}

package olint

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

/*
Annotations parsed from doc comments (`// @...` or `/* @... */`) above a declaration or above
`package`, and from `@(zero_alloc)`-style attributes (which the compiler accepts only with
`-custom-attribute:zero_alloc,no_temp_alloc,alloc_safe`).
*/
Annotations :: struct {
	zero_alloc:     bool,
	no_temp_alloc:  bool,
	alloc_safe:     bool,
	allocates_heap: bool,
	allocates_temp: bool,
	ignore_all:     bool,
	ignored_rules:  Rule_Set,
	layer:          string,
	forbid_imports: [dynamic]string,
}

/*
A misspelled annotation or an unknown rule name in `@ignore(...)`, found in a doc comment.
*/
Annotation_Problem :: struct {
	pos:     tokenizer.Pos,
	message: string, // Allocated with the temp allocator
}

// Annotation names olint reads.
@(private = "file")
OLINT_ANNOTATIONS := [?]string {
	"zero_alloc",
	"no_temp_alloc",
	"no_temp",
	"alloc_safe",
	"allow_alloc",
	"allocates",
	"heap_alloc",
	"temp_allocates",
	"temp_alloc",
	"ignore",
	"nolint",
	"olint_ignore",
	"layer",
	"forbid_import",
	"forbid_imports",
}

// Annotations of obench (https://github.com/zeybek/obench), which shares `@zero_alloc`.
@(private = "file")
OBENCH_ANNOTATIONS := [?]string{"group", "params", "threads"}

/*
Frees dynamic memory owned by `ann`.
*/
destroy_annotations :: proc(ann: ^Annotations, allocator := context.allocator) {
	for s in ann.forbid_imports {
		delete(s, allocator)
	}
	delete(ann.forbid_imports)
}

// One `@name` or `@name(args)` token of an annotation line.
@(private = "file")
_Annotation_Token :: struct {
	name:     string, // With `-` normalized to `_` by `_normalized_name`
	args:     string,
	has_args: bool,
	column:   int, // Byte offset of `@` within the line
}

// Splits the next annotation off `rest`. Returns false at the end of the annotations, which is
// the first text that doesn't start with `@`.
@(private = "file")
_next_annotation :: proc(rest: ^string, line_start: string) -> (tok: _Annotation_Token, ok: bool) {
	s := strings.trim_left_space(rest^)
	if s == "" || s[0] != '@' {
		return {}, false
	}
	tok.column = len(line_start) - len(s)
	name_end := 1
	for name_end < len(s) {
		c := s[name_end]
		if c != '_' &&
		   c != '-' &&
		   (c < 'a' || c > 'z') &&
		   (c < 'A' || c > 'Z') &&
		   (c < '0' || c > '9') {
			break
		}
		name_end += 1
	}
	tok.name = s[1:name_end]
	s = s[name_end:]
	if strings.has_prefix(s, "(") {
		close_idx := strings.index_byte(s, ')')
		if close_idx < 0 {
			return {}, false
		}
		tok.has_args = true
		tok.args = s[1:close_idx]
		s = s[close_idx + 1:]
	}
	rest^ = s
	return tok, true
}

@(private = "file")
_normalized_name :: proc(name: string) -> string {
	if strings.index_byte(name, '-') < 0 {
		return name
	}
	out, _ := strings.replace_all(name, "-", "_", context.temp_allocator)
	return out
}

@(private = "file")
_trim_arg :: proc(s: string) -> string {
	return strings.trim(s, " \t\r\n\"'`")
}

@(private = "file")
_apply_annotation :: proc(
	tok: _Annotation_Token,
	out: ^Annotations,
	allocator: runtime.Allocator,
) {
	switch _normalized_name(tok.name) {
	case "zero_alloc":
		out.zero_alloc = true
	case "no_temp_alloc", "no_temp":
		out.no_temp_alloc = true
	case "alloc_safe", "allow_alloc":
		out.alloc_safe = true
	case "allocates", "heap_alloc":
		out.allocates_heap = true
	case "temp_allocates", "temp_alloc":
		out.allocates_temp = true
	case "ignore", "nolint", "olint_ignore":
		if !tok.has_args || strings.trim_space(tok.args) == "" {
			out.ignore_all = true
			out.ignored_rules = ALL_RULES
			return
		}
		rest := tok.args
		for part in strings.split_iterator(&rest, ",") {
			item := _trim_arg(part)
			if item == "all" || item == "*" {
				out.ignore_all = true
				out.ignored_rules = ALL_RULES
			} else if r, ok := parse_rule_id(item); ok {
				out.ignored_rules += {r}
			}
		}
	case "layer":
		if trimmed := _trim_arg(tok.args); trimmed != "" {
			out.layer = trimmed
		}
	case "forbid_import", "forbid_imports":
		rest := tok.args
		for part in strings.split_iterator(&rest, ",") {
			if item := _trim_arg(part); item != "" {
				append(&out.forbid_imports, strings.clone(item, allocator))
			}
		}
	}
}

// Calls `visit` for every annotation token in the annotation lines of `docs`. A line holds
// annotations only when it starts with `@`, so prose that mentions `@zero_alloc` is ignored.
@(private = "file")
_each_annotation :: proc(
	docs: ^ast.Comment_Group,
	data: rawptr,
	visit: proc(tok: _Annotation_Token, pos: tokenizer.Pos, data: rawptr),
) {
	if docs == nil {
		return
	}
	for comment in docs.list {
		body := comment.text
		prefix_len := 0
		switch {
		case strings.has_prefix(body, "//"):
			body = body[2:]
			prefix_len = 2
		case strings.has_prefix(body, "/*"):
			body = strings.trim_suffix(body[2:], "*/")
			prefix_len = 2
		}
		line_no := comment.pos.line
		first_line := true
		for line in strings.split_lines_iterator(&body) {
			text := strings.trim_left_space(line)
			if strings.has_prefix(text, "*") && !strings.has_prefix(text, "*/") {
				text = strings.trim_left_space(text[1:])
			}
			if strings.has_prefix(text, "@") {
				rest := text
				for tok in _next_annotation(&rest, line) {
					pos := tokenizer.Pos {
						file   = comment.pos.file,
						line   = line_no,
						column = tok.column + 1 + (comment.pos.column - 1 + prefix_len if first_line else 0),
					}
					visit(tok, pos, data)
				}
			}
			line_no += 1
			first_line = false
		}
	}
}

/*
Parses doc comments (`docs`) and declaration attributes (`attrs`) into an `Annotations` struct.
*/
@(require_results)
parse_annotations :: proc(
	docs: ^ast.Comment_Group,
	attrs: []^ast.Attribute = nil,
	allocator := context.allocator,
) -> (
	res: Annotations,
) {
	res.forbid_imports = make([dynamic]string, allocator)

	Ctx :: struct {
		out:       ^Annotations,
		allocator: runtime.Allocator,
	}
	ctx := Ctx{&res, allocator}
	_each_annotation(docs, &ctx, proc(tok: _Annotation_Token, pos: tokenizer.Pos, data: rawptr) {
		c := (^Ctx)(data)
		_apply_annotation(tok, c.out, c.allocator)
	})

	for attr in attrs {
		if attr == nil {
			continue
		}
		for elem in attr.elems {
			if elem == nil {
				continue
			}
			name := ""
			#partial switch e in elem.derived {
			case ^ast.Ident:
				name = e.name
			case ^ast.Field_Value:
				if id, ok := e.field.derived.(^ast.Ident); ok {
					name = id.name
				}
			}
			switch name {
			case "zero_alloc":
				res.zero_alloc = true
			case "no_temp_alloc":
				res.no_temp_alloc = true
			case "alloc_safe":
				res.alloc_safe = true
			}
		}
	}
	return
}

// Levenshtein distance between `a` and `b`, ignoring ASCII case.
@(private = "file")
_edit_distance :: proc(a, b: string) -> int {
	if len(a) > 64 || len(b) > 64 {
		return max(len(a), len(b))
	}
	lower :: proc(c: u8) -> u8 {
		return c + 32 if c >= 'A' && c <= 'Z' else c
	}
	prev, curr: [65]int
	for j in 0 ..= len(b) {
		prev[j] = j
	}
	for i in 1 ..= len(a) {
		curr[0] = i
		for j in 1 ..= len(b) {
			cost := 0 if lower(a[i - 1]) == lower(b[j - 1]) else 1
			curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
		}
		prev = curr
	}
	return prev[len(b)]
}

/*
Finds misspelled annotations in `docs` (an unknown `@name` within two edits of an annotation
olint reads) and unknown rule names in `@ignore(...)`. Unknown names that aren't close to an
olint annotation (`@note`, `@see`, obench's `@params`) are left alone. Messages use the temp
allocator.
*/
@(require_results)
find_annotation_problems :: proc(docs: ^ast.Comment_Group) -> []Annotation_Problem {
	out := make([dynamic]Annotation_Problem, context.temp_allocator)
	_each_annotation(docs, &out, proc(tok: _Annotation_Token, pos: tokenizer.Pos, data: rawptr) {
		list := (^[dynamic]Annotation_Problem)(data)
		name := _normalized_name(tok.name)
		for known in OLINT_ANNOTATIONS {
			if name == known {
				if (name == "ignore" || name == "nolint" || name == "olint_ignore") &&
				   tok.has_args {
					rest := tok.args
					for part in strings.split_iterator(&rest, ",") {
						item := _trim_arg(part)
						if item == "" || item == "all" || item == "*" {
							continue
						}
						if _, ok := parse_rule_id(item); !ok {
							append(
								list,
								Annotation_Problem {
									pos = pos,
									message = fmt.tprintf(
										"unknown rule '%s' in @%s(...); see 'olint rules'",
										item,
										tok.name,
									),
								},
							)
						}
					}
				}
				return
			}
		}
		for known in OBENCH_ANNOTATIONS {
			if name == known {
				return
			}
		}
		if len(name) < 4 {
			return
		}
		best, best_dist := "", 3
		for known in OLINT_ANNOTATIONS {
			if d := _edit_distance(name, known); d < best_dist {
				best, best_dist = known, d
			}
		}
		if best != "" {
			append(
				list,
				Annotation_Problem {
					pos = pos,
					message = fmt.tprintf(
						"unknown annotation @%s, did you mean @%s? The check it names is not active",
						tok.name,
						best,
					),
				},
			)
		}
	})
	return out[:]
}

/*
Reports whether `rule` is suppressed by `ann`.
*/
@(require_results)
is_rule_ignored :: proc "contextless" (#by_ptr ann: Annotations, rule: Rule_ID) -> bool {
	return ann.ignore_all || (rule in ann.ignored_rules)
}

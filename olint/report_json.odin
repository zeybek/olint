package olint

import "core:encoding/json"
import "core:io"
import "core:os"
import "core:strings"

/*
Schema version for JSON reports exported by `olint`.
*/
JSON_FORMAT_VERSION :: 1

/*
Root JSON document written by `--json` or `save_json_report`.
*/
Export_Document :: struct {
	format_version:     int `json:"format_version"`,
	olint_version:      string `json:"olint_version"`,
	odin_version:       string `json:"odin_version"`,
	os:                 string `json:"os"`,
	arch:               string `json:"arch"`,
	target_name:        string `json:"target_name"`,
	packages_count:     int `json:"packages_count"`,
	dependencies_count: int `json:"dependencies_count"`,
	files_count:        int `json:"files_count"`,
	procs_count:        int `json:"procs_count"`,
	elapsed_ms:         f64 `json:"elapsed_ms"`,
	error_count:        int `json:"error_count"`,
	warning_count:      int `json:"warning_count"`,
	info_count:         int `json:"info_count"`,
	parse_errors:       []string `json:"parse_errors,omitempty"`,
	diagnostics:        []Diagnostic `json:"diagnostics"`,
}

/*
Builds a serializable `Export_Document` view of `r`.
*/
@(require_results)
export_document :: proc(r: ^Report) -> Export_Document {
	return Export_Document {
		format_version = JSON_FORMAT_VERSION,
		olint_version = VERSION,
		odin_version = ODIN_VERSION,
		os = ODIN_OS_STRING,
		arch = ODIN_ARCH_STRING,
		target_name = r.target_name,
		packages_count = r.packages_count,
		dependencies_count = r.dependencies_count,
		files_count = r.files_count,
		procs_count = r.procs_count,
		elapsed_ms = r.elapsed_ms,
		error_count = r.error_count,
		warning_count = r.warning_count,
		info_count = r.info_count,
		parse_errors = r.parse_errors[:],
		diagnostics = r.diagnostics[:],
	}
}

/*
Writes `r` as indented JSON to `w`.
*/
@(require_results)
write_json_report :: proc(
	w: io.Writer,
	r: ^Report,
	allocator := context.allocator,
) -> Report_Error {
	doc := export_document(r)
	opt := json.Marshal_Options {
		pretty     = true,
		use_spaces = true,
		spaces     = 2,
	}
	data := json.marshal(doc, opt, allocator) or_return
	defer delete(data, allocator)
	_, err := io.write(w, data)
	return err
}

/*
Saves `r` as indented JSON to `path`.
*/
@(require_results)
save_json_report :: proc(r: ^Report, path: string) -> Report_Error {
	sb := strings.builder_make(context.temp_allocator)
	write_json_report(strings.to_writer(&sb), r, context.temp_allocator) or_return
	return os.write_entire_file(path, strings.to_string(sb))
}

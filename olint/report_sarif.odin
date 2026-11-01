package olint

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

/*
SARIF 2.1.0 structures for GitHub Actions Code Scanning integration.
*/
Sarif_Message :: struct {
	text: string `json:"text"`,
}

Sarif_Artifact_Location :: struct {
	uri: string `json:"uri"`,
}

Sarif_Region :: struct {
	start_line:   int `json:"startLine"`,
	start_column: int `json:"startColumn,omitempty"`,
}

Sarif_Physical_Location :: struct {
	artifact_location: Sarif_Artifact_Location `json:"artifactLocation"`,
	region:            Sarif_Region `json:"region"`,
}

Sarif_Location :: struct {
	physical_location: Sarif_Physical_Location `json:"physicalLocation"`,
	message:           Sarif_Message `json:"message,omitempty"`,
}

Sarif_Thread_Flow_Location :: struct {
	location: Sarif_Location `json:"location"`,
}

Sarif_Thread_Flow :: struct {
	locations: []Sarif_Thread_Flow_Location `json:"locations"`,
}

Sarif_Code_Flow :: struct {
	thread_flows: []Sarif_Thread_Flow `json:"threadFlows"`,
}

Sarif_Rule :: struct {
	id:                string `json:"id"`,
	short_description: Sarif_Message `json:"shortDescription"`,
}

Sarif_Driver :: struct {
	name:            string `json:"name"`,
	version:         string `json:"version"`,
	information_uri: string `json:"informationUri"`,
	rules:           []Sarif_Rule `json:"rules"`,
}

Sarif_Tool :: struct {
	driver: Sarif_Driver `json:"driver"`,
}

Sarif_Result :: struct {
	rule_id:    string `json:"ruleId"`,
	level:      string `json:"level"`,
	message:    Sarif_Message `json:"message"`,
	locations:  []Sarif_Location `json:"locations"`,
	code_flows: []Sarif_Code_Flow `json:"codeFlows,omitempty"`,
}

Sarif_Run :: struct {
	tool:    Sarif_Tool `json:"tool"`,
	results: []Sarif_Result `json:"results"`,
}

Sarif_Document :: struct {
	schema:  string `json:"$schema"`,
	version: string `json:"version"`,
	runs:    []Sarif_Run `json:"runs"`,
}

/*
Writes `r` in SARIF 2.1.0 format to `w`.
*/
@(require_results)
write_sarif_report :: proc(
	w: io.Writer,
	r: ^Report,
	allocator := context.temp_allocator,
) -> Report_Error {
	rules := make([dynamic]Sarif_Rule, 0, len(Rule_ID), allocator)
	for rule in Rule_ID {
		append(
			&rules,
			Sarif_Rule {
				id = rule_id_string(rule),
				short_description = Sarif_Message{text = rule_description(rule)},
			},
		)
	}

	results := make([dynamic]Sarif_Result, 0, len(r.diagnostics), allocator)
	for &d in r.diagnostics {
		uri := relative_display_path(r.root_path, d.location.file_path, allocator)
		locs := make([]Sarif_Location, 1, allocator)
		locs[0] = Sarif_Location {
			physical_location = Sarif_Physical_Location {
				artifact_location = Sarif_Artifact_Location{uri = uri},
				region = Sarif_Region {
					start_line = max(d.location.line, 1),
					start_column = max(d.location.column, 1),
				},
			},
		}

		var_flows: []Sarif_Code_Flow = nil
		if len(d.chain) > 0 {
			tf_locs := make([]Sarif_Thread_Flow_Location, len(d.chain), allocator)
			for step, idx in d.chain {
				s_uri := relative_display_path(r.root_path, step.location.file_path, allocator)
				tf_locs[idx] = Sarif_Thread_Flow_Location {
					location = Sarif_Location {
						physical_location = Sarif_Physical_Location {
							artifact_location = Sarif_Artifact_Location{uri = s_uri},
							region = Sarif_Region {
								start_line = max(step.location.line, 1),
								start_column = max(step.location.column, 1),
							},
						},
						message = Sarif_Message {
							text = fmt.aprintf(
								"%s: %s",
								step.symbol,
								step.description,
								allocator = allocator,
							),
						},
					},
				}
			}
			tflows := make([]Sarif_Thread_Flow, 1, allocator)
			tflows[0] = Sarif_Thread_Flow {
				locations = tf_locs,
			}
			cflows := make([]Sarif_Code_Flow, 1, allocator)
			cflows[0] = Sarif_Code_Flow {
				thread_flows = tflows,
			}
			var_flows = cflows
		}

		sarif_level := "warning"
		switch d.severity {
		case .Error:
			sarif_level = "error"
		case .Warning:
			sarif_level = "warning"
		case .Info:
			sarif_level = "note"
		}

		append(
			&results,
			Sarif_Result {
				rule_id = d.rule_name,
				level = sarif_level,
				message = Sarif_Message{text = d.message},
				locations = locs,
				code_flows = var_flows,
			},
		)
	}

	runs := make([]Sarif_Run, 1, allocator)
	runs[0] = Sarif_Run {
		tool = Sarif_Tool {
			driver = Sarif_Driver {
				name = "olint",
				version = VERSION,
				information_uri = "https://github.com/zeybek/olint",
				rules = rules[:],
			},
		},
		results = results[:],
	}

	doc := Sarif_Document {
		schema  = "https://json.schemastore.org/sarif-2.1.0.json",
		version = "2.1.0",
		runs    = runs,
	}

	opt := json.Marshal_Options {
		pretty     = true,
		use_spaces = true,
		spaces     = 2,
	}
	data := json.marshal(doc, opt, allocator) or_return
	_, err := io.write(w, data)
	return err
}

/*
Saves `r` in SARIF 2.1.0 format to `path`.
*/
@(require_results)
save_sarif_report :: proc(r: ^Report, path: string) -> Report_Error {
	sb := strings.builder_make(context.temp_allocator)
	write_sarif_report(strings.to_writer(&sb), r, context.temp_allocator) or_return
	return os.write_entire_file(path, strings.to_string(sb))
}

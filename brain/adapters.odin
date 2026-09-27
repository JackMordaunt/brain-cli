package brain

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "jm:path"

// Transcripts are a second source, and deliberately not vault content: they
// are machine-written, never committed, and their formats belong to other
// people's programs. Each agent's format is one Adapter here; when that agent
// changes its format, its adapter is what changes.

// Turn is one message of one conversation.
Turn :: struct {
	id, ts, role, session, title, cwd, body: string,
}

Adapter :: struct {
	name: string,
	// Every transcript this adapter can see on this machine.
	list: proc(cli: ^Cli) -> []string,
	// The turns of one transcript. A transcript with no title is a headless
	// API run, not a conversation, and yields nothing.
	emit: proc(cli: ^Cli, file: string) -> []Turn,
}

ADAPTERS :: [3]Adapter {
	{name = "claude", list = claude_list, emit = claude_emit},
	{name = "pi", list = pi_list, emit = pi_emit},
	{name = "fixture", list = fixture_list, emit = fixture_emit},
}

// adapters_all names the adapters this machine can use. The fixture one
// exists for the test suite and only shows when it is pointed at a directory.
adapters_all :: proc(cli: ^Cli) -> []string {
	names := make([dynamic]string)
	for a in ADAPTERS {
		if a.name == "fixture" && getenv(cli, "FIXTURE_TRANSCRIPTS") == "" {
			continue
		}
		append(&names, a.name)
	}
	return names[:]
}

find_adapter :: proc(cli: ^Cli, name: string) -> (Adapter, bool) {
	for a in ADAPTERS {
		if a.name == name {
			for known in adapters_all(cli) {
				if known == name {
					return a, true
				}
			}
		}
	}
	return {}, false
}

// ---- claude ---------------------------------------------------------------
// Claude Code transcripts: ~/.claude/projects/<cwd-slug>/<session-id>.jsonl

claude_root :: proc(cli: ^Cli) -> string {
	return path.join(getenv(cli, "CLAUDE_CONFIG_DIR", path.join(cli.home, ".claude")), "projects")
}

claude_list :: proc(cli: ^Cli) -> []string {
	return files_with_suffix(claude_root(cli), ".jsonl")
}

claude_emit :: proc(cli: ^Cli, file: string) -> []Turn {
	text, err := os.read_entire_file_from_path(file, context.allocator)
	if err != nil {
		return nil
	}
	lines := strings.split_lines(string(text))
	sid := filepath.stem(file)

	// The title is on one of two record kinds; the last one written wins.
	title := last_field(lines, `"type":"custom-title"`, "customTitle")
	if title == "" {
		title = last_field(lines, `"type":"ai-title"`, "aiTitle")
	}
	if title == "" {
		return nil
	}
	cwd := ""
	for l in lines {
		if strings.contains(l, `"cwd":"`) {
			cwd = json_string(parse_line(l), "cwd")
			break
		}
	}

	turns := make([dynamic]Turn)
	for l in lines {
		v := parse_line(l)
		obj, is_obj := v.(json.Object)
		if !is_obj {
			continue
		}
		kind := json_string(v, "type")
		if kind != "user" && kind != "assistant" {
			continue
		}
		if json_bool(v, "isSidechain") || json_bool(v, "isMeta") {
			continue
		}
		if ut := json_string(v, "userType"); ut != "" && ut != "external" {
			continue
		}
		body := content_text(obj["message"])
		skip := CLAUDE_SKIP
		if body == "" || skipped_prefix(body, skip[:]) {
			continue
		}
		id := json_string(v, "uuid")
		if id == "" {
			continue
		}
		append(
			&turns,
			Turn {
				id = id,
				ts = json_string(v, "timestamp"),
				role = kind,
				session = sid,
				title = title,
				cwd = cwd,
				body = collapse_space(body),
			},
		)
	}
	return turns[:]
}

CLAUDE_SKIP :: [6]string {
	"<command-name>",
	"<local-command-stdout>",
	"<command-message>",
	"<system-reminder>",
	"<function_results>",
	"Caveat:",
}

// ---- pi -------------------------------------------------------------------
// pi transcripts: ~/.pi/agent/sessions/<cwd-slug>/<timestamp>_<id>.jsonl

pi_root :: proc(cli: ^Cli) -> string {
	return path.join(getenv(cli, "PI_HOME", path.join(cli.home, ".pi")), "agent", "sessions")
}

pi_list :: proc(cli: ^Cli) -> []string {
	return files_with_suffix(pi_root(cli), ".jsonl")
}

pi_emit :: proc(cli: ^Cli, file: string) -> []Turn {
	text, err := os.read_entire_file_from_path(file, context.allocator)
	if err != nil {
		return nil
	}
	lines := strings.split_lines(string(text))
	if len(lines) == 0 {
		return nil
	}
	title := ""
	for l in lines {
		if strings.contains(l, `"conversation-title"`) {
			if t := json_string(parse_line(l), "data", "title"); t != "" {
				title = t
			}
		}
	}
	if title == "" {
		title = last_field(lines, `"type":"session_info"`, "name")
	}
	if title == "" {
		return nil
	}
	head := parse_line(lines[0])
	sid := json_string(head, "id")
	if sid == "" {
		sid = filepath.stem(file)
		if i := strings.index_byte(sid, '_'); i >= 0 {
			sid = sid[i + 1:]
		}
	}
	cwd := json_string(head, "cwd")

	turns := make([dynamic]Turn)
	for l in lines {
		v := parse_line(l)
		obj, is_obj := v.(json.Object)
		if !is_obj || json_string(v, "type") != "message" {
			continue
		}
		role := json_string(v, "message", "role")
		if role != "user" && role != "assistant" {
			continue
		}
		body := content_text(obj["message"])
		skip := PI_SKIP
		if body == "" || skipped_prefix(body, skip[:]) {
			continue
		}
		id := json_string(v, "id")
		if id == "" {
			continue
		}
		append(
			&turns,
			Turn {
				id = id,
				ts = json_string(v, "timestamp"),
				role = role,
				session = sid,
				title = title,
				cwd = cwd,
				body = collapse_space(body),
			},
		)
	}
	return turns[:]
}

PI_SKIP :: [2]string{"<system-reminder>", "<command-name>"}

// ---- fixture --------------------------------------------------------------
// A source the test suite owns: TSV files under FIXTURE_TRANSCRIPTS with the
// columns id, timestamp, role, session, title, cwd, body.

fixture_list :: proc(cli: ^Cli) -> []string {
	root := getenv(cli, "FIXTURE_TRANSCRIPTS")
	if root == "" {
		return nil
	}
	return files_with_suffix(root, ".tsv")
}

fixture_emit :: proc(cli: ^Cli, file: string) -> []Turn {
	text, err := os.read_entire_file_from_path(file, context.allocator)
	if err != nil {
		return nil
	}
	turns := make([dynamic]Turn)
	rest := string(text)
	for raw in strings.split_lines_iterator(&rest) {
		cols := strings.split(strings.trim_suffix(raw, "\r"), "\t")
		if len(cols) < 7 {
			continue
		}
		append(
			&turns,
			Turn {
				id = cols[0],
				ts = cols[1],
				role = cols[2],
				session = cols[3],
				title = cols[4],
				cwd = cols[5],
				body = strings.join(cols[6:], " "),
			},
		)
	}
	return turns[:]
}

// ---- shared ---------------------------------------------------------------

files_with_suffix :: proc(root, suffix: string) -> []string {
	if !os.is_dir(root) {
		return nil
	}
	all, err := path.walk(root)
	if err != nil {
		return nil
	}
	files := make([dynamic]string)
	for f in all {
		if strings.has_suffix(f, suffix) {
			append(&files, f)
		}
	}
	return files[:]
}

parse_line :: proc(line: string) -> json.Value {
	v, err := json.parse_string(line)
	if err != nil {
		return nil
	}
	return v
}

// last_field parses the last line containing marker and returns its field.
last_field :: proc(lines: []string, marker, field: string) -> string {
	#reverse for l in lines {
		if strings.contains(l, marker) {
			return json_string(parse_line(l), field)
		}
	}
	return ""
}

// json_string walks keys into nested objects and returns the string there.
json_string :: proc(v: json.Value, keys: ..string) -> string {
	cur := v
	for k in keys {
		obj, ok := cur.(json.Object)
		if !ok {
			return ""
		}
		cur = obj[k]
	}
	s, ok := cur.(json.String)
	return ok ? string(s) : ""
}

json_bool :: proc(v: json.Value, key: string) -> bool {
	obj, ok := v.(json.Object)
	if !ok {
		return false
	}
	b, is_bool := obj[key].(json.Boolean)
	return is_bool && bool(b)
}

// content_text is a message's text: its content when that is a string, or
// the text blocks of a content array joined with newlines.
content_text :: proc(message: json.Value) -> string {
	msg, ok := message.(json.Object)
	if !ok {
		return ""
	}
	#partial switch c in msg["content"] {
	case json.String:
		return string(c)
	case json.Array:
		parts := make([dynamic]string)
		for item in c {
			if json_string(item, "type") == "text" {
				append(&parts, json_string(item, "text"))
			}
		}
		return strings.join(parts[:], "\n")
	}
	return ""
}

skipped_prefix :: proc(body: string, prefixes: []string) -> bool {
	for p in prefixes {
		if strings.has_prefix(body, p) {
			return true
		}
	}
	return false
}

// collapse_space turns every run of whitespace into one space.
collapse_space :: proc(s: string) -> string {
	b := strings.builder_make()
	in_space := false
	for c in s {
		switch c {
		case ' ', '\t', '\n', '\r', '\v', '\f':
			in_space = true
		case:
			if in_space && strings.builder_len(b) > 0 {
				strings.write_byte(&b, ' ')
			}
			in_space = false
			strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}

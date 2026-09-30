/*
Package term decides how much decoration an output stream can take, and
writes it. A command that is read by agents as often as by people prints
plain text unless a person is plainly watching: stdout is a terminal, no
agent announced itself, and neither NO_COLOR nor TERM=dumb asks otherwise.
Plain is the zero value, so a Style nobody set writes no escape codes.

	style := term.detect(terminal.is_terminal(os.stdout))
	term.paint(&b, style, {.Bold}, "Ask")          // bold on a terminal, "Ask" in a pipe
	term.paint(&b, style, {.Dim}, "brain")
	if term.agent() != "" { ... }                  // an agent set AI_AGENT, CLAUDECODE, ...

Importing this package imports core:terminal, whose init turns on virtual
terminal processing for a Windows console (core/terminal/terminal_windows.odin),
so the codes it writes render there too.
*/
package term

import "core:os"
import "core:strings"
import "core:terminal"

// Style is what one stream may carry. depth .None means plain: no escape
// codes at all, which is what a pipe, a file and an agent get.
Style :: struct {
	depth: terminal.Color_Depth,
}

// Mode is a person's explicit choice, from a --color flag or a setting.
// Auto leaves the decision to detect.
Mode :: enum {
	Auto,
	Always,
	Never,
}

// Lookup reads an environment variable, "" when unset. data is passed
// through, so a caller can consult its own overrides before the process
// environment.
Lookup :: #type proc(key: string, data: rawptr) -> string

// AGENT_VARS are what coding agents set in the environment of the commands
// they run: Claude Code 2.1.281 sets AI_AGENT=claude-code_2-1-281_agent and
// CLAUDECODE=1, and the Codex 0.154.0 binary names CODEX_SANDBOX and
// CODEX_SANDBOX_NETWORK_DISABLED (both seen 2026-09-30). Claude Code also
// pipes stdout, which detect catches without any of these; the variables
// cover an agent that runs commands in a pseudo-terminal.
AGENT_VARS :: [?]string{"AI_AGENT", "CLAUDECODE", "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED"}

// parse_mode reads auto, always or never.
parse_mode :: proc(s: string) -> (Mode, bool) {
	switch s {
	case "auto":
		return .Auto, true
	case "always":
		return .Always, true
	case "never":
		return .Never, true
	}
	return .Auto, false
}

// agent names the first agent variable set, "" when none is.
agent :: proc(lookup: Lookup = os_lookup, data: rawptr = nil) -> string {
	for k in AGENT_VARS {
		if lookup(k, data) != "" {
			return k
		}
	}
	return ""
}

// detect decides the style for a stream. An explicit mode wins; after that
// NO_COLOR and TERM=dumb mean plain and CLICOLOR_FORCE means styled; in Auto
// the stream must be a terminal and no agent may have announced itself.
detect :: proc(tty: bool, mode := Mode.Auto, lookup: Lookup = os_lookup, data: rawptr = nil) -> Style {
	switch mode {
	case .Never:
		return {}
	case .Always:
		return {depth = max(env_depth(lookup, data), terminal.Color_Depth.Three_Bit)}
	case .Auto:
	}
	if lookup("NO_COLOR", data) != "" || lookup("TERM", data) == "dumb" {
		return {}
	}
	if f := lookup("CLICOLOR_FORCE", data); f != "" && f != "0" {
		return {depth = max(env_depth(lookup, data), terminal.Color_Depth.Three_Bit)}
	}
	if !tty || agent(lookup, data) != "" {
		return {}
	}
	depth := env_depth(lookup, data)
	when ODIN_OS == .Windows {
		// core:terminal found out whether this console took virtual
		// terminal processing, which no variable says.
		depth = max(depth, terminal.color_depth)
	}
	return {depth = depth}
}

// env_depth is the colour depth the environment advertises. It assumes any
// TERM other than dumb takes the SGR attributes and the eight base colours,
// which is all bold and dim need.
env_depth :: proc(lookup: Lookup, data: rawptr) -> terminal.Color_Depth {
	ct := lookup("COLORTERM", data)
	if ct == "truecolor" || ct == "24bit" || lookup("WT_SESSION", data) != "" {
		return .True_Color
	}
	t := lookup("TERM", data)
	switch {
	case t == "" || t == "dumb":
		return .None
	case strings.contains(t, "-truecolor") || strings.contains(t, "-direct"):
		return .True_Color
	case strings.contains(t, "-256color"):
		return .Eight_Bit
	}
	return .Three_Bit
}

os_lookup :: proc(key: string, _: rawptr) -> string {
	v, _ := os.lookup_env(key, context.temp_allocator)
	return v
}

// styled reports whether the style carries escape codes at all.
styled :: proc(s: Style) -> bool {
	return s.depth != .None
}

Attr :: enum {
	Bold,
	Dim,
	Italic,
	Underline,
}

Attrs :: bit_set[Attr]

// paint writes text with the attributes set, then resets them. A plain style
// writes the text alone.
paint :: proc(b: ^strings.Builder, s: Style, attrs: Attrs, text: string) {
	if !styled(s) || attrs == {} || text == "" {
		strings.write_string(b, text)
		return
	}
	strings.write_string(b, "\x1b[")
	first := true
	for a in attrs {
		if !first {
			strings.write_byte(b, ';')
		}
		first = false
		switch a {
		case .Bold:
			strings.write_byte(b, '1')
		case .Dim:
			strings.write_byte(b, '2')
		case .Italic:
			strings.write_byte(b, '3')
		case .Underline:
			strings.write_byte(b, '4')
		}
	}
	strings.write_byte(b, 'm')
	strings.write_string(b, text)
	strings.write_string(b, "\x1b[0m")
}

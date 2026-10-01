package brain

import "core:os"
import "core:strings"

// A harness is a program that runs an agent: Claude Code, pi, and the
// next one. Each has its own way to be told to run brain at a session's
// start, before a prompt and when the agent would stop, and its own shape
// for what it hands over and what it takes back. Everything brain does
// with those moments is one of three commands that know no harness:
// pack, prime and settle, driven by plain flags. A Harness adapter is the
// thin layer that registers them with its program, turns the program's
// input into a Hook_Event, and words a settle reply the way the program
// listens. Adding a harness is one file, like adding a transcript
// adapter in brain/adapters.odin.

Hook_Kind :: enum {
	Prompt, // what the vault knows about a prompt
	Stop, // the agent would stop; settle may ask for one more turn
}

// Hook_Event is one moment in a session, however the harness said it.
Hook_Event :: struct {
	kind:       Hook_Kind,
	prompt:     string,
	session:    string,
	transcript: string, // the session's file on disk, for settle to read
	cwd:        string,
	continuing: bool, // the stop is already a continuation settle asked for
}

// Hook_Registration is one hook a harness reports: its event, the brain
// subcommand it runs, and whether it is on.
Hook_Registration :: struct {
	event, sub: string,
	on:         bool,
}

Harness :: struct {
	name:        string,
	// The transcript adapter in ADAPTERS that reads this harness's sessions.
	transcripts: string,
	// Whether this machine has the harness at all.
	detect:      proc(cli: ^Cli) -> bool,
	// The harness's own hook input, when it hands one over on stdin.
	parse:       proc(text: string) -> (Hook_Event, bool),
	// How settle says "one more turn, for this".
	reply:       proc(reason: string) -> string,
	register:    proc(cli: ^Cli, exe: string),
	unregister:  proc(cli: ^Cli),
	status:      proc(cli: ^Cli) -> []Hook_Registration,
}

HARNESSES :: [2]Harness {
	{
		name = "claude",
		transcripts = "claude",
		detect = claude_detect,
		parse = claude_parse,
		reply = claude_reply,
		register = claude_register,
		unregister = claude_unregister,
		status = claude_status,
	},
	{
		name = "pi",
		transcripts = "pi",
		detect = pi_detect,
		parse = pi_parse,
		reply = pi_reply,
		register = pi_register,
		unregister = pi_unregister,
		status = pi_status,
	},
}

harness_named :: proc(name: string) -> (Harness, bool) {
	for h in HARNESSES {
		if h.name == name {
			return h, true
		}
	}
	return {}, false
}

// harnesses_here is every harness this machine has, or the one named.
harnesses_here :: proc(cli: ^Cli, only: string) -> []Harness {
	found := make([dynamic]Harness)
	for h in HARNESSES {
		if only != "" ? h.name == only : h.detect(cli) {
			append(&found, h)
		}
	}
	return found[:]
}

// hooks_apply registers brain with every harness here, or the one named.
hooks_apply :: proc(cli: ^Cli, exe: string, only := "") {
	for h in harnesses_here(cli, only) {
		h.register(cli, exe)
	}
}

hooks_remove :: proc(cli: ^Cli, only := "") {
	for h in harnesses_here(cli, only) {
		h.unregister(cli)
	}
}

// hook_event is the moment a prime or settle was called for: from the
// flags when the caller gave them, else from the harness's own input on
// stdin, recognised by the harness named or by its shape.
hook_event :: proc(cli: ^Cli, kind: Hook_Kind, flags: Hook_Event, harness: string) -> (ev: Hook_Event, h: Harness, ok: bool) {
	ev = flags
	ev.kind = kind
	if ev.session == "" {
		ev.session = session_id(cli)
	}
	if harness != "" {
		h, ok = harness_named(harness)
		if !ok {
			return
		}
	}
	// Flags carried the event; nothing to read.
	if (kind == .Prompt && ev.prompt != "") || (kind == .Stop && ev.transcript != "") {
		if !ok {
			h, ok = harness_named("claude")
		}
		return ev, h, true
	}
	text := read_stdin(cli)
	if harness == "" {
		for cand in HARNESSES {
			if parsed, is := cand.parse(text); is {
				parsed.kind = kind
				if parsed.session == "" {
					parsed.session = ev.session
				}
				return parsed, cand, true
			}
		}
		if kind == .Prompt && strings.trim_space(text) != "" {
			// Plain text on stdin is the prompt itself.
			ev.prompt = text
			h, _ = harness_named("claude")
			return ev, h, true
		}
		return ev, h, false
	}
	parsed, is := h.parse(text)
	if !is {
		return ev, h, false
	}
	parsed.kind = kind
	if parsed.session == "" {
		parsed.session = ev.session
	}
	return parsed, h, true
}

// read_stdin is what the harness handed over, or what a test set.
read_stdin :: proc(cli: ^Cli) -> string {
	if cli.has_stdin {
		return cli.stdin
	}
	b := strings.builder_make()
	buf: [16384]byte
	for {
		n, err := os.read(os.stdin, buf[:])
		if n > 0 {
			strings.write_bytes(&b, buf[:n])
		}
		if err != nil || n == 0 {
			break
		}
	}
	return strings.to_string(b)
}

// wants_stdin says whether a command line reads a harness's input on
// stdin: settle and prime do unless their flags already carry the event.
wants_stdin :: proc(args: []string) -> bool {
	if args[0] != "prime" && args[0] != "settle" {
		return false
	}
	skip := false
	for a in args[1:] {
		if skip {
			skip = false
			continue
		}
		switch a {
		case "--budget", "--harness", "--cwd":
			skip = true
		case "--session", "--transcript":
			return false
		case:
			if !strings.has_prefix(a, "-") {
				return false
			}
		}
	}
	return true
}

// cmd_hooks shows which hooks are registered with which harness, and
// turns them on or off; --harness names one, else every harness here.
// On needs this binary's own path, the way install writes it.
cmd_hooks :: proc(cli: ^Cli, args: []string) -> int {
	usage := "usage: brain hooks [on|off] [--harness claude|pi]"
	action, only := "", ""
	rest := args
	for len(rest) > 0 {
		arg := rest[0]
		rest = rest[1:]
		switch arg {
		case "on", "off":
			if action != "" {
				return fail(cli, usage)
			}
			action = arg
		case "--harness":
			if len(rest) == 0 {
				return fail(cli, usage)
			}
			only = rest[0]
			rest = rest[1:]
			if _, known := harness_named(only); !known {
				return fail(cli, strings.concatenate({"no such harness: ", only, " (have: claude, pi)"}))
			}
		case:
			return fail(cli, usage)
		}
	}
	switch action {
	case "off":
		hooks_remove(cli, only)
	case "on":
		exe := getenv(cli, "BRAIN_EXE")
		if exe == "" {
			found, err := os.get_executable_path(context.allocator)
			if err != nil {
				return fail(cli, "cannot find this binary's own path")
			}
			exe = found
		}
		hooks_apply(cli, posix_path(exe), only)
	}
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		for h in harnesses_here(cli, only) {
			jw_key(&w, h.name)
			jw_obj(&w)
			for s in h.status(cli) {
				jw_field_bool(&w, s.sub, s.on)
			}
			jw_end_obj(&w)
		}
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	for h in harnesses_here(cli, only) {
		for s in h.status(cli) {
			outf(cli, "%-7s %-18s brain %-7s %s\n", h.name, s.event, s.sub, s.on ? "on" : "off")
		}
	}
	return 0
}

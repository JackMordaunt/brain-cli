package brain

import "core:encoding/json"
import "core:os"
import "core:strings"

import "jm:path"

// Claude Code runs hooks at points in a session and adds what a command
// hook prints on exit 0 to the session's context
// (code.claude.com/docs/en/hooks). The installer registers three:
//
//	SessionStart      brain pack    what the vault knows about this repository
//	UserPromptSubmit  brain prime   what it knows about this prompt
//	Stop              brain settle  once per session, ask for what was settled
//
// Each is written into ~/.claude/settings.json beside whatever is already
// there and recognised by its command, so installing twice adds nothing,
// uninstall removes only them, and `brain hooks off` turns them off
// without touching anyone else's.

HOOK_TIMEOUT :: 10

// Hook is one registration: the event, its matcher where the event takes
// one, the subcommand, and the phrase its command line is recognised by.
Hook :: struct {
	event, matcher, sub, mark: string,
}

HOOKS_CLAUDE :: [3]Hook {
	{event = "SessionStart", matcher = "startup|clear|compact", sub = "pack", mark = " pack 2>/dev/null"},
	{event = "UserPromptSubmit", sub = "prime", mark = " prime 2>/dev/null"},
	{event = "Stop", sub = "settle", mark = " settle 2>/dev/null"},
}

claude_settings :: proc(cli: ^Cli) -> string {
	return path.join(cli.home, ".claude", "settings.json")
}

// hook_command is the shell line a hook runs: a miss prints nothing and
// the session goes on, so a repository the vault knows nothing about costs
// no error.
hook_command :: proc(exe: string, sub := "pack") -> string {
	return strings.concatenate({exe, " ", sub, " 2>/dev/null || true"})
}

// hook_apply adds the hooks to Claude Code's user settings, creating the
// file when there is none. A file that does not parse is left alone and
// named, since a bad write there would take every hook with it.
hook_apply :: proc(cli: ^Cli, exe: string) {
	file := claude_settings(cli)
	root, ok := settings_load(cli, file)
	if !ok {
		return
	}
	changed := false
	hooks_claude := HOOKS_CLAUDE
	for h in hooks_claude {
		if hook_present(root, h) {
			say(cli, "%s: brain %s %s hook present", file, h.sub, h.event)
			continue
		}
		hooks, has_hooks := root["hooks"].(json.Object)
		if !has_hooks {
			hooks = make(json.Object)
		}
		entries, has_entries := hooks[h.event].(json.Array)
		if !has_entries {
			entries = make(json.Array)
		}
		cmd := make(json.Object)
		cmd["type"] = json.String("command")
		cmd["command"] = json.String(hook_command(exe, h.sub))
		cmd["timeout"] = json.Integer(HOOK_TIMEOUT)
		inner := make(json.Array)
		append(&inner, json.Value(cmd))
		entry := make(json.Object)
		if h.matcher != "" {
			entry["matcher"] = json.String(h.matcher)
		}
		entry["hooks"] = json.Value(inner)
		append(&entries, json.Value(entry))
		hooks[h.event] = json.Value(entries)
		root["hooks"] = json.Value(hooks)
		say(cli, "%s: brain %s %s hook added", file, h.sub, h.event)
		changed = true
	}
	if changed {
		settings_save(cli, file, root)
	}
}

// hook_remove takes the hooks out again, and only them.
hook_remove :: proc(cli: ^Cli) {
	file := claude_settings(cli)
	if !path.exists(file) {
		return
	}
	root, ok := settings_load(cli, file)
	if !ok {
		return
	}
	changed := false
	hooks_claude := HOOKS_CLAUDE
	for h in hooks_claude {
		if !hook_present(root, h) {
			continue
		}
		hooks := root["hooks"].(json.Object)
		entries := hooks[h.event].(json.Array)
		kept := make(json.Array)
		for e in entries {
			if !entry_is_ours(e, h) {
				append(&kept, e)
			}
		}
		hooks[h.event] = json.Value(kept)
		say(cli, "%s: brain %s %s hook removed", file, h.sub, h.event)
		changed = true
	}
	if changed {
		settings_save(cli, file, root)
	}
}

// hook_present reports whether the event has an entry that is this hook.
hook_present :: proc(root: json.Object, h: Hook) -> bool {
	hooks, ok := root["hooks"].(json.Object)
	if !ok {
		return false
	}
	entries, has := hooks[h.event].(json.Array)
	if !has {
		return false
	}
	for e in entries {
		if entry_is_ours(e, h) {
			return true
		}
	}
	return false
}

// entry_is_ours matches an entry whose every command is this hook's,
// which is only the one the installer wrote.
entry_is_ours :: proc(e: json.Value, h: Hook) -> bool {
	entry, ok := e.(json.Object)
	if !ok {
		return false
	}
	inner, has := entry["hooks"].(json.Array)
	if !has || len(inner) == 0 {
		return false
	}
	for c in inner {
		cmd, is_obj := c.(json.Object)
		if !is_obj {
			return false
		}
		s, is_str := cmd["command"].(json.String)
		if !is_str || !strings.contains(string(s), h.mark) {
			return false
		}
	}
	return true
}

// cmd_hooks shows which hooks are registered, and turns them all on or
// off. On needs this binary's own path, the way install writes it.
cmd_hooks :: proc(cli: ^Cli, args: []string) -> int {
	if len(args) > 1 || (len(args) == 1 && args[0] != "on" && args[0] != "off") {
		return fail(cli, "usage: brain hooks [on|off]")
	}
	if len(args) == 1 {
		if args[0] == "off" {
			hook_remove(cli)
		} else {
			exe := getenv(cli, "BRAIN_EXE")
			if exe == "" {
				found, err := os.get_executable_path(context.allocator)
				if err != nil {
					return fail(cli, "cannot find this binary's own path")
				}
				exe = found
			}
			hook_apply(cli, posix_path(exe))
		}
	}
	file := claude_settings(cli)
	root, ok := settings_load(cli, file)
	if !ok {
		return 1
	}
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		hooks_claude := HOOKS_CLAUDE
		for h in hooks_claude {
			jw_field_bool(&w, h.sub, hook_present(root, h))
		}
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	hooks_claude := HOOKS_CLAUDE
	for h in hooks_claude {
		outf(cli, "%-18s brain %-7s %s\n", h.event, h.sub, hook_present(root, h) ? "on" : "off")
	}
	return 0
}

// settings_load parses the settings file, or returns an empty object when
// there is none. ok is false when the file exists and does not parse.
settings_load :: proc(cli: ^Cli, file: string) -> (root: json.Object, ok: bool) {
	text, exists := read_text(file)
	if !exists || strings.trim_space(text) == "" {
		return make(json.Object), true
	}
	v, err := json.parse(transmute([]byte)text, parse_integers = true)
	if err != nil {
		note(cli, "%s does not parse (%v); add the SessionStart hook by hand: %s", file, err, hook_command("brain"))
		return nil, false
	}
	obj, is_obj := v.(json.Object)
	if !is_obj {
		note(cli, "%s is not a JSON object; left alone", file)
		return nil, false
	}
	return obj, true
}

settings_save :: proc(cli: ^Cli, file: string, root: json.Object) {
	if cli.dry {
		return
	}
	data, err := json.marshal(json.Value(root), {pretty = true, use_spaces = true, spaces = 2})
	if err != nil {
		note(cli, "cannot encode %s: %v", file, err)
		return
	}
	path.mkdirs(path.dir(file))
	if werr := path.write(file, strings.concatenate({string(data), "\n"})); werr != nil {
		note(cli, "cannot write %s: %v", file, werr)
	}
}

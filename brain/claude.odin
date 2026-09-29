package brain

import "core:encoding/json"
import "core:strings"

import "jm:path"

// Claude Code runs a SessionStart hook when a session starts, is cleared or
// is compacted, and adds what the hook prints on exit 0 to the session's
// context (code.claude.com/docs/en/hooks, "SessionStart"). The installer
// registers `brain pack` as one, so every session in a repository
// opens with what the vault knows about it. The hook is written into
// ~/.claude/settings.json beside whatever is already there; it is recognised
// by its command, so installing twice adds nothing and uninstall removes
// only it.

HOOK_MATCHER :: "startup|clear|compact"
HOOK_TIMEOUT :: 10

claude_settings :: proc(cli: ^Cli) -> string {
	return path.join(cli.home, ".claude", "settings.json")
}

// hook_command is the shell line the hook runs: a miss prints nothing and
// the session goes on, so a repository the vault knows nothing about costs
// no error.
hook_command :: proc(exe: string) -> string {
	return strings.concatenate({exe, " pack 2>/dev/null || true"})
}

// hook_apply adds the SessionStart hook to Claude Code's user settings,
// creating the file when there is none. A file that does not parse is left
// alone and named, since a bad write there would take every hook with it.
hook_apply :: proc(cli: ^Cli, exe: string) {
	file := claude_settings(cli)
	root, ok := settings_load(cli, file)
	if !ok {
		return
	}
	if hook_present(root) {
		say(cli, "%s: brain pack SessionStart hook present", file)
		return
	}
	hooks, has_hooks := root["hooks"].(json.Object)
	if !has_hooks {
		hooks = make(json.Object)
	}
	starts, has_starts := hooks["SessionStart"].(json.Array)
	if !has_starts {
		starts = make(json.Array)
	}
	cmd := make(json.Object)
	cmd["type"] = json.String("command")
	cmd["command"] = json.String(hook_command(exe))
	cmd["timeout"] = json.Integer(HOOK_TIMEOUT)
	inner := make(json.Array)
	append(&inner, json.Value(cmd))
	entry := make(json.Object)
	entry["matcher"] = json.String(HOOK_MATCHER)
	entry["hooks"] = json.Value(inner)
	append(&starts, json.Value(entry))
	hooks["SessionStart"] = json.Value(starts)
	root["hooks"] = json.Value(hooks)
	say(cli, "%s: brain pack SessionStart hook added", file)
	settings_save(cli, file, root)
}

// hook_remove takes the hook out again, and only it.
hook_remove :: proc(cli: ^Cli) {
	file := claude_settings(cli)
	if !path.exists(file) {
		return
	}
	root, ok := settings_load(cli, file)
	if !ok || !hook_present(root) {
		return
	}
	hooks := root["hooks"].(json.Object)
	starts := hooks["SessionStart"].(json.Array)
	kept := make(json.Array)
	for e in starts {
		if !entry_is_ours(e) {
			append(&kept, e)
		}
	}
	hooks["SessionStart"] = json.Value(kept)
	say(cli, "%s: brain pack SessionStart hook removed", file)
	settings_save(cli, file, root)
}

// hook_present reports whether any SessionStart entry is the pack hook.
hook_present :: proc(root: json.Object) -> bool {
	hooks, ok := root["hooks"].(json.Object)
	if !ok {
		return false
	}
	starts, has := hooks["SessionStart"].(json.Array)
	if !has {
		return false
	}
	for e in starts {
		if entry_is_ours(e) {
			return true
		}
	}
	return false
}

// entry_is_ours matches a SessionStart entry whose every command is a
// brain pack, which is only the one the installer wrote.
entry_is_ours :: proc(e: json.Value) -> bool {
	entry, ok := e.(json.Object)
	if !ok {
		return false
	}
	inner, has := entry["hooks"].(json.Array)
	if !has || len(inner) == 0 {
		return false
	}
	for h in inner {
		cmd, is_obj := h.(json.Object)
		if !is_obj {
			return false
		}
		c, is_str := cmd["command"].(json.String)
		if !is_str || !strings.contains(string(c), " pack 2>/dev/null") {
			return false
		}
	}
	return true
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

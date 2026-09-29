package brain

import "core:strconv"
import "core:strings"

import "jm:path"
import "jm:sqlite3"

// The coding agents in TARGETS each read a markdown file in a repository
// before they start, at a path of their own, per their docs cited beside
// each row. `brain export <agent>` writes the repository's
// pack into that file, so the vault is the durable store and the agent's
// file a view of it: regenerate it after the vault changes and every agent
// opens with the same facts. Shared files get a managed block beside
// whatever else is there; files brain owns outright are written whole, with
// the frontmatter that agent documents.

// Target is one agent's file. own is true when the whole file is brain's.
Target :: struct {
	name, file, head: string,
	own:              bool,
}

TARGETS :: [7]Target {
	// code.claude.com/docs/en/memory
	{name = "claude", file = "CLAUDE.md"},
	// agents.md; the readers are listed in AGENTS_MD_READERS
	{name = "agents", file = "AGENTS.md"},
	// docs.github.com/copilot/customizing-copilot/adding-custom-instructions-for-github-copilot
	{name = "copilot", file = ".github/copilot-instructions.md"},
	// geminicli.com/docs/cli/gemini-md
	{name = "gemini", file = "GEMINI.md"},
	// cursor.com/docs/rules: frontmatter description, globs, alwaysApply
	{name = "cursor", file = ".cursor/rules/brain.mdc", own = true, head = "---\ndescription: memory for this repository, from the Brain vault\nalwaysApply: true\n---\n"},
	// docs.cline.bot/customization/cline-rules: every file under .clinerules/
	{name = "cline", file = ".clinerules/brain.md", own = true},
	// kiro.dev/docs/steering: frontmatter inclusion, always by default
	{name = "kiro", file = ".kiro/steering/brain.md", own = true, head = "---\ninclusion: always\n---\n"},
}

// Agents whose docs name AGENTS.md as their project file: Codex
// (learn.chatgpt.com, agent configuration), OpenCode (opencode.ai/docs/rules),
// Jules (jules.google/docs), Junie (junie.jetbrains.com/docs, .junie/AGENTS.md
// and the root file), Zed (zed.dev/docs/ai/instructions) and Warp
// (docs.warp.dev, rules for agents).
AGENTS_MD_READERS :: [7]string{"codex", "opencode", "jules", "junie", "jetbrains", "zed", "warp"}

find_target :: proc(name: string) -> (Target, bool) {
	n := strings.to_lower(name)
	for r in AGENTS_MD_READERS {
		if r == n {
			n = "agents"
		}
	}
	for t in TARGETS {
		if t.name == n {
			return t, true
		}
	}
	return {}, false
}

target_names :: proc() -> string {
	names := make([dynamic]string)
	for t in TARGETS {
		append(&names, t.name)
	}
	readers := AGENTS_MD_READERS
	return strings.concatenate({strings.join(names[:], " "), " (", strings.join(readers[:], ", "), " read AGENTS.md)"})
}

cmd_export :: proc(cli: ^Cli, args: []string) -> int {
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	usage := strings.concatenate({"usage: brain export <agent>... | --all [--budget <tokens>]\n  agents: ", target_names()})
	budget := PACK_BUDGET * 4
	all := false
	names := make([dynamic]string)
	rest := args
	for len(rest) > 0 {
		arg := rest[0]
		rest = rest[1:]
		switch arg {
		case "--all":
			all = true
		case "--budget":
			n, ok := 0, false
			if len(rest) > 0 {
				n, ok = strconv.parse_int(rest[0])
				rest = rest[1:]
			}
			if !ok || n <= 0 {
				return fail(cli, usage)
			}
			budget = n * 4
		case:
			append(&names, arg)
		}
	}
	targets := make([dynamic]Target)
	if all {
		for t in TARGETS {
			append(&targets, t)
		}
	}
	for n in names {
		t, ok := find_target(n)
		if !ok {
			return fail(cli, strings.concatenate({"unknown agent: ", n, "\n", usage}))
		}
		append(&targets, t)
	}
	if len(targets) == 0 {
		return fail(cli, usage)
	}
	root, project := repo_here(cli)
	db, oerr := open_db(cli.db)
	if oerr != "" {
		return fail(cli, oerr)
	}
	defer sqlite3.close(&db)
	body := build_pack(db, project, strings.join(query_terms(project), "-"), budget)
	if body == "" {
		return fail(cli, strings.concatenate({"no bullets for: ", project}))
	}
	w := jw_make()
	if cli.json {
		jw_obj(&w)
		jw_field(&w, "project", project)
		jw_field(&w, "root", root)
		jw_key(&w, "files")
		jw_arr(&w)
	}
	for t in targets {
		file := path.join(root, t.file)
		status: string
		if t.own {
			status = write_own(cli, file, strings.concatenate({t.head, body}))
		} else {
			status = block_apply(cli, file, "memory", "<!--", "-->", strings.trim_right(body, "\n"), "brain export")
		}
		if cli.json {
			jw_obj(&w)
			jw_field(&w, "agent", t.name)
			jw_field(&w, "file", t.file)
			jw_field(&w, "status", status)
			jw_end_obj(&w)
		}
	}
	if cli.json {
		jw_end_arr(&w)
		jw_end_obj(&w)
		jw_flush(cli, &w)
	}
	return 0
}

// write_own writes a file that is brain's alone, and says nothing was done
// when it is already current.
write_own :: proc(cli: ^Cli, file, want: string) -> (status: string) {
	if cur, ok := read_text(file); ok && cur == want {
		say(cli, "%s: already current", file)
		return "current"
	}
	say(cli, "%s: written", file)
	if cli.dry {
		return "written"
	}
	path.mkdirs(path.dir(file))
	path.write(file, want)
	return "written"
}

package brain

import "core:strings"

import "jm:path"

// `brain import` reads what an agent remembered on its own and proposes it,
// one bullet per memory, into the inbox: nothing enters the vault until a
// person approves it. Claude Code keeps one file per memory under
// ~/.claude/projects/<slug>/memory/ with MEMORY.md as the index; any other
// markdown file is read as a list, one proposal per bullet line.

cmd_import :: proc(cli: ^Cli, args: []string) -> int {
	if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	if len(args) != 1 {
		return fail(cli, "usage: brain import claude | <file.md>")
	}
	lines: []string
	source: string
	switch args[0] {
	case "claude":
		root, _ := repo_here(cli)
		dir := path.join(cli.home, ".claude", "projects", claude_slug(root), "memory")
		lines = claude_bullets(dir)
		source = "claude memory"
		if len(lines) == 0 {
			return fail(cli, strings.concatenate({"no Claude Code memories under ", dir}))
		}
	case:
		text, ok := read_text(args[0])
		if !ok {
			return fail(cli, strings.concatenate({"cannot read ", args[0]}))
		}
		lines = list_bullets(text)
		source = strings.concatenate({"imported from ", path.base(args[0])})
		if len(lines) == 0 {
			return fail(cli, strings.concatenate({"no bullet lines in ", args[0]}))
		}
	}
	queued := 0
	for l in lines {
		if code := propose_line(cli, complete_bullet(l, source)); code == 0 {
			queued += 1
		}
	}
	outf(cli, "%d proposal(s) from %d memories; brain inbox lists them\n", queued, len(lines))
	return 0
}

// claude_slug is the directory name Claude Code gives a project: its path
// with every character that is not a letter or digit turned into a dash.
claude_slug :: proc(root: string) -> string {
	buf := make([]byte, len(root))
	for c, i in transmute([]byte)root {
		switch {
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'):
			buf[i] = c
		case:
			buf[i] = '-'
		}
	}
	return string(buf)
}

// claude_bullets turns a Claude Code memory directory into bullet lines.
// Each index line is `- [Title](file.md) — hook`; the file holds
// frontmatter (name, description, type) and a body, which becomes the fact,
// one line. A memory with no file keeps its hook.
claude_bullets :: proc(dir: string) -> []string {
	index, ok := read_text(path.join(dir, "MEMORY.md"))
	if !ok {
		return nil
	}
	out := make([dynamic]string)
	for l in strings.split_lines(index) {
		if !strings.has_prefix(l, "- [") {
			continue
		}
		title, found := between(l, "- [", "]")
		if !found || title == "" {
			continue
		}
		file, _ := between(l, "](", ")")
		fact := ""
		if i := strings.index(l, SEP); i >= 0 {
			fact = strings.trim_space(l[i + len(SEP):])
		}
		kind := ""
		if file != "" {
			if text, fok := read_text(path.join(dir, file)); fok {
				body, fm := split_frontmatter(text)
				if b := one_line(body); b != "" {
					fact = b
				}
				kind = fm["type"]
			}
		}
		if fact == "" {
			continue
		}
		who := kind != "" ? strings.concatenate({"claude memory (", kind, ")"}) : "claude memory"
		append(&out, strings.concatenate({"- **", title, "**", SEP, fact, SEP, who}))
	}
	return out[:]
}

// split_frontmatter separates a leading `---` block into its `key: value`
// lines and the body after it.
split_frontmatter :: proc(text: string) -> (body: string, fields: map[string]string) {
	fields = make(map[string]string)
	if !strings.has_prefix(text, "---\n") {
		return text, fields
	}
	rest := text[4:]
	end := strings.index(rest, "\n---")
	if end < 0 {
		return text, fields
	}
	for l in strings.split_lines(rest[:end]) {
		if i := strings.index(l, ":"); i > 0 {
			fields[strings.trim_space(l[:i])] = strings.trim_space(l[i + 1:])
		}
	}
	body = rest[end + len("\n---"):]
	return strings.trim_space(body), fields
}

// one_line joins a body's lines with spaces.
one_line :: proc(body: string) -> string {
	return strings.join(strings.fields(body), " ")
}

// list_bullets reads every `- ` or `* ` line of a markdown file as a fact,
// with its first words as the handle. A line that is a bullet in the
// vault's own shape is kept as it is.
list_bullets :: proc(text: string) -> []string {
	out := make([dynamic]string)
	for raw in strings.split_lines(text) {
		l := strings.trim_space(raw)
		if !strings.has_prefix(l, "- ") && !strings.has_prefix(l, "* ") {
			continue
		}
		if strings.has_prefix(l, "- **") {
			append(&out, l)
			continue
		}
		fact := strings.trim_space(l[2:])
		if fact == "" {
			continue
		}
		words := strings.fields(fact)
		n := min(len(words), 5)
		handle := strings.trim_right(strings.join(words[:n], " "), ".,;:")
		append(&out, strings.concatenate({"- **", handle, "**", SEP, fact}))
	}
	return out[:]
}

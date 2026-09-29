package brain

import "core:fmt"
import "core:strconv"
import "core:strings"

import "jm:path"

// An agent proposes a bullet; a person approves it. Proposals wait in
// AI/INBOX.md, which the index skips, so nothing an agent wrote answers a
// find until someone moved it into a core file. `brain inbox` lists the
// queue, `brain inbox approve <n> [--to LEARNINGS]` moves one, and
// `brain inbox drop <n>` discards one.

INBOX_FILE :: "AI/INBOX.md"
INBOX_HEAD :: "# Inbox\n\nBullets agents proposed, waiting for a person. `brain inbox` lists them,\n`brain inbox approve <n> [--to LEARNINGS]` moves one into memory, `brain inbox drop <n>`\ndiscards it.\n\n"

cmd_propose :: proc(cli: ^Cli, args: []string) -> int {
	if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	line := strings.trim_space(strings.join(args, " "))
	if line == "" {
		return fail(cli, "usage: brain propose '- **handle** (aliases: ...) — fact — source — YYYY-MM-DD'")
	}
	return propose_line(cli, complete_bullet(line, caller_id(cli)))
}

// propose_line queues one completed bullet line, or says why not.
propose_line :: proc(cli: ^Cli, line: string) -> int {
	b, ok := parse_bullet(line, "")
	if !ok {
		return fail(cli, strings.concatenate({"not a bullet: it needs `- **handle**`, a fact and a date; got: ", line}))
	}
	inbox := path.join(cli.vault, INBOX_FILE)
	text, exists := read_text(inbox)
	if !exists {
		text = INBOX_HEAD
	}
	n := 0
	for l in strings.split_lines(text) {
		q, qok := parse_bullet(l, "")
		if !qok {
			continue
		}
		n += 1
		if q.handle == b.handle {
			outf(cli, "already proposed as #%d: **%s**\n", n, b.handle)
			return 0
		}
	}
	if !strings.has_suffix(text, "\n") {
		text = strings.concatenate({text, "\n"})
	}
	if werr := path.write(inbox, strings.concatenate({text, line, "\n"})); werr != nil {
		return fail(cli, fmt.aprintf("cannot write %s: %v", inbox, werr))
	}
	n += 1
	outf(cli, "proposed #%d **%s**; a person approves it with: brain inbox approve %d\n", n, b.handle, n)
	return 0
}

// complete_bullet fills what an agent may leave off: a source, which
// becomes the caller, and today's date. A line that already ends in a date
// is taken as written.
complete_bullet :: proc(line, caller: string) -> string {
	f := strings.split(line, SEP)
	n := len(f)
	if n >= 2 && is_iso_date(f[n - 1]) {
		return line
	}
	if n == 2 {
		who := caller != "" ? caller : "agent"
		return strings.concatenate({line, SEP, who, SEP, today_iso()})
	}
	return strings.concatenate({line, SEP, today_iso()})
}

// Inbox_Line is one line of the inbox file, and whether it is a proposal.
Inbox_Line :: struct {
	text:   string,
	bullet: Bullet,
	is:     bool,
}

read_inbox :: proc(cli: ^Cli) -> (lines: []Inbox_Line, exists: bool) {
	text, ok := read_text(path.join(cli.vault, INBOX_FILE))
	if !ok {
		return nil, false
	}
	all := make([dynamic]Inbox_Line)
	for l in strings.split_lines(text) {
		b, is := parse_bullet(l, "")
		append(&all, Inbox_Line{text = l, bullet = b, is = is})
	}
	// split_lines leaves an empty last element after the final newline.
	if len(all) > 0 && all[len(all) - 1].text == "" {
		pop(&all)
	}
	return all[:], true
}

write_inbox :: proc(cli: ^Cli, lines: []Inbox_Line) -> string {
	b := strings.builder_make()
	for l in lines {
		strings.write_string(&b, l.text)
		strings.write_string(&b, "\n")
	}
	inbox := path.join(cli.vault, INBOX_FILE)
	if werr := path.write(inbox, strings.to_string(b)); werr != nil {
		return fmt.aprintf("cannot write %s: %v", inbox, werr)
	}
	return ""
}

cmd_inbox :: proc(cli: ^Cli, args: []string) -> int {
	if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	lines, exists := read_inbox(cli)
	if len(args) == 0 {
		n := 0
		for l in lines {
			if l.is {
				n += 1
				outf(cli, "#%d %s\n", n, l.text)
			}
		}
		if n == 0 {
			out(cli, "inbox empty\n")
		}
		return 0
	}
	if !exists {
		return fail(cli, "inbox empty")
	}
	usage := "usage: brain inbox [approve <n> [--to MEMORY|LEARNINGS|TUNINGS] | drop <n>]"
	if len(args) < 2 {
		return fail(cli, usage)
	}
	want, ok := strconv.parse_int(args[1])
	if !ok || want < 1 {
		return fail(cli, usage)
	}
	at := -1
	n := 0
	for l, i in lines {
		if l.is {
			n += 1
			if n == want {
				at = i
				break
			}
		}
	}
	if at < 0 {
		return fail(cli, fmt.aprintf("no proposal #%d; brain inbox lists them", want))
	}
	chosen := lines[at]
	switch args[0] {
	case "approve":
		to := "MEMORY"
		if len(args) >= 4 && args[2] == "--to" {
			to = strings.to_upper(args[3])
		} else if len(args) != 2 {
			return fail(cli, usage)
		}
		if to != "MEMORY" && to != "LEARNINGS" && to != "TUNINGS" {
			return fail(cli, usage)
		}
		rel := strings.concatenate({"AI/", to, ".md"})
		target := path.join(cli.vault, rel)
		text, _ := read_text(target)
		if text != "" && !strings.has_suffix(text, "\n") {
			text = strings.concatenate({text, "\n"})
		}
		if werr := path.write(target, strings.concatenate({text, chosen.text, "\n"})); werr != nil {
			return fail(cli, fmt.aprintf("cannot write %s: %v", target, werr))
		}
		if err := write_inbox(cli, drop_at(lines, at)); err != "" {
			return fail(cli, err)
		}
		if err := sync(cli, quiet = true); err != "" {
			return fail(cli, err)
		}
		outf(cli, "approved #%d **%s** -> %s\n", want, chosen.bullet.handle, rel)
	case "drop":
		if len(args) != 2 {
			return fail(cli, usage)
		}
		if err := write_inbox(cli, drop_at(lines, at)); err != "" {
			return fail(cli, err)
		}
		outf(cli, "dropped #%d **%s**\n", want, chosen.bullet.handle)
	case:
		return fail(cli, usage)
	}
	return 0
}

// drop_at is lines without the one at index at.
drop_at :: proc(lines: []Inbox_Line, at: int) -> []Inbox_Line {
	kept := make([dynamic]Inbox_Line)
	for l, i in lines {
		if i != at {
			append(&kept, l)
		}
	}
	return kept[:]
}

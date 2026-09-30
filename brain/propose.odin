package brain

import "core:fmt"
import "core:strconv"
import "core:strings"

import "jm:path"

// An agent proposes a bullet and a person reviews it. Proposals land in
// AI/INBOX.md. When review comes after, the default, the index reads the
// inbox too, so a proposal answers a find at once, marked unreviewed; when
// it comes before, the index skips the inbox and nothing an agent wrote
// answers a find until a person moved it into a core file. `brain inbox`
// lists the proposals, `brain inbox approve <n> [--to LEARNINGS]` moves one
// into a core file, and `brain inbox drop <n>` moves one to AI/DROPPED.md,
// which the index never reads and propose checks, so the same fact is not
// proposed again.

INBOX_FILE   :: "AI/INBOX.md"
DROPPED_FILE :: "AI/DROPPED.md"
INBOX_HEAD   :: "# Inbox\n\nBullets agents proposed that no person has reviewed yet. `brain inbox` lists them,\n`brain inbox approve <n> [--to LEARNINGS]` moves one into memory, `brain inbox drop <n>`\nrejects it.\n\n"
DROPPED_HEAD :: "# Dropped\n\nProposals a person rejected. `brain propose` refuses the same fact again.\n\n"

// UNREVIEWED follows the locator of a hit still in the inbox.
UNREVIEWED :: "(unreviewed)"

// Review is when a person reviews what agents propose: After lets a
// proposal answer finds until it is dropped, Before holds it back until it
// is approved.
Review :: enum {
	After,
	Before,
}

// review_mode reads BRAIN_REVIEW, then the setting `brain review` wrote,
// and defaults to After.
review_mode :: proc(cli: ^Cli) -> Review {
	v := getenv(cli, "BRAIN_REVIEW")
	if v == "" {
		v = strings.trim_space(first_line(path.join(cli.conf_dir, "review")))
	}
	return v == "before" ? .Before : .After
}

review_name :: proc(r: Review) -> string {
	return r == .Before ? "before" : "after"
}

// cmd_review shows or sets when proposals are reviewed, and reindexes so
// the setting takes effect on the next find.
cmd_review :: proc(cli: ^Cli, args: []string) -> int {
	usage := "usage: brain review [after|before]"
	if len(args) > 1 {
		return fail(cli, usage)
	}
	if len(args) == 1 {
		if args[0] != "after" && args[0] != "before" {
			return fail(cli, usage)
		}
		if err := path.mkdirs(cli.conf_dir); err != nil {
			return fail(cli, fmt.aprintf("cannot create %s: %v", cli.conf_dir, err))
		}
		conf := path.join(cli.conf_dir, "review")
		if err := path.write(conf, strings.concatenate({args[0], "\n"})); err != nil {
			return fail(cli, fmt.aprintf("cannot write %s: %v", conf, err))
		}
		if cli.vault != "" {
			if err := sync(cli, quiet = true); err != "" {
				return fail(cli, err)
			}
		}
	}
	mode := review_mode(cli)
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "review", review_name(mode))
		jw_end_obj(&w)
		jw_flush(cli, &w)
	} else if mode == .After {
		out(cli, "review after: proposals answer finds at once, marked unreviewed, until dropped\n")
	} else {
		out(cli, "review before: proposals wait in the inbox until approved\n")
	}
	return 0
}

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
	dropped, _ := read_text(path.join(cli.vault, DROPPED_FILE))
	for l in strings.split_lines(dropped) {
		d, dok := parse_bullet(l, "")
		if dok && d.handle == b.handle && d.fact == b.fact {
			if cli.json {
				propose_json(cli, "dropped", 0, b.handle)
			} else {
				outf(cli, "a person dropped this fact before; not proposed: %s\n", l)
			}
			return 0
		}
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
			if cli.json {
				propose_json(cli, "already", n, b.handle)
			} else {
				outf(cli, "already proposed as #%d: **%s**\n", n, b.handle)
			}
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
	if cli.json {
		propose_json(cli, "proposed", n, b.handle)
	} else if review_mode(cli) == .After {
		outf(cli, "proposed #%d **%s**; it answers finds now, marked unreviewed, until a person drops it\n", n, b.handle)
	} else {
		outf(cli, "proposed #%d **%s**; a person approves it with: brain inbox approve %d\n", n, b.handle, n)
	}
	return 0
}

propose_json :: proc(cli: ^Cli, status: string, n: int, handle: string) {
	w := jw_make()
	jw_obj(&w)
	jw_field(&w, "status", status)
	jw_field_int(&w, "n", i64(n))
	jw_field(&w, "handle", handle)
	jw_end_obj(&w)
	jw_flush(cli, &w)
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
		w := jw_make()
		if cli.json {
			jw_obj(&w)
			jw_key(&w, "proposals")
			jw_arr(&w)
		}
		for l in lines {
			if !l.is {
				continue
			}
			n += 1
			if cli.json {
				jw_obj(&w)
				jw_field_int(&w, "n", i64(n))
				jw_field(&w, "handle", l.bullet.handle)
				jw_field(&w, "aliases", l.bullet.aliases)
				jw_field(&w, "fact", l.bullet.fact)
				jw_field(&w, "source", l.bullet.source)
				jw_field(&w, "date", l.bullet.date)
				jw_field(&w, "line", l.text)
				jw_end_obj(&w)
			} else {
				outf(cli, "#%d %s\n", n, l.text)
			}
		}
		if cli.json {
			jw_end_arr(&w)
			jw_end_obj(&w)
			jw_flush(cli, &w)
		} else if n == 0 {
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
		if cli.json {
			inbox_json(cli, "approved", want, chosen.bullet.handle, rel)
		} else {
			outf(cli, "approved #%d **%s** -> %s\n", want, chosen.bullet.handle, rel)
		}
	case "drop":
		if len(args) != 2 {
			return fail(cli, usage)
		}
		dropped := path.join(cli.vault, DROPPED_FILE)
		text, dexists := read_text(dropped)
		if !dexists {
			text = DROPPED_HEAD
		}
		if !strings.has_suffix(text, "\n") {
			text = strings.concatenate({text, "\n"})
		}
		if werr := path.write(dropped, strings.concatenate({text, chosen.text, "\n"})); werr != nil {
			return fail(cli, fmt.aprintf("cannot write %s: %v", dropped, werr))
		}
		if err := write_inbox(cli, drop_at(lines, at)); err != "" {
			return fail(cli, err)
		}
		if cli.json {
			inbox_json(cli, "dropped", want, chosen.bullet.handle, "")
		} else {
			outf(cli, "dropped #%d **%s**\n", want, chosen.bullet.handle)
		}
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

inbox_json :: proc(cli: ^Cli, action: string, n: int, handle, to: string) {
	w := jw_make()
	jw_obj(&w)
	jw_field(&w, "action", action)
	jw_field_int(&w, "n", i64(n))
	jw_field(&w, "handle", handle)
	if to != "" {
		jw_field(&w, "to", to)
	}
	jw_end_obj(&w)
	jw_flush(cli, &w)
}

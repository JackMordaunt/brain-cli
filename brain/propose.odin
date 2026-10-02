package brain

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

import "jm:path"
import "jm:sqlite3"

// An agent proposes a bullet and a person reviews it. Proposals land in
// AI/INBOX.md. When review comes after, the default, the index reads the
// inbox too, so a proposal answers a find at once, marked unreviewed; when
// it comes before, the index skips the inbox and nothing an agent wrote
// answers a find until a person moved it into a core file. `brain inbox`
// lists the proposals, `brain inbox approve <n>|all [--to LEARNINGS]` moves one or all
// into a core file, and `brain inbox drop <n>` moves one to AI/DROPPED.md,
// which the index never reads and propose checks, so the same fact is not
// proposed again.

INBOX_FILE   :: "AI/INBOX.md"
DROPPED_FILE :: "AI/DROPPED.md"
INBOX_HEAD   :: "# Inbox\n\nBullets agents proposed that no person has reviewed yet. `brain inbox` lists them,\n`brain inbox approve <n> [--to LEARNINGS]` moves one into memory, `approve all` every one,\n`brain inbox drop <n>` rejects it.\n\n"
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

// scratch_path says why a bullet is tied to where it was written: it names
// the working directory by its absolute path, or a path under the system's
// temporary directory. A durable fact survives the directory it was found
// in; the proof's task sessions (2026-10-02) proposed bullets about the
// script they had just written, located by such paths.
scratch_path :: proc(line: string) -> string {
	if cwd, err := os.get_working_directory(context.allocator); err == nil && cwd != "" && cwd != "/" && strings.contains(line, cwd) {
		return strings.concatenate({"names this working directory (", cwd, "); a durable fact does not depend on where it was found"})
	}
	for tmp in ([?]string{"/tmp/", "/var/tmp/", "/private/tmp/"}) {
		if strings.contains(line, tmp) {
			return strings.concatenate({"names a path under ", tmp, "; nothing durable lives there"})
		}
	}
	return ""
}

cmd_propose :: proc(cli: ^Cli, args: []string) -> int {
	if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	force := false
	rest := make([dynamic]string)
	for a in args {
		if a == "--force" {
			force = true
		} else {
			append(&rest, a)
		}
	}
	line := strings.trim_space(strings.join(rest[:], " "))
	if line == "" {
		return fail(cli, "usage: brain propose [--force] '- **handle** (aliases: ...) — fact — source — YYYY-MM-DD'")
	}
	// settle says "reply none"; agents run it as a command. Nothing to record.
	if strings.to_lower(strings.trim(line, "'\"")) == "none" {
		out(cli, "nothing proposed\n")
		return 0
	}
	return propose_line(cli, complete_bullet(line, caller_id(cli)), force)
}

// propose_line queues one completed bullet line, or says why not.
// RESTATE_SHARE is the share of a proposed fact's distinctive words a current
// bullet must hold to count as already saying it.
RESTATE_SHARE :: 0.6

// restating_bullet finds a current bullet, in a core file, that already says what a
// proposed bullet says: it holds RESTATE_SHARE of the fact's distinctive
// words (four letters or more, not query noise), words meeting as the
// stemmed index meets them. Settle drew proposals out of the proof's task
// sessions (2026-10-02) that restated bullets the vault held; a proposal
// is checked against the index before the inbox is written.
restating_bullet :: proc(cli: ^Cli, b: Bullet) -> Hit {
	if ensure_db(cli) != "" {
		return {}
	}
	db, oerr := open_db(cli.db)
	if oerr != "" {
		return {}
	}
	defer sqlite3.close(&db)
	words := make([dynamic]string)
	stop := PRIME_STOP
	for t in query_terms(b.fact) {
		if utf8.rune_count_in_string(t) >= 4 && !slice.contains(stop[:], t) && !slice.contains(words[:], t) {
			append(&words, t)
		}
	}
	if len(words) < 4 {
		return {}
	}
	m, ok := build_match(db, strings.join(words[:], " "))
	if !ok {
		return {}
	}
	need := int(f64(len(words)) * RESTATE_SHARE + 0.5)
	for h in query_fts(db, m.or, FIND_LIMIT * 2) {
		if h.file == INBOX_FILE || h.handle == "" {
			continue
		}
		if count_met_terms(strings.concatenate({h.handle, " ", h.aliases, " ", h.fact}), words[:]) >= need {
			return h
		}
	}
	return {}
}

propose_line :: proc(cli: ^Cli, line: string, force := false) -> int {
	b, ok := parse_bullet(line, "")
	if !ok {
		return fail(cli, strings.concatenate({"not a bullet: it needs `- **handle**`, a fact and a date; got: ", line}))
	}
	guard: Guard
	guard_init(&guard, worktree_strict(cli.vault))
	defer guard_destroy(&guard)
	if why := guard_line(&guard, line); why != "" {
		return fail(cli, strings.concatenate({"not proposed: the bullet ", why}))
	}
	if why := scratch_path(line); why != "" {
		return fail(cli, strings.concatenate({"not proposed: the bullet ", why}))
	}
	if !force {
		if dup := restating_bullet(cli, b); dup.handle != "" {
			return fail(
				cli,
				strings.concatenate(
					{
						"not proposed: the bullet restates **",
						dup.handle,
						"** (",
						dup.file,
						":",
						int_str(dup.line),
						"); if it corrects that bullet, propose again with --force and say what changed",
					},
				),
			)
		}
	}
	return inbox_write(cli, line, b)
}

// inbox_write appends a parsed bullet to the inbox unless a person dropped
// the same fact before or the same handle is already waiting; tend's
// hygiene items take this path too, past the checks a fact gets.
inbox_write :: proc(cli: ^Cli, line: string, b: Bullet) -> int {
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
	} else if is_tend(b) {
		outf(cli, "proposed #%d **%s**; brain inbox approve %d applies it\n", n, b.handle, n)
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
	usage := "usage: brain inbox [approve <n>|all [--to MEMORY|LEARNINGS|TUNINGS] | drop <n>]"
	if len(args) < 2 {
		return fail(cli, usage)
	}
	if args[1] == "all" {
		if args[0] != "approve" {
			return fail(cli, usage)
		}
		return inbox_approve_all(cli, lines, args[2:], usage)
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
		// A hygiene item from tend is an action, not a fact: approving it
		// applies the action and logs it, and nothing moves into a core file.
		if is_tend(chosen.bullet) {
			if err := tend_apply(cli, chosen.bullet); err != "" {
				return fail(cli, err)
			}
			if err := write_inbox(cli, drop_at(lines, at)); err != "" {
				return fail(cli, err)
			}
			tend_log(cli, chosen.text)
			if err := sync(cli, quiet = true); err != "" {
				return fail(cli, err)
			}
			if cli.json {
				inbox_json(cli, "applied", want, chosen.bullet.handle, "")
			} else {
				outf(cli, "applied #%d **%s**\n", want, chosen.bullet.handle)
			}
			return 0
		}
		rel, valid := approve_target(args[2:])
		if !valid {
			return fail(cli, usage)
		}
		if err := append_bullets(cli, rel, {chosen}); err != "" {
			return fail(cli, err)
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

// approve_target reads the optional `--to MEMORY|LEARNINGS|TUNINGS` that
// follows an approve and names the core file, relative to the vault.
approve_target :: proc(args: []string) -> (rel: string, ok: bool) {
	to := "MEMORY"
	if len(args) == 2 && args[0] == "--to" {
		to = strings.to_upper(args[1])
	} else if len(args) != 0 {
		return "", false
	}
	if to != "MEMORY" && to != "LEARNINGS" && to != "TUNINGS" {
		return "", false
	}
	return strings.concatenate({"AI/", to, ".md"}), true
}

// append_bullets adds the inbox lines to the end of the core file rel,
// in order, and says what went wrong.
append_bullets :: proc(cli: ^Cli, rel: string, chosen: []Inbox_Line) -> string {
	target := path.join(cli.vault, rel)
	text, _ := read_text(target)
	b := strings.builder_make()
	strings.write_string(&b, text)
	if text != "" && !strings.has_suffix(text, "\n") {
		strings.write_string(&b, "\n")
	}
	for l in chosen {
		strings.write_string(&b, l.text)
		strings.write_string(&b, "\n")
	}
	if werr := path.write(target, strings.to_string(b)); werr != nil {
		return fmt.aprintf("cannot write %s: %v", target, werr)
	}
	return ""
}

// inbox_approve_all moves every proposal into one core file with a single
// write and a single sync, leaving the inbox with only its header.
inbox_approve_all :: proc(cli: ^Cli, lines: []Inbox_Line, args: []string, usage: string) -> int {
	rel, ok := approve_target(args)
	if !ok {
		return fail(cli, usage)
	}
	chosen := make([dynamic]Inbox_Line)
	kept := make([dynamic]Inbox_Line)
	for l in lines {
		// Hygiene items change the vault; each is approved on its own.
		if l.is && !is_tend(l.bullet) {
			append(&chosen, l)
		} else {
			append(&kept, l)
		}
	}
	if len(chosen) == 0 {
		return fail(cli, "inbox empty")
	}
	if err := append_bullets(cli, rel, chosen[:]); err != "" {
		return fail(cli, err)
	}
	if err := write_inbox(cli, kept[:]); err != "" {
		return fail(cli, err)
	}
	if err := sync(cli, quiet = true); err != "" {
		return fail(cli, err)
	}
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "action", "approved")
		jw_field_int(&w, "count", i64(len(chosen)))
		jw_field(&w, "to", rel)
		jw_key(&w, "handles")
		jw_arr(&w)
		for l in chosen {
			jw_str(&w, l.bullet.handle)
		}
		jw_end_arr(&w)
		jw_end_obj(&w)
		jw_flush(cli, &w)
	} else {
		for l, i in chosen {
			outf(cli, "approved #%d **%s** -> %s\n", i + 1, l.bullet.handle, rel)
		}
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

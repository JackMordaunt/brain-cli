package brain

import "core:strconv"
import "core:strings"

import "jm:path"
import "jm:sqlite3"

// A session re-derives how to release, deploy or run the tests, one
// command at a time, and the sequence that worked is already in the
// transcript as tool calls. `brain howto <terms>` finds the session whose
// shell commands or title match best and replays the chain around the
// best match: the shell commands between the prompt that asked and the
// next prompt, failures dropped, repeats collapsed. --propose writes the
// chain into the repository's state folder in the vault with a bullet
// pointing at it, so the next session finds it by handle and a person
// can edit it.

HOWTO_LIMIT :: 8 // sessions listed by --all
HOWTO_SHELL :: "Bash" // the tool whose calls form a chain

Howto :: struct {
	session, title, date, cwd: string,
	commands:                  []string,
}

cmd_howto :: proc(cli: ^Cli, args: []string) -> int {
	all, propose := false, false
	limit := HOWTO_LIMIT
	terms := make([dynamic]string)
	exclude := getenv(cli, "CLAUDE_CODE_SESSION_ID", getenv(cli, "CLAUDE_SESSION_ID"))
	rest := args
	for len(rest) > 0 {
		arg := rest[0]
		rest = rest[1:]
		switch arg {
		case "--all":
			all = true
		case "--propose":
			propose = true
		case "--limit":
			if len(rest) > 0 {
				limit, _ = strconv.parse_int(rest[0])
				rest = rest[1:]
			}
			if limit <= 0 {
				limit = HOWTO_LIMIT
			}
		case:
			if strings.has_prefix(arg, "-") {
				return fail(cli, strings.concatenate({"howto: unknown flag ", arg}))
			}
			append(&terms, arg)
		}
	}
	if len(terms) == 0 {
		return fail(cli, "usage: brain howto <terms...> [--all] [--propose]")
	}
	if !recall_enabled(cli) {
		return 1
	}
	db, err := open_recall_db(cli)
	if err != "" {
		return fail(cli, err)
	}
	defer sqlite3.close(&db)
	recall_sync(cli, db, full = false)

	match := fts_and(terms[:])
	if all {
		list := howto_sessions(db, match, exclude, limit)
		if cli.json {
			w := jw_make()
			jw_arr(&w)
			for h in list {
				jw_howto(&w, h, with_commands = false)
			}
			jw_end_arr(&w)
			jw_flush(cli, &w)
		} else {
			for h in list {
				outf(cli, "%s  %s  %d commands  %s\n", h.date, h.title, len(h.commands), h.session)
			}
		}
		return len(list) > 0 ? 0 : howto_report_miss(cli, terms[:])
	}
	h, found := howto_best(db, match, exclude)
	if !found {
		return howto_report_miss(cli, terms[:])
	}
	if propose {
		return howto_propose(cli, terms[:], h)
	}
	if cli.json {
		w := jw_make()
		jw_howto(&w, h, with_commands = true)
		jw_flush(cli, &w)
		return 0
	}
	outf(cli, "%s  %s  %s\n", h.date, h.title, h.cwd)
	for c in h.commands {
		outf(cli, "  %s\n", c)
	}
	return 0
}

howto_report_miss :: proc(cli: ^Cli, terms: []string) -> int {
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "error", strings.concatenate({"no session ran commands about: ", strings.join(terms, " ")}))
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 1
	}
	outf(cli, "no session ran commands about: %s\n", strings.join(terms, " "))
	return 1
}

// fts_and is every term required, as an FTS5 match string.
fts_and :: proc(terms: []string) -> string {
	q := make([dynamic]string)
	for t in terms {
		append(&q, quoted(t))
	}
	return strings.join(q[:], " AND ")
}

// howto_best is the chain around the best-scoring successful shell call.
// A command that names the terms outranks a title that does.
howto_best :: proc(db: sqlite3.Db, match, exclude: string) -> (h: Howto, found: bool) {
	stmt, err := sqlite3.query(
		db,
		`with hit(rid, s) as (
		   select rowid, bm25(tool_fts, 2.0, 1.0) from tool_fts
		   where tool_fts match ? order by rank limit 200
		 )
		 select t.session, t.title, substr(t.ts,1,10), t.cwd, t.ts
		 from hit h join tool t on t.rowid = h.rid
		 where t.name = ? and t.ok = 1 and t.session <> ?
		 order by h.s limit 1`,
		match,
		HOWTO_SHELL,
		exclude,
	)
	if err != nil || !sqlite3.next(&stmt) {
		if err == nil {
			sqlite3.finish(&stmt)
		}
		return
	}
	h = Howto {
		session = strings.clone(sqlite3.text(stmt, 0)),
		title   = strings.clone(sqlite3.text(stmt, 1)),
		date    = strings.clone(sqlite3.text(stmt, 2)),
		cwd     = strings.clone(sqlite3.text(stmt, 3)),
	}
	anchor := strings.clone(sqlite3.text(stmt, 4))
	sqlite3.finish(&stmt)
	h.commands = howto_chain(db, h.session, anchor)
	return h, true
}

// howto_chain is the successful shell commands of one task: those between
// the prompt before the anchor call and the prompt after it, in order,
// with a command repeated back to back kept once.
howto_chain :: proc(db: sqlite3.Db, session, anchor: string) -> []string {
	lo := scalar_text(db, "select coalesce(max(ts),'') from turn where session=? and role='user' and ts < ?", session, anchor)
	hi := scalar_text(db, "select coalesce(min(ts),'~') from turn where session=? and role='user' and ts > ?", session, anchor)
	cmds := make([dynamic]string)
	for c in column_texts(
		db,
		"select input from tool where session=? and name=? and ok=1 and ts > ? and ts < ? order by ts",
		session,
		HOWTO_SHELL,
		lo,
		hi,
	) {
		if c == "" || (len(cmds) > 0 && cmds[len(cmds) - 1] == c) {
			continue
		}
		append(&cmds, strings.clone(c))
	}
	return cmds[:]
}

// howto_sessions lists the sessions that match, best first, each with its
// chain around its own best call.
howto_sessions :: proc(db: sqlite3.Db, match, exclude: string, limit: int) -> []Howto {
	list := make([dynamic]Howto)
	stmt, err := sqlite3.query(
		db,
		`with hit(rid, s) as (
		   select rowid, bm25(tool_fts, 2.0, 1.0) from tool_fts
		   where tool_fts match ? order by rank limit 400
		 ),
		 best as (
		   select t.session, min(h.s) as s
		   from hit h join tool t on t.rowid = h.rid
		   where t.name = ? and t.ok = 1 and t.session <> ?
		   group by t.session
		 )
		 select b.session, t.title, substr(t.ts,1,10), t.cwd, t.ts
		 from best b join hit h on h.s = b.s join tool t on t.rowid = h.rid and t.session = b.session
		 group by b.session order by b.s limit ?`,
		match,
		HOWTO_SHELL,
		exclude,
		i64(limit),
	)
	if err != nil {
		return nil
	}
	defer sqlite3.finish(&stmt)
	anchors := make([dynamic]string)
	for sqlite3.next(&stmt) {
		append(
			&list,
			Howto {
				session = strings.clone(sqlite3.text(stmt, 0)),
				title = strings.clone(sqlite3.text(stmt, 1)),
				date = strings.clone(sqlite3.text(stmt, 2)),
				cwd = strings.clone(sqlite3.text(stmt, 3)),
			},
		)
		append(&anchors, strings.clone(sqlite3.text(stmt, 4)))
	}
	for &h, i in list {
		h.commands = howto_chain(db, h.session, anchors[i])
	}
	return list[:]
}

// howto_propose writes the chain into the vault, under the repository's
// state folder, and proposes a bullet that names it. The file is the
// person's to edit; the bullet is what the next session finds.
howto_propose :: proc(cli: ^Cli, terms: []string, h: Howto) -> int {
	if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	if len(h.commands) == 0 {
		return fail(cli, "the matching session ran no successful command to keep")
	}
	repo := path.base(h.cwd)
	if repo == "" || repo == "/" || repo == "." {
		repo = "howto"
	}
	slug := strings.join(query_terms(strings.join(terms, " ")), "-")
	rel := strings.concatenate({repo, "/howto-", slug, ".md"})
	file := path.join(cli.vault, rel)
	b := strings.builder_make()
	strings.write_string(&b, strings.concatenate({"# howto ", strings.join(terms, " "), "\n\n"}))
	strings.write_string(&b, strings.concatenate({"From \"", h.title, "\", ", h.date, ", in ", h.cwd, ". The shell commands that ran without error, in order; `brain howto ", strings.join(terms, " "), "` replays it from the transcript.\n\n```sh\n"}))
	for c in h.commands {
		strings.write_string(&b, c)
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, "```\n")
	path.mkdirs(path.dir(file))
	if werr := path.write(file, strings.to_string(b)); werr != nil {
		return fail(cli, strings.concatenate({"cannot write ", file}))
	}
	line := strings.concatenate(
		{
			"- **howto ", strings.join(terms, " "), "** (aliases: ", strings.join(terms, " "), " chain, how to ", strings.join(terms, " "), ")",
			SEP, "the ", strings.join(terms, " "), " commands that worked on ", h.date, " in ", repo, ": ", int_str(i64(len(h.commands))), " steps, in ", rel,
			SEP, "recall:", h.session,
			SEP, today_iso(),
		},
	)
	if !cli.json {
		outf(cli, "wrote %s\n", rel)
	}
	return propose_line(cli, line)
}

jw_howto :: proc(w: ^Jw, h: Howto, with_commands: bool) {
	jw_obj(w)
	jw_field(w, "session", h.session)
	jw_field(w, "title", h.title)
	jw_field(w, "date", h.date)
	jw_field(w, "cwd", h.cwd)
	jw_field_int(w, "commands", i64(len(h.commands)))
	if with_commands {
		jw_key(w, "chain")
		jw_arr(w)
		for c in h.commands {
			jw_str(w, c)
		}
		jw_end_arr(w)
	}
	jw_end_obj(w)
}

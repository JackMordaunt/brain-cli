package brain

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "jm:path"
import "jm:sqlite3"

// What `brain find` answers is what was concluded and is still true. What
// `brain recall` answers is what was actually said, which is not the same
// thing and is not always right: a retracted claim reads exactly like a sound
// one. So transcripts live in their own database, behind their own command.

RECALL_SCHEMA :: `
create table if not exists source(path text primary key, adapter text);
create table if not exists turn(
  id text primary key, adapter text, session text, path text,
  ts text, role text, title text, cwd text, body text);
create virtual table if not exists turn_fts
  using fts5(body, title, content='turn', content_rowid='rowid');
create trigger if not exists turn_ai after insert on turn begin
  insert into turn_fts(rowid, body, title) values (new.rowid, new.body, new.title);
end;
create trigger if not exists turn_ad after delete on turn begin
  insert into turn_fts(turn_fts, rowid, body, title)
    values ('delete', old.rowid, old.body, old.title);
end;
create table if not exists tool(
  id text primary key, turn_id text, session text, path text,
  ts text, cwd text, title text, name text, input text, ok integer);
create virtual table if not exists tool_fts
  using fts5(input, title, content='tool', content_rowid='rowid');
create trigger if not exists tool_ai after insert on tool begin
  insert into tool_fts(rowid, input, title) values (new.rowid, new.input, new.title);
end;
create trigger if not exists tool_ad after delete on tool begin
  insert into tool_fts(tool_fts, rowid, input, title)
    values ('delete', old.rowid, old.input, old.title);
end;
`

// adapters_on names the sources this machine has enabled.
adapters_on :: proc(cli: ^Cli) -> []string {
	on := make([dynamic]string)
	lines, err := path.read_lines(cli.conf_sources)
	if err != nil {
		return nil
	}
	for l in lines {
		a := strings.trim_space(l)
		if a == "" || strings.has_prefix(a, "#") {
			continue
		}
		if _, ok := find_adapter(cli, a); ok {
			append(&on, a)
		}
	}
	return on[:]
}

open_recall_db :: proc(cli: ^Cli) -> (sqlite3.Db, string) {
	if err := path.mkdirs(cli.state); err != nil {
		return {}, fmt.aprintf("cannot create %s: %v", cli.state, err)
	}
	db, err := open_db(cli.recall_db)
	if err != "" {
		return {}, err
	}
	if e := sqlite3.exec(db, RECALL_SCHEMA); e != nil {
		sqlite3.close(&db)
		return {}, sql_err(e)
	}
	return db, ""
}

// recall_sync ingests everything an adapter can see, or only what moved
// since the last pass, and returns how many transcripts were read.
// Re-reading a whole transcript is cheap enough that there is no byte offset
// to keep: turns are keyed by the agent's own id, so a session resumed into a
// new file re-inserts nothing, and the overlap costs nothing.
recall_sync :: proc(cli: ^Cli, db: sqlite3.Db, full: bool) -> int {
	total := 0
	full := full
	// A database written before tool calls were read fills its tool table
	// with one full pass.
	if !full && scalar_int(db, "select count(*) from tool") == 0 && scalar_int(db, "select count(*) from turn") > 0 {
		full = true
	}
	for name in adapters_on(cli) {
		a, _ := find_adapter(cli, name)
		stamp := path.join(cli.state, strings.concatenate({"recall-", name, ".stamp"}))
		stamp_time, serr := os.modification_time_by_path(stamp)
		all := a.list(cli)
		changed := make([dynamic]string)
		for f in all {
			if full || serr != nil {
				append(&changed, f)
				continue
			}
			if t, terr := os.modification_time_by_path(f); terr == nil && time.diff(stamp_time, t) > 0 {
				append(&changed, f)
			}
		}
		total += len(changed)
		if len(changed) > 0 {
			sqlite3.exec(db, "pragma journal_mode=wal; begin")
			ins, _ := sqlite3.prepare(
				db,
				"insert or ignore into turn(id,adapter,session,path,ts,role,title,cwd,body) values(?,?,?,?,?,?,?,?,?)",
			)
			src, _ := sqlite3.prepare(db, "insert or replace into source(path,adapter) values(?,?)")
			tool, _ := sqlite3.prepare(
				db,
				"insert or ignore into tool(id,turn_id,session,path,ts,cwd,title,name,input,ok) values(?,?,?,?,?,?,?,?,?,?)",
			)
			for f in changed {
				ingest_file(cli, a, f, &ins, &src, &tool)
			}
			sqlite3.finish(&ins)
			sqlite3.finish(&src)
			sqlite3.finish(&tool)
			sqlite3.exec(db, "commit")
		}
		// A transcript that disappeared takes its turns with it.
		if full {
			now := make(map[string]bool)
			for f in all {
				now[f] = true
			}
			for was in column_texts(db, "select path from source where adapter=?", name) {
				if !now[was] {
					sqlite3.exec_args(db, "delete from turn where path=?", was)
					sqlite3.exec_args(db, "delete from tool where path=?", was)
					sqlite3.exec_args(db, "delete from source where path=?", was)
				}
			}
		}
		path.write(stamp, "")
	}
	return total
}

// ingest_file parses one transcript in its own arena, so a batch of large
// files does not hold every parsed record until the process exits.
ingest_file :: proc(cli: ^Cli, a: Adapter, file: string, ins, src, tool: ^sqlite3.Stmt) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	tr := a.emit(cli, file)
	for t in tr.turns {
		step(ins, t.id, a.name, t.session, file, t.ts, t.role, t.title, t.cwd, t.body)
	}
	for c in tr.tools {
		step(tool, c.id, c.turn_id, c.session, file, c.ts, c.cwd, c.title, c.name, c.input, i64(c.ok ? 1 : 0))
	}
	step(src, file, a.name)
}

recall_enabled :: proc(cli: ^Cli) -> bool {
	if len(adapters_on(cli)) > 0 {
		return true
	}
	errf(cli, "brain recall: no transcript sources enabled.\n\n")
	errf(cli, "  available: %s \n", strings.join(adapters_all(cli), " "))
	errf(cli, "  enable one: brain recall --enable claude\n")
	return false
}

cmd_recall :: proc(cli: ^Cli, args: []string) -> int {
	limit := RECALL_LIMIT
	json_out, sessions, prefix := cli.json, false, false
	terms := make([dynamic]string)
	// Its own transcript is on disk and will be picked up by the next sync,
	// so without this an agent asking whether it has discussed something
	// finds its own current reasoning. --all turns the filter off.
	exclude := getenv(cli, "CLAUDE_CODE_SESSION_ID", getenv(cli, "CLAUDE_SESSION_ID"))

	rest := args
	for len(rest) > 0 {
		arg := rest[0]
		rest = rest[1:]
		switch arg {
		case "--sync":
			if !recall_enabled(cli) {
				return 1
			}
			db, err := open_recall_db(cli)
			if err != "" {
				return fail(cli, err)
			}
			defer sqlite3.close(&db)
			outf(cli, "ingested %d transcript(s)\n", recall_sync(cli, db, full = true))
			outf(cli, "turns: %d\n", scalar_int(db, "select count(*) from turn"))
			outf(cli, "tool calls: %d\n", scalar_int(db, "select count(*) from tool"))
			return 0
		case "--sources":
			on := adapters_on(cli)
			for a in adapters_all(cli) {
				enabled := false
				for o in on {
					if o == a {
						enabled = true
					}
				}
				outf(cli, "  %-8s %s\n", a, enabled ? "enabled" : "disabled")
			}
			return 0
		case "--enable":
			if len(rest) == 0 {
				return fail(cli, "recall --enable <adapter>")
			}
			name := rest[0]
			if _, ok := find_adapter(cli, name); !ok {
				return fail(cli, fmt.aprintf("no such adapter: %s (have: %s )", name, strings.join(adapters_all(cli), " ")))
			}
			path.mkdirs(cli.conf_dir)
			already := false
			for o in adapters_on(cli) {
				if o == name {
					already = true
				}
			}
			if !already {
				path.append_file(cli.conf_sources, strings.concatenate({name, "\n"}))
			}
			outf(cli, "recall: %s enabled\n", name)
			return 0
		case "--disable":
			if len(rest) == 0 {
				return fail(cli, "recall --disable <adapter>")
			}
			name := rest[0]
			if lines, err := path.read_lines(cli.conf_sources); err == nil {
				kept := make([dynamic]string)
				for l in lines {
					if strings.trim_space(l) != name {
						append(&kept, l)
					}
				}
				body := strings.join(kept[:], "\n")
				if body != "" {
					body = strings.concatenate({body, "\n"})
				}
				path.write(cli.conf_sources, body)
			}
			outf(cli, "recall: %s disabled\n", name)
			return 0
		case "--full":
			if len(rest) == 0 {
				return fail(cli, "recall --full <turn-id>")
			}
			db, err := open_recall_db(cli)
			if err != "" {
				return fail(cli, err)
			}
			defer sqlite3.close(&db)
			out(
				cli,
				scalar_text(
					db,
					`select title || char(10) || ts || '  ' || role || '  ' || cwd || char(10) || char(10) || body
					 from turn where id like ? limit 1`,
					strings.concatenate({rest[0], "%"}),
				),
			)
			out(cli, "\n")
			return 0
		case "--limit":
			if len(rest) > 0 {
				limit, _ = strconv.parse_int(rest[0])
				rest = rest[1:]
			}
			if limit <= 0 {
				limit = RECALL_LIMIT
			}
		case "--exclude":
			exclude = len(rest) > 0 ? rest[0] : ""
			if len(rest) > 0 {
				rest = rest[1:]
			}
		case "--json":
			json_out = true
		case "--all":
			exclude = ""
		case "--sessions":
			sessions = true
		case "--prefix":
			prefix = true
		case:
			if strings.has_prefix(arg, "-") {
				return fail(cli, fmt.aprintf("recall: unknown flag %s", arg))
			}
			append(&terms, arg)
		}
	}
	if !recall_enabled(cli) {
		return 1
	}
	if len(terms) == 0 {
		return fail(cli, "usage: brain recall <terms...>")
	}
	db, err := open_recall_db(cli)
	if err != "" {
		return fail(cli, err)
	}
	defer sqlite3.close(&db)
	recall_sync(cli, db, full = false)

	// --prefix makes the last term a prefix match, which is what an
	// interactive caller needs: without the star an FTS5 query matches whole
	// tokens only, so a half-typed word finds nothing.
	m := strings.builder_make()
	for t, i in terms {
		if i > 0 {
			strings.write_string(&m, " AND ")
		}
		strings.write_string(&m, quoted(t))
		if prefix && i == len(terms) - 1 {
			strings.write_byte(&m, '*')
		}
	}
	match := strings.to_string(m)
	where_sql := exclude != "" ? "and t.session <> ?" : "and ? <> ''"
	where_arg: sqlite3.Value = exclude != "" ? exclude : "x"

	// snippet() and bm25() are FTS5 auxiliary functions that must run in the
	// query that reads the fts table, so both are computed in the CTE that
	// does the MATCH and the join happens afterwards.
	if sessions {
		stmt, qerr := sqlite3.query(
			db,
			strings.concatenate(
				{
					`with hit(rid, s) as (
					   select rowid, bm25(turn_fts, 1.0, 2.0)
					   from turn_fts where turn_fts match ?
					   order by rank limit 400
					 )
					 select t.session, count(*), t.adapter, t.title
					 from hit h join turn t on t.rowid = h.rid
					 where 1=1 `,
					where_sql,
					` group by t.session order by min(h.s) limit ?`,
				},
			),
			match,
			where_arg,
			i64(limit),
		)
		if qerr != nil {
			return fail(cli, sql_err(qerr))
		}
		defer sqlite3.finish(&stmt)
		n := 0
		for sqlite3.next(&stmt) {
			n += 1
			outf(cli, "%s\t%d\t%s\t%s\n", sqlite3.text(stmt, 0), sqlite3.integer(stmt, 1), sqlite3.text(stmt, 2), sqlite3.text(stmt, 3))
		}
		// A miss exits non-zero here too, so a caller can tell one from a hit.
		return n > 0 ? 0 : 1
	}

	stmt, qerr := sqlite3.query(
		db,
		strings.concatenate(
			{
				`with hit(rid, snip, n) as (
				   select rowid, snippet(turn_fts, 0, '[', ']', ' … ', 14),
				          bm25(turn_fts, 1.0, 2.0)
				   from turn_fts where turn_fts match ?
				   order by rank limit ?
				 )
				 select substr(t.id,1,8), substr(t.ts,1,10), t.adapter, t.title, h.snip
				 from hit h join turn t on t.rowid = h.rid
				 where 1=1 `,
				where_sql,
				` order by h.n limit ?`,
			},
		),
		match,
		i64(limit * 4),
		where_arg,
		i64(limit),
	)
	if qerr != nil {
		return fail(cli, sql_err(qerr))
	}
	defer sqlite3.finish(&stmt)
	n := 0
	if json_out {
		out(cli, "[\n")
	}
	for sqlite3.next(&stmt) {
		id := sqlite3.text(stmt, 0)
		date := sqlite3.text(stmt, 1)
		agent := sqlite3.text(stmt, 2)
		title := sqlite3.text(stmt, 3)
		snip := sqlite3.text(stmt, 4)
		if json_out {
			if n > 0 {
				out(cli, ",\n")
			}
			out(
				cli,
				strings.concatenate(
					{
						`{"id":"`, json_escape(id),
						`","date":"`, json_escape(date),
						`","agent":"`, json_escape(agent),
						`","title":"`, json_escape(title),
						`","snippet":"`, json_escape(snip),
						`"}`,
					},
				),
			)
		} else {
			outf(cli, "%s  %s  %s\n    %s\n    %s\n\n", date, agent, title, snip, id)
		}
		n += 1
	}
	if json_out {
		out(cli, "\n]\n")
	}
	if n == 0 {
		strings.builder_reset(&cli.out)
		outf(cli, "nothing said about: %s\n", strings.join(terms[:], " "))
		return 1
	}
	return 0
}

// json_escape makes s safe inside a JSON string literal.
json_escape :: proc(s: string) -> string {
	b := strings.builder_make()
	for c in s {
		switch c {
		case '"':
			strings.write_string(&b, `\"`)
		case '\\':
			strings.write_string(&b, `\\`)
		case '\n':
			strings.write_string(&b, `\n`)
		case '\r':
			strings.write_string(&b, `\r`)
		case '\t':
			strings.write_string(&b, `\t`)
		case:
			if c < 0x20 {
				fmt.sbprintf(&b, `\u%04x`, c)
			} else {
				strings.write_rune(&b, c)
			}
		}
	}
	return strings.to_string(b)
}

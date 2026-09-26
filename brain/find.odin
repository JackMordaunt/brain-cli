package brain

import "core:strings"
import "core:unicode/utf8"

import "jm:sqlite3"

// Handle matches outrank body matches, so a bullet named **review** beats a
// handoff that merely mentions the word.

// Match is the two FTS5 strings `find` tries in order: every term (with its
// synonyms) required, then any term.
Match :: struct {
	and, or: string,
}

// build_match tokenises a raw query and expands each term with its synonyms.
// ok is false when nothing survives tokenising.
build_match :: proc(db: sqlite3.Db, raw: string) -> (m: Match, ok: bool) {
	groups := make([dynamic]string)
	lowered := strings.to_lower(raw)
	buf := make([]byte, len(lowered))
	for c, i in transmute([]byte)lowered {
		switch {
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_':
			buf[i] = c
		case:
			buf[i] = ' '
		}
	}
	for t in strings.fields(string(buf)) {
		grp := strings.builder_make()
		strings.write_string(&grp, quoted(t))
		for s in column_texts(db, "select expansion from synonyms where term=?", t) {
			if s == "" {
				continue
			}
			strings.write_string(&grp, " OR ")
			strings.write_string(&grp, quoted(s))
		}
		append(&groups, strings.concatenate({"(", strings.to_string(grp), ")"}))
	}
	if len(groups) == 0 {
		return {}, false
	}
	return Match{and = strings.join(groups[:], " AND "), or = strings.join(groups[:], " OR ")}, true
}

// quoted wraps a term as an FTS5 string, dropping any quote inside it.
quoted :: proc(t: string) -> string {
	inner, _ := strings.replace_all(t, "\"", "")
	return strings.concatenate({"\"", inner, "\""})
}

// Hit is one bullet result: where it is and the line as written.
Hit :: struct {
	file:   string,
	line:   i64,
	raw:    string,
	handle: string,
}

// query_fts returns the best bullets for a match string, up to FIND_LIMIT.
query_fts :: proc(db: sqlite3.Db, match: string) -> []Hit {
	hits := make([dynamic]Hit)
	stmt, err := sqlite3.query(
		db,
		`select b.file, b.line, b.raw, b.handle
		 from bullets_fts f join bullets b on b.id = f.rowid
		 where bullets_fts match ?
		 order by bm25(bullets_fts, 10.0, 6.0, 1.0)
		 limit ?`,
		match,
		i64(FIND_LIMIT),
	)
	if err != nil {
		return nil
	}
	defer sqlite3.finish(&stmt)
	for sqlite3.next(&stmt) {
		append(
			&hits,
			Hit {
				file = sqlite3.text(stmt, 0),
				line = sqlite3.integer(stmt, 1),
				raw = sqlite3.text(stmt, 2),
				handle = sqlite3.text(stmt, 3),
			},
		)
	}
	return hits[:]
}

// Doc is one prose result, already cut to the length find prints.
Doc :: struct {
	locator: string, // file:line
	text:    string,
}

// query_lines returns matching prose from outside the core files, up to 5.
query_lines :: proc(db: sqlite3.Db, match: string) -> []Doc {
	docs := make([dynamic]Doc)
	stmt, err := sqlite3.query(
		db,
		`select l.file || ':' || l.line, substr(l.text,1,200)
		 from lines_fts f join lines l on l.id = f.rowid
		 where lines_fts match ?
		   and l.file not in ('AI/MEMORY.md','AI/LEARNINGS.md','AI/TUNINGS.md')
		 order by bm25(lines_fts) limit 5`,
		match,
	)
	if err != nil {
		return nil
	}
	defer sqlite3.finish(&stmt)
	for sqlite3.next(&stmt) {
		append(&docs, Doc{locator = sqlite3.text(stmt, 0), text = sqlite3.text(stmt, 1)})
	}
	return docs[:]
}

// Who asked. Agents set BRAIN_CALLER/BRAIN_SESSION; Claude Code is recognised
// from its own environment.
caller_id :: proc(cli: ^Cli) -> string {
	if c := getenv(cli, "BRAIN_CALLER"); c != "" {
		return c
	}
	if getenv(cli, "CLAUDECODE") != "" {
		return "claude"
	}
	return ""
}

session_id :: proc(cli: ^Cli) -> string {
	return getenv(cli, "BRAIN_SESSION", getenv(cli, "CLAUDE_CODE_SESSION_ID"))
}

cmd_find :: proc(cli: ^Cli, args: []string) -> int {
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	if len(args) == 0 {
		return fail(cli, "usage: brain find <terms...>")
	}
	db, oerr := open_db(cli.db)
	if oerr != "" {
		return fail(cli, oerr)
	}
	defer sqlite3.close(&db)

	raw := strings.join(args, " ")
	m, ok := build_match(db, raw)
	if !ok {
		return fail(cli, "empty query")
	}

	used := m.and
	hits := query_fts(db, m.and)
	if len(hits) == 0 {
		hits = query_fts(db, m.or)
		used = m.or
	}
	docs := query_lines(db, m.and)
	if len(docs) == 0 {
		docs = query_lines(db, m.or)
	}
	n := len(hits) + len(docs)

	// Every query is logged, and which bullets answered, so a bullet no query
	// ever returns becomes visible and a miss becomes the synonym backlog.
	sqlite3.exec_args(
		db,
		"insert into queries(ts,q,hits,caller,session) values(datetime('now'),?,?,?,?)",
		raw,
		i64(n),
		caller_id(cli),
		session_id(cli),
	)
	qid := sqlite3.last_id(db)
	if len(hits) > 0 && qid > 0 {
		sqlite3.exec_args(
			db,
			`insert into query_hits(query_id,file,handle,rank)
			 select ?, b.file, b.handle,
			   row_number() over (order by bm25(bullets_fts, 10.0, 6.0, 1.0))
			 from bullets_fts f join bullets b on b.id = f.rowid
			 where bullets_fts match ?
			 order by bm25(bullets_fts, 10.0, 6.0, 1.0) limit ?`,
			qid,
			used,
			i64(FIND_LIMIT),
		)
	}

	if n == 0 {
		outf(cli, "no hits for: %s\n", raw)
		out(cli, "(logged — 'brain log' lists zero-hit queries as the synonym backlog)\n")
		return 1
	}
	// A bullet result is three lines (locator, bullet, blank). The output is
	// capped by bytes so a broad query cannot flood an agent's context.
	written := 0
	capped := false
	for h in hits {
		entry := strings.concatenate({h.file, ":", int_str(h.line), "\n", h.raw, "\n\n"})
		if written + len(entry) > FIND_BYTES {
			capped = true
			break
		}
		out(cli, entry)
		written += len(entry)
	}
	if capped {
		out(cli, "… output capped; narrow the query\n")
	}
	if len(docs) > 0 {
		out(cli, "-- documents --\n")
		for d in docs {
			line := strings.concatenate({d.locator, "  ", d.text})
			out(cli, rune_prefix(line, 220))
			out(cli, "\n")
		}
	}
	return 0
}

// rune_prefix returns at most n characters of s.
rune_prefix :: proc(s: string, n: int) -> string {
	if utf8.rune_count_in_string(s) <= n {
		return s
	}
	return strings.cut(s, 0, n)
}

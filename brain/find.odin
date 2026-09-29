package brain

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

import "jm:sqlite3"

// Handle matches outrank body matches, so a bullet named **review** beats a
// handoff that merely mentions the word.

// Match is the FTS5 strings `find` tries in order: every term (with its
// synonyms) required, then any term. Bullets also take a prefix match on
// the handle and alias columns; prose has no such columns and keeps exact
// terms.
Match :: struct {
	and, or:             string, // bullets
	prose_and, prose_or: string,
}

// PREFIX_MIN is the shortest term that also matches as a prefix of a handle
// or alias, so `libgit` reaches `libgit2` and a typo's stem still lands.
PREFIX_MIN :: 3

// build_match tokenises a raw query and widens each term with its synonyms
// and, from PREFIX_MIN characters, a prefix match on the handle and alias
// columns. Prose keeps exact terms. ok is false when nothing survives
// tokenising.
build_match :: proc(db: sqlite3.Db, raw: string) -> (m: Match, ok: bool) {
	groups := make([dynamic]string)
	prose := make([dynamic]string)
	for t in query_terms(raw) {
		grp := strings.builder_make()
		strings.write_string(&grp, quoted(t))
		for s in column_texts(db, "select expansion from synonyms where term=?", t) {
			if s == "" {
				continue
			}
			strings.write_string(&grp, " OR ")
			strings.write_string(&grp, quoted(s))
		}
		append(&prose, strings.concatenate({"(", strings.to_string(grp), ")"}))
		if utf8.rune_count_in_string(t) >= PREFIX_MIN {
			strings.write_string(&grp, " OR {handle aliases} : ")
			strings.write_string(&grp, quoted(t))
			strings.write_string(&grp, "*")
		}
		append(&groups, strings.concatenate({"(", strings.to_string(grp), ")"}))
	}
	if len(groups) == 0 {
		return {}, false
	}
	return Match {
			and = strings.join(groups[:], " AND "),
			or = strings.join(groups[:], " OR "),
			prose_and = strings.join(prose[:], " AND "),
			prose_or = strings.join(prose[:], " OR "),
		},
		true
}

// query_terms lowercases text and splits it on anything but a letter, digit,
// dot, dash or underscore, which is how a handle is compared to a query too.
query_terms :: proc(raw: string) -> []string {
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
	return strings.fields(string(buf))
}

// quoted wraps a term as an FTS5 string, dropping any quote inside it.
quoted :: proc(t: string) -> string {
	inner, _ := strings.replace_all(t, "\"", "")
	return strings.concatenate({"\"", inner, "\""})
}

// Hit is one bullet result: where it is, the line as written, its parts,
// and its bm25 score. FTS5's bm25() returns a negative number and a better
// match is lower (sqlite.org/fts5.html, "The bm25() function").
Hit :: struct {
	file:    string,
	line:    i64,
	raw:     string,
	handle:  string,
	aliases: string,
	fact:    string,
	source:  string,
	date:    string,
	score:   f64,
}

// query_fts returns the best bullets for a match string, up to limit.
// Equal scores fall to the newer bullet.
query_fts :: proc(db: sqlite3.Db, match: string, limit := FIND_LIMIT) -> []Hit {
	hits := make([dynamic]Hit)
	stmt, err := sqlite3.query(
		db,
		`select b.file, b.line, b.raw, b.handle, b.aliases, b.fact, b.source, b.date,
		        bm25(bullets_fts, 10.0, 6.0, 1.0) as score
		 from bullets_fts f join bullets b on b.id = f.rowid
		 where bullets_fts match ?
		 order by score, b.date desc
		 limit ?`,
		match,
		i64(limit),
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
				aliases = sqlite3.text(stmt, 4),
				fact = sqlite3.text(stmt, 5),
				source = sqlite3.text(stmt, 6),
				date = sqlite3.text(stmt, 7),
				score = sqlite3.real(stmt, 8),
			},
		)
	}
	return hits[:]
}

// EXACT_RATIO is the share of the named bullet's score a neighbour needs to
// stay in the answer once the query names a handle or alias outright.
EXACT_RATIO :: 0.5

// cut_to_exact puts a hit whose handle or alias is the whole query first and
// drops the hits that are not near ties with it, so an exact ask gets its
// answer and not seven neighbours. A query naming no bullet comes back as
// it was.
cut_to_exact :: proc(hits: []Hit, raw: string) -> []Hit {
	q := strings.join(query_terms(raw), " ")
	ex := -1
	for h, i in hits {
		if names(h, q) {
			ex = i
			break
		}
	}
	if ex < 0 {
		return hits
	}
	kept := make([dynamic]Hit)
	append(&kept, hits[ex])
	for h, i in hits {
		if i != ex && h.score <= hits[ex].score * EXACT_RATIO {
			append(&kept, h)
		}
	}
	return kept[:]
}

// names reports whether q, already normalised by query_terms, is the hit's
// handle or one of its aliases.
names :: proc(h: Hit, q: string) -> bool {
	if strings.join(query_terms(h.handle), " ") == q {
		return true
	}
	for a in strings.split(h.aliases, ",") {
		if strings.join(query_terms(a), " ") == q {
			return true
		}
	}
	return false
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

// Form is how a hit prints: the line as written, or for an agent the
// handle, fact and date alone, since the aliases and source only cost its
// context. An agent gets Terse unless it asks for --raw; a terminal gets Raw
// unless it asks for --terse.
Form :: enum {
	Raw,
	Terse,
}

// format_hit renders one hit. A bullet written without a source parses its
// fact as the source, so the terse form takes whichever field is there; one
// with neither prints as written.
format_hit :: proc(h: Hit, form: Form) -> string {
	loc := strings.concatenate({h.file, ":", int_str(h.line)})
	body := h.fact != "" ? h.fact : h.source
	if form == .Terse && body != "" {
		return strings.concatenate({loc, " **", h.handle, "**", SEP, body, SEP, h.date, "\n"})
	}
	return strings.concatenate({loc, "\n", h.raw, "\n\n"})
}

cmd_find :: proc(cli: ^Cli, args: []string) -> int {
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	form := caller_id(cli) != "" ? Form.Terse : Form.Raw
	budget := FIND_BYTES
	terms := make([dynamic]string)
	rest := args
	for len(rest) > 0 {
		arg := rest[0]
		rest = rest[1:]
		switch arg {
		case "--terse":
			form = .Terse
		case "--raw":
			form = .Raw
		case "--budget":
			n, ok := 0, false
			if len(rest) > 0 {
				n, ok = strconv.parse_int(rest[0])
				rest = rest[1:]
			}
			if !ok || n <= 0 {
				return fail(cli, "usage: brain find --budget <tokens>")
			}
			budget = n * 4
		case:
			append(&terms, arg)
		}
	}
	if len(terms) == 0 {
		return fail(cli, "usage: brain find <terms...> [--budget <tokens>] [--raw|--terse]")
	}
	db, oerr := open_db(cli.db)
	if oerr != "" {
		return fail(cli, oerr)
	}
	defer sqlite3.close(&db)

	raw := strings.join(terms[:], " ")
	m, ok := build_match(db, raw)
	if !ok {
		return fail(cli, "empty query")
	}

	hits := query_fts(db, m.and)
	if len(hits) == 0 {
		hits = query_fts(db, m.or)
	}
	hits = cut_to_exact(hits, raw)
	docs := query_lines(db, m.prose_and)
	if len(docs) == 0 {
		docs = query_lines(db, m.prose_or)
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
	for h, i in hits {
		sqlite3.exec_args(
			db,
			"insert into query_hits(query_id,file,handle,rank) values(?,?,?,?)",
			qid,
			h.file,
			h.handle,
			i64(i + 1),
		)
	}

	if n == 0 {
		outf(cli, "no hits for: %s\n", raw)
		out(cli, "(logged — 'brain log' lists zero-hit queries as the synonym backlog)\n")
		return 1
	}
	// The output is capped by bytes, the budget, so a broad query cannot
	// flood an agent's context. Bullets go first; what was printed is logged
	// so the cost of a session's lookups can be read back.
	written := 0
	capped := false
	for h in hits {
		entry := format_hit(h, form)
		if written + len(entry) > budget {
			capped = true
			break
		}
		out(cli, entry)
		written += len(entry)
	}
	if !capped && len(docs) > 0 {
		out(cli, "-- documents --\n")
		written += len("-- documents --\n")
		for d in docs {
			line := strings.concatenate({rune_prefix(strings.concatenate({d.locator, "  ", d.text}), 220), "\n"})
			if written + len(line) > budget {
				capped = true
				break
			}
			out(cli, line)
			written += len(line)
		}
	}
	if capped {
		out(cli, "… output capped; narrow the query or raise --budget\n")
	}
	sqlite3.exec_args(db, "update queries set bytes=? where id=?", i64(written), qid)
	return 0
}

// rune_prefix returns at most n characters of s.
rune_prefix :: proc(s: string, n: int) -> string {
	if utf8.rune_count_in_string(s) <= n {
		return s
	}
	return strings.cut(s, 0, n)
}

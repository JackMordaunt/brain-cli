package brain

import "core:strconv"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import "jm:sqlite3"

import "../term"

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
// Equal scores fall to a reviewed bullet, then to the newer one.
query_fts :: proc(db: sqlite3.Db, match: string, limit := FIND_LIMIT) -> []Hit {
	hits := make([dynamic]Hit)
	stmt, err := sqlite3.query(
		db,
		`select b.file, b.line, b.raw, b.handle, b.aliases, b.fact, b.source, b.date,
		        bm25(bullets_fts, 10.0, 6.0, 1.0) as score
		 from bullets_fts f join bullets b on b.id = f.rowid
		 where bullets_fts match ?
		 order by score, b.file = 'AI/INBOX.md', b.date desc
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
cut_to_exact :: proc(hits: []Hit, raw: string) -> (kept_hits: []Hit, named: bool) {
	q := strings.join(query_terms(raw), " ")
	ex := -1
	for h, i in hits {
		if names(h, q) {
			ex = i
			break
		}
	}
	if ex < 0 {
		return hits, false
	}
	kept := make([dynamic]Hit)
	append(&kept, hits[ex])
	for h, i in hits {
		if i != ex && h.score <= hits[ex].score * EXACT_RATIO {
			append(&kept, h)
		}
	}
	return kept[:], true
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
	file:    string,
	line:    i64,
	date:    string, // the note's date, from its name; "" when it has none
	text:    string,
}

// query_lines returns matching prose from outside the core files, up to
// limit, five by default.
query_lines :: proc(db: sqlite3.Db, match: string, limit := 5) -> []Doc {
	docs := make([dynamic]Doc)
	stmt, err := sqlite3.query(
		db,
		`select l.file, l.line, substr(l.text,1,600), coalesce(d.date,'')
		 from lines_fts f join lines l on l.id = f.rowid left join docs d on d.file = l.file
		 where lines_fts match ?
		   and l.file not in ('AI/MEMORY.md','AI/LEARNINGS.md','AI/TUNINGS.md','AI/INBOX.md')
		 order by bm25(lines_fts) limit ?`,
		match,
		i64(limit),
	)
	if err != nil {
		return nil
	}
	defer sqlite3.finish(&stmt)
	for sqlite3.next(&stmt) {
		file, line := sqlite3.text(stmt, 0), sqlite3.integer(stmt, 1)
		append(
			&docs,
			Doc {
				locator = strings.concatenate({file, ":", int_str(line)}),
				file = file,
				line = line,
				text = sqlite3.text(stmt, 2),
				date = sqlite3.text(stmt, 3),
			},
		)
	}
	return docs[:]
}

// term_meets says whether a word of a bullet or note meets a query term:
// equal, or one the other's prefix from four letters, so `install` meets
// `installs` and `linux` meets `linux-amd64`; a rough stand-in for the
// index's stemming, close enough for counting shared words.
term_meets :: proc(word, term: string) -> bool {
	if word == term {
		return true
	}
	if len(term) >= 4 && len(word) >= 4 {
		return strings.has_prefix(word, term) || strings.has_prefix(term, word)
	}
	return false
}

// count_met_terms counts the distinct terms a text meets.
count_met_terms :: proc(text: string, terms: []string) -> int {
	words := query_terms(text)
	n := 0
	for t in terms {
		for w in words {
			if term_meets(w, t) {
				n += 1
				break
			}
		}
	}
	return n
}

// PARTIAL_LIMIT is how many bullets holding only some of the terms follow
// the ones holding all; a partial bullet must meet at least half the terms.
PARTIAL_LIMIT :: 3

// SHADOW_OVERLAP is how many distinctive words (four letters or more, not
// query noise) a note line must share with a newer bullet's fact to count
// as an older telling of the same thing.
SHADOW_OVERLAP :: 3

// shadowed_by names the bullet among hits that tells what a note line
// tells, more recently: the line's file is older than the bullet (or
// undated) and the two share SHADOW_OVERLAP distinctive words. On
// tools/proof (sonnet, 2026-09-29 and 2026-10-02) agents took a planted
// stale note's line over the current bullet above it, section header or
// not, so the line itself now says which bullet outranks it.
shadowed_by :: proc(d: Doc, hits: []Hit) -> string {
	words := make([dynamic]string)
	stop := PRIME_STOP
	for t in query_terms(d.text) {
		if utf8.rune_count_in_string(t) >= 4 && !slice.contains(stop[:], t) && !slice.contains(words[:], t) {
			append(&words, t)
		}
	}
	best, best_n := "", 0
	for h in hits {
		if h.handle == "" || (d.date != "" && d.date >= h.date) {
			continue
		}
		n := count_met_terms(h.fact, words[:])
		if n >= SHADOW_OVERLAP && n > best_n {
			best, best_n = h.handle, n
		}
	}
	return best
}

// PARAGRAPH_MAX bounds a note paragraph served to an agent.
PARAGRAPH_MAX :: 500

// doc_paragraph returns the note's paragraph from the hit line on: the
// contiguous lines until a blank or a heading, PARAGRAPH_MAX characters at
// most. A fact that lives only in a note was costing an agent several
// rounds of 200-character snippets (tools/proof, 2026-09-29: 113K to 200K
// tokens against grep's 74K to 129K); the paragraph answers in one.
doc_paragraph :: proc(db: sqlite3.Db, d: Doc) -> string {
	b := strings.builder_make()
	stmt, err := sqlite3.query(
		db,
		"select text from lines where file = ? and line >= ? and line < ? order by line",
		d.file,
		d.line,
		d.line + 12,
	)
	if err != nil {
		return d.text
	}
	defer sqlite3.finish(&stmt)
	for sqlite3.next(&stmt) {
		t := strings.trim_space(sqlite3.text(stmt, 0))
		if t == "" || (strings.has_prefix(t, "#") && strings.builder_len(b) > 0) {
			break
		}
		if strings.builder_len(b) > 0 {
			strings.write_string(&b, " ")
		}
		strings.write_string(&b, t)
		if strings.builder_len(b) >= PARAGRAPH_MAX {
			break
		}
	}
	if strings.builder_len(b) == 0 {
		return d.text
	}
	return rune_prefix(strings.to_string(b), PARAGRAPH_MAX)
}

// doc_entry renders one note line under the bullets. An agent gets the
// paragraph, so a fact that lives only in a note is read once; a terminal
// gets the line. A line an above bullet outranks is served as the line
// with the bullet's name on it, whoever asks.
doc_entry :: proc(db: sqlite3.Db, d: Doc, hits: []Hit, form: Form) -> string {
	if by := shadowed_by(d, hits); by != "" {
		return strings.concatenate(
			{rune_prefix(strings.concatenate({d.locator, "  ", d.text}), 220), " ← older than **", by, "** above; the bullet is current\n"},
		)
	}
	if form == .Terse {
		return strings.concatenate({d.locator, "  ", doc_paragraph(db, d), "\n"})
	}
	return strings.concatenate({rune_prefix(strings.concatenate({d.locator, "  ", d.text}), 220), "\n"})
}

// Who asked. Agents set BRAIN_CALLER/BRAIN_SESSION; Claude Code is recognised
// from its own environment, and any other agent term knows from its own:
// AI_AGENT's value names it, and either of Codex's sandbox variables
// being set names it codex.
caller_id :: proc(cli: ^Cli) -> string {
	if c := getenv(cli, "BRAIN_CALLER"); c != "" {
		return c
	}
	if getenv(cli, "CLAUDECODE") != "" {
		return "claude"
	}
	switch term.agent(env_lookup, cli) {
	case "":
		return ""
	case "AI_AGENT":
		return getenv(cli, "AI_AGENT")
	case "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED":
		return "codex"
	}
	return "agent"
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
// with neither prints as written. with_source keeps the source clause in the
// terse form: the line's provenance, at 5 to 10 percent more of a bullet.
format_hit :: proc(h: Hit, form: Form, with_source := false) -> string {
	loc := strings.concatenate({h.file, ":", int_str(h.line)})
	if h.file == INBOX_FILE {
		loc = strings.concatenate({loc, " ", UNREVIEWED})
	}
	body := h.fact != "" ? h.fact : h.source
	if form == .Terse && body != "" {
		if with_source && h.fact != "" && h.source != "" {
			return strings.concatenate({loc, " **", h.handle, "**", SEP, body, SEP, h.source, SEP, h.date, "\n"})
		}
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
	// Notes (prose lines) always follow the bullets. The proof measured the
	// alternative, notes only when fewer than two bullets answered and none
	// was named outright (BRAIN_NOTES=short): it lost five of eight answers
	// that lived only in a note on sonnet and four of eight on opus, at twice
	// the tokens, and gained nothing on the rest (2026-09-29). BRAIN_TERSE=
	// source keeps the source clause in the terse form; it changed nothing
	// measurable and stays as a knob the proof can run.
	want_notes := false
	notes_short := getenv(cli, "BRAIN_NOTES") == "short"
	with_source := getenv(cli, "BRAIN_TERSE") == "source"
	weighted := rank_weighted(cli)
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
		case "--notes":
			want_notes = true
		case "--plain":
			weighted = false
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
	if weighted {
		hits = weigh(db, hits)
	}
	named: bool
	hits, named = cut_to_exact(hits, raw)
	// A bullet one word short of the query still shows: unless a handle was
	// named outright, bullets holding some of the terms fill the list after
	// those holding them all, and the output heads each group. Before
	// 2026-10-02 the OR query ran only when the AND query found nothing, so
	// `brainfold install linux` showed two bullets that happened to hold all
	// three words and not the one that held the install line.
	partial := 0
	if !named && len(hits) < FIND_LIMIT {
		terms := query_terms(raw)
		need := max(1, (len(terms) + 1) / 2)
		filled := make([dynamic]Hit)
		append(&filled, ..hits)
		for h in query_fts(db, m.or, FIND_LIMIT * 3) {
			if len(filled) >= FIND_LIMIT || partial >= PARTIAL_LIMIT {
				break
			}
			seen := false
			for k in hits {
				if k.file == h.file && k.line == h.line {
					seen = true
					break
				}
			}
			if seen || count_met_terms(h.raw, terms) < need {
				continue
			}
			append(&filled, h)
			partial += 1
		}
		hits = filled[:]
	}
	docs: []Doc
	if want_notes || !notes_short || (len(hits) - partial < 2 && !named) {
		docs = query_lines(db, m.prose_and)
		if len(docs) == 0 {
			docs = query_lines(db, m.prose_or)
		}
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

	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "query", raw)
		jw_key(&w, "hits")
		jw_arr(&w)
		for h in hits {
			jw_hit(&w, h)
		}
		jw_end_arr(&w)
		jw_key(&w, "documents")
		jw_arr(&w)
		for d in docs {
			jw_obj(&w)
			jw_field(&w, "locator", d.locator)
			jw_field(&w, "text", d.text)
			jw_end_obj(&w)
		}
		jw_end_arr(&w)
		jw_end_obj(&w)
		sqlite3.exec_args(db, "update queries set bytes=? where id=?", i64(strings.builder_len(w.b)), qid)
		jw_flush(cli, &w)
		return n == 0 ? 1 : 0
	}
	if n == 0 {
		outf(cli, "nothing in the vault for: %s\n", raw)
		out(cli, MISS_TAIL)
		return 1
	}
	// The output is capped by bytes, the budget, so a broad query cannot
	// flood an agent's context. Bullets go first; what was printed is logged
	// so the cost of a session's lookups can be read back.
	written := 0
	capped := false
	full := len(hits) - partial
	for h, i in hits {
		if i == full && partial > 0 {
			head := full == 0 ? PARTIAL_HEAD : SOME_HEAD
			out(cli, head)
			written += len(head)
		}
		entry := format_hit(h, form, with_source)
		if written + len(entry) > budget {
			capped = true
			break
		}
		out(cli, entry)
		written += len(entry)
	}
	if !capped && len(docs) > 0 {
		out(cli, NOTES_HEAD)
		written += len(NOTES_HEAD)
		for d in docs {
			line := doc_entry(db, d, hits, form)
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

// NOTES_HEAD introduces the prose lines under the bullets. An agent reading
// both needs to know which wins: a note is a snapshot of when it was
// written, a bullet was kept true. On tools/proof (sonnet, 2026-09-29) an
// agent took a stale plan's line over the current bullet above it.
NOTES_HEAD :: "-- notes (older snapshots; a bullet above outranks them) --\n"

// PARTIAL_HEAD and MISS_TAIL make a weak answer final. On tools/proof
// (sonnet, 2026-10-02) an agent asked seven times, each query a rewording,
// before saying the vault had nothing; the nearest bullets by some terms
// looked like an invitation to try again.
PARTIAL_HEAD :: "-- no bullet holds every term; the nearest by some of them. If none answers, the vault does not have it: say so, do not reword and retry --\n"
SOME_HEAD :: "-- also, by some of the terms --\n"
MISS_TAIL :: "(noted; brain log lists what keeps missing. The vault does not have it: say so, do not reword and retry)\n"

// rune_prefix returns at most n characters of s.
rune_prefix :: proc(s: string, n: int) -> string {
	if utf8.rune_count_in_string(s) <= n {
		return s
	}
	return strings.cut(s, 0, n)
}

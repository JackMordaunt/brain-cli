package brain

import "core:math"
import "core:os"
import "core:slice"
import "core:strings"

import "jm:path"
import "jm:sqlite3"

// The find log says what was served; nothing says whether it helped.
// Learn reads both logs back as reinforcement. A serve was used when the
// session stopped searching for those terms, no correction followed
// within ten turns, and, the strong form, the agent went on to name the
// handle. A query term that led to a used bullet and is not among its
// names is wired to it as an alias once three sessions agree. Every
// weight stays text: an alias is a word in the bullet, a boost is a
// number read off a log, and both are reversed by an edit.

LEARN_SESSIONS :: 3 // distinct sessions before a term becomes an alias
LEARN_DEAD_DAYS :: 180 // days an alias may go unqueried before it is dead
LEARN_MIN_QUERIES :: 50 // log size below which nothing is dead yet
LEARN_TERM_MIN :: 4 // shorter query terms are not aliases
WEIGHT_CAP :: 1.0 // most bm25 a used bullet may gain; one tie margin
WEIGHT_SCALE :: 0.5 // boost = min(cap, scale * ln(1 + used))

// Serve_Outcome is one served bullet and what followed it in its session.
Serve_Outcome :: struct {
	query_id: i64,
	handle:   string,
	used:     bool,
	strong:   bool,
}

cmd_learn :: proc(cli: ^Cli, args: []string) -> int {
	apply := false
	for a in args {
		switch a {
		case "--apply":
			apply = true
		case:
			return fail(cli, "usage: brain learn [--apply]")
		}
	}
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	db, oerr := open_db(cli.db)
	if oerr != "" {
		return fail(cli, oerr)
	}
	defer sqlite3.close(&db)
	outcomes := learn_outcomes(cli, db)
	candidates := alias_candidates(db)
	dead := dead_aliases(db)
	applied := 0
	if apply {
		applied = apply_aliases(cli, candidates)
		if len(dead.synonyms) > 0 {
			applied += prune_synonyms(cli, dead.synonyms)
		}
		if applied > 0 {
			sync(cli, quiet = true)
		}
	}
	used, strong := 0, 0
	for o in outcomes {
		if o.used {
			used += 1
		}
		if o.strong {
			strong += 1
		}
	}
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field_int(&w, "serves", i64(len(outcomes)))
		jw_field_int(&w, "used", i64(used))
		jw_field_int(&w, "strong", i64(strong))
		jw_key(&w, "aliases")
		jw_arr(&w)
		for c in candidates {
			jw_obj(&w)
			jw_field(&w, "handle", c.handle)
			jw_field(&w, "file", c.file)
			jw_field(&w, "term", c.term)
			jw_field_int(&w, "sessions", i64(c.sessions))
			jw_end_obj(&w)
		}
		jw_end_arr(&w)
		jw_key(&w, "dead_aliases")
		jw_arr(&w)
		for d in dead.aliases {
			jw_str(&w, d)
		}
		jw_end_arr(&w)
		jw_key(&w, "dead_synonyms")
		jw_arr(&w)
		for d in dead.synonyms {
			jw_str(&w, d)
		}
		jw_end_arr(&w)
		jw_field_int(&w, "applied", i64(applied))
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	outf(cli, "%d serves with a session: %d used, %d named back by the agent\n", len(outcomes), used, strong)
	out(cli, "\n== aliases to learn: a query word that found a bullet it does not name, in three sessions or more ==\n")
	for c in candidates {
		outf(cli, "%s **%s** += %s (%d sessions)\n", c.file, c.handle, c.term, c.sessions)
	}
	outf(cli, "\n== dead: not in any query for %d days ==\n", LEARN_DEAD_DAYS)
	if dead.too_few {
		outf(cli, "   too few queries logged (%d) to call anything dead yet\n", LEARN_MIN_QUERIES)
	}
	for d in dead.aliases {
		outf(cli, "alias %s\n", d)
	}
	for d in dead.synonyms {
		outf(cli, "synonym %s\n", d)
	}
	if apply {
		outf(cli, "\napplied %d edits\n", applied)
	} else if len(candidates) > 0 || len(dead.synonyms) > 0 {
		out(cli, "\n--apply writes the aliases into the bullets and the dead synonyms out of synonyms.tsv\n")
	}
	return 0
}

// learn_outcomes decides every logged serve that had a session, writes
// the verdicts to serve_outcome, and returns them. Serves without a
// transcript to read are judged on the find log alone.
learn_outcomes :: proc(cli: ^Cli, db: sqlite3.Db) -> []Serve_Outcome {
	Serve :: struct {
		query_id:        i64,
		handle, aliases: string,
		session, ts, q:  string,
	}
	serves := make([dynamic]Serve)
	stmt, err := sqlite3.query(
		db,
		`select q.id, h.handle, coalesce(b.aliases,''), q.session, q.ts, q.q
		 from query_hits h join queries q on q.id = h.query_id
		 left join bullets b on b.handle = h.handle and b.file = h.file
		 where q.session <> '' order by q.session, q.ts`,
	)
	if err != nil {
		return nil
	}
	for sqlite3.next(&stmt) {
		append(
			&serves,
			Serve {
				query_id = sqlite3.integer(stmt, 0),
				handle = strings.clone(sqlite3.text(stmt, 1)),
				aliases = strings.clone(sqlite3.text(stmt, 2)),
				session = strings.clone(sqlite3.text(stmt, 3)),
				ts = strings.clone(sqlite3.text(stmt, 4)),
				q = strings.clone(sqlite3.text(stmt, 5)),
			},
		)
	}
	sqlite3.finish(&stmt)

	rc: sqlite3.Db
	have_rc := false
	if len(adapters_on(cli)) > 0 && os.exists(cli.recall_db) {
		if opened, rerr := open_recall_db(cli); rerr == "" {
			rc, have_rc = opened, true
		}
	}
	defer if have_rc {
		sqlite3.close(&rc)
	}
	// Corrections by session, read once.
	corrections := make(map[string][dynamic]string) // session -> correction ts
	if have_rc {
		for m in lesson_moments(rc, 0, "", "") {
			if m.kind != "correction" {
				continue
			}
			list, has := corrections[m.session]
			if !has {
				list = make([dynamic]string)
			}
			append(&list, m.ts)
			corrections[m.session] = list
		}
	}

	outcomes := make([dynamic]Serve_Outcome)
	for s in serves {
		o := Serve_Outcome{query_id = s.query_id, handle = s.handle, used = true}
		names := name_terms(s.handle, s.aliases)
		// Kept looking: a later lookup in the session on the same names.
		for later in column_texts(db, "select q from queries where session=? and ts > ? and id <> ?", s.session, s.ts, s.query_id) {
			for t in query_terms(later) {
				if names[t] {
					o.used = false
				}
			}
		}
		if o.used && have_rc {
			if list, has := corrections[s.session]; has {
				for cts in list {
					if cts <= turn_time(s.ts) {
						continue
					}
					between := scalar_int(rc, "select count(*) from turn where session=? and ts > ? and ts <= ?", s.session, turn_time(s.ts), cts)
					if between <= SUSPECT_TURNS {
						o.used = false
					}
				}
			}
			if o.used {
				n := scalar_int(
					rc,
					"select count(*) from turn where session=? and role='assistant' and ts > ? and instr(lower(body), ?) > 0",
					s.session,
					turn_time(s.ts),
					strings.to_lower(s.handle),
				)
				o.strong = n > 0
			}
		}
		append(&outcomes, o)
	}
	sqlite3.exec(db, "begin")
	sqlite3.exec(db, "delete from serve_outcome")
	for o in outcomes {
		sqlite3.exec_args(db, "insert into serve_outcome(query_id,handle,used,strong) values(?,?,?,?)", o.query_id, o.handle, i64(o.used ? 1 : 0), i64(o.strong ? 1 : 0))
	}
	sqlite3.exec(db, "commit")
	return outcomes[:]
}

// name_terms is the words of a handle and its aliases.
name_terms :: proc(handle, aliases: string) -> map[string]bool {
	names := make(map[string]bool)
	for t in query_terms(handle) {
		names[t] = true
	}
	for t in query_terms(aliases) {
		names[t] = true
	}
	return names
}

Alias_Candidate :: struct {
	handle, file, term: string,
	sessions:           int,
}

// alias_candidates is every (bullet, query term) pair where the term led
// to a used serve of the bullet and is not among its names, in
// LEARN_SESSIONS or more distinct sessions.
alias_candidates :: proc(db: sqlite3.Db) -> []Alias_Candidate {
	Count :: struct {
		handle, file, term: string,
		sessions:           map[string]bool,
	}
	counts := make(map[string]^Count)
	order := make([dynamic]string)
	stmt, err := sqlite3.query(
		db,
		`select h.handle, h.file, q.q, q.session, coalesce(b.aliases,''), coalesce(b.fact,'')
		 from serve_outcome o join query_hits h on h.query_id = o.query_id and h.handle = o.handle
		 join queries q on q.id = o.query_id
		 left join bullets b on b.handle = h.handle and b.file = h.file
		 where o.used = 1 and q.session <> ''`,
	)
	if err != nil {
		return nil
	}
	defer sqlite3.finish(&stmt)
	stop := PRIME_STOP
	for sqlite3.next(&stmt) {
		handle := sqlite3.text(stmt, 0)
		names := name_terms(handle, sqlite3.text(stmt, 4))
		outer: for t in query_terms(sqlite3.text(stmt, 2)) {
			if len(t) < LEARN_TERM_MIN || names[t] || t == "prime" || t == "pack" {
				continue
			}
			for s in stop {
				if t == s {
					continue outer
				}
			}
			key := strings.concatenate({sqlite3.text(stmt, 1), "|", handle, "|", t})
			c, has := counts[key]
			if !has {
				c = new(Count)
				c.handle = strings.clone(handle)
				c.file = strings.clone(sqlite3.text(stmt, 1))
				c.term = strings.clone(t)
				c.sessions = make(map[string]bool)
				counts[strings.clone(key)] = c
				append(&order, key)
			}
			c.sessions[strings.clone(sqlite3.text(stmt, 3))] = true
		}
	}
	found := make([dynamic]Alias_Candidate)
	for key in order {
		c := counts[key]
		if len(c.sessions) >= LEARN_SESSIONS {
			append(&found, Alias_Candidate{handle = c.handle, file = c.file, term = c.term, sessions = len(c.sessions)})
		}
	}
	slice.sort_by(found[:], proc(a, b: Alias_Candidate) -> bool {
		if a.sessions != b.sessions {
			return a.sessions > b.sessions
		}
		return a.handle < b.handle
	})
	return found[:]
}

Dead_Terms :: struct {
	aliases, synonyms: []string,
	too_few:           bool,
}

// dead_aliases is every alias of a core bullet, and every synonym term,
// that no query in LEARN_DEAD_DAYS contained, once the log is big enough
// to mean anything.
dead_aliases :: proc(db: sqlite3.Db) -> (d: Dead_Terms) {
	if scalar_int(db, "select count(*) from queries") < LEARN_MIN_QUERIES {
		d.too_few = true
		return
	}
	asked := make(map[string]bool)
	for q in column_texts(db, "select q from queries where ts >= date('now', ?)", strings.concatenate({"-", int_str(LEARN_DEAD_DAYS), " day"})) {
		for t in query_terms(q) {
			asked[strings.clone(t)] = true
		}
	}
	aliases := make([dynamic]string)
	for row in column_texts(db, "select handle || char(9) || aliases from bullets where file in " + CSV_CORE + " and aliases <> ''") {
		handle, _, als := strings.partition(row, "\t")
		for a in strings.split(als, ",") {
			alive := false
			for t in query_terms(a) {
				if asked[t] {
					alive = true
				}
			}
			if !alive && strings.trim_space(a) != "" {
				append(&aliases, strings.concatenate({strings.trim_space(a), " (", handle, ")"}))
			}
		}
	}
	synonyms := make([dynamic]string)
	for term in column_texts(db, "select distinct term from synonyms") {
		if !asked[term] {
			append(&synonyms, strings.clone(term))
		}
	}
	d.aliases = aliases[:]
	d.synonyms = synonyms[:]
	return
}

// apply_aliases writes each candidate term into its bullet's alias list,
// in the markdown, and returns how many lines changed.
apply_aliases :: proc(cli: ^Cli, candidates: []Alias_Candidate) -> int {
	changed := 0
	by_file := make(map[string][dynamic]Alias_Candidate)
	for c in candidates {
		list, has := by_file[c.file]
		if !has {
			list = make([dynamic]Alias_Candidate)
		}
		append(&list, c)
		by_file[c.file] = list
	}
	for file, list in by_file {
		text, ok := read_text(path.join(cli.vault, file))
		if !ok {
			continue
		}
		lines := strings.split_lines(text)
		for &l in lines {
			b, is := parse_bullet(l, "")
			if !is {
				continue
			}
			for c in list {
				if c.handle != b.handle {
					continue
				}
				if name_terms(b.handle, b.aliases)[c.term] {
					continue
				}
				head := strings.concatenate({"- **", b.handle, "**"})
				if b.aliases != "" {
					old := strings.concatenate({"(aliases: ", b.aliases, ")"})
					l, _ = strings.replace(l, old, strings.concatenate({"(aliases: ", b.aliases, ", ", c.term, ")"}), 1)
				} else {
					l, _ = strings.replace(l, head, strings.concatenate({head, " (aliases: ", c.term, ")"}), 1)
				}
				b, _ = parse_bullet(l, "")
				changed += 1
			}
		}
		path.write(path.join(cli.vault, file), strings.join(lines, "\n"))
	}
	return changed
}

// prune_synonyms drops every row of synonyms.tsv whose term is dead.
prune_synonyms :: proc(cli: ^Cli, dead: []string) -> int {
	file := path.join(cli.vault, SYNONYMS_FILE)
	text, ok := read_text(file)
	if !ok {
		return 0
	}
	gone := make(map[string]bool)
	for d in dead {
		gone[d] = true
	}
	kept := make([dynamic]string)
	dropped := 0
	for l, i in strings.split_lines(text) {
		term, _, _ := strings.partition(l, "\t")
		if i > 0 && gone[term] {
			dropped += 1
			continue
		}
		append(&kept, l)
	}
	path.write(file, strings.join(kept[:], "\n"))
	return dropped
}

// ---- the ranking experiment -----------------------------------------------

// rank_weighted is whether find boosts bullets by how often they were
// used: BRAIN_RANK=weighted, off by default until the proof says
// otherwise, and --plain turns it off for one call.
rank_weighted :: proc(cli: ^Cli) -> bool {
	return getenv(cli, "BRAIN_RANK") == "weighted"
}

// weigh moves each hit's score by a bounded amount for the serves that
// were used, never for serves alone, and not at all for a bullet that
// failed verify. FTS5's bm25() is negative and a better match is lower
// (sqlite.org/fts5.html, "The bm25() function"), so a boost subtracts.
weigh :: proc(db: sqlite3.Db, hits: []Hit) -> []Hit {
	for &h in hits {
		if scalar_int(db, "select count(*) from claims where handle=? and verdict='failed'", h.handle) > 0 {
			continue
		}
		used := scalar_int(db, "select count(*) from serve_outcome where handle=? and used=1", h.handle)
		if used == 0 {
			continue
		}
		h.score -= min(WEIGHT_CAP, WEIGHT_SCALE * math.ln(1 + f64(used)))
	}
	slice.sort_by(hits, proc(a, b: Hit) -> bool {return a.score < b.score})
	return hits
}

package brain

import "core:fmt"
import "core:slice"
import "core:strings"

import "jm:sqlite3"

CSV_CORE :: "('AI/MEMORY.md','AI/LEARNINGS.md','AI/TUNINGS.md')"

// Section is one of doctor's checks: a key for --json, a title for a person,
// and the query that lists what it found.
Section :: struct {
	key, title, sql: string,
	arg:             i64,
	has_arg:         bool,
}

doctor_sections :: proc(nq: int) -> []Section {
	s := make([dynamic]Section)
	append(&s, Section{key = "stale", title = fmt.aprintf("stale: not verified in %dd", STALE_DAYS), sql = fmt.aprintf(`select date, file, handle from bullets
			 where date <> '' and date < date('now','-%d day')
			 order by date limit 40`, STALE_DAYS)})
	append(&s, Section{key = "thin_aliases", title = "thin aliases (<2) — a future searcher's vocabulary is missing", sql = `select file, handle, aliases from bullets
		 where file in ` + CSV_CORE + ` and
		   (aliases='' or (length(aliases)-length(replace(aliases,',',''))) < 1)
		 order by file, handle`})
	append(&s, Section{key = "oversized", title = fmt.aprintf("oversized bullets (fact > %d chars)", MAXLEN), sql = "select file, handle, len from bullets where len > ? order by len desc", arg = i64(MAXLEN), has_arg = true})
	append(&s, Section{key = "duplicate_handles", title = "duplicate handles", sql = `select handle, count(*) n, group_concat(file,' + ') files
		 from bullets group by lower(handle) having n > 1`})
	append(&s, Section{key = "dead_links", title = "dead wikilinks", sql = `select l.file, l.line, l.target from links l
		 where not exists (select 1 from docs d where d.file like '%' || l.target || '.md')
		   and not exists (select 1 from bullets b where lower(b.handle)=lower(replace(l.target,'-',' ')))
		 order by l.file limit 30`})
	append(&s, Section{key = "orphan_artifacts", title = "orphan artifacts (no bullet or document points at them)", sql = `select d.file from docs d
		 where d.file like 'AI/artifacts/%'
		   and not exists (select 1 from bullets b where b.raw like '%' || replace(d.file,'AI/','') || '%')
		   and not exists (select 1 from lines l where l.file <> d.file and l.text like '%' || replace(d.file,'AI/','') || '%')
		 order by d.file`})
	// Frequency is the promote signal: a bullet that keeps answering queries is
	// being paid for in tokens on every hit, and a gate, shim or project file
	// would answer it for free.
	append(&s, Section{key = "promote", title = fmt.aprintf("promote candidates: returned by %d+ queries — a gate or project file would answer for free", PROMOTE_QUERIES), sql = `select h.file, h.handle, count(distinct h.query_id) as queries,
		   count(distinct nullif(q.session,'')) as sessions,
		   substr(group_concat(distinct q.q), 1, 40) as asked_as
		 from query_hits h join queries q on q.id = h.query_id
		 where h.rank <= 3
		 group by h.file, h.handle having queries >= ?
		 order by queries desc, sessions desc limit 20`, arg = i64(PROMOTE_QUERIES), has_arg = true})
	if nq >= 50 {
		append(&s, Section{key = "never_returned", title = fmt.aprintf("never returned by any query (prune candidates, from %d queries)", nq), sql = `select b.file, b.handle, b.date from bullets b
			 where not exists (select 1 from query_hits h where h.handle = b.handle)
			 order by b.date limit 30`})
	}
	append(&s, Section{key = "zero_hit", title = "zero-hit queries", sql = "select q, count(*) n from queries where hits=0 group by q order by n desc limit 15"})
	append(&s, Section{key = "failed_claims", title = "claims that failed the last brain verify: a path, file, subcommand or commit the bullet names is not there", sql = "select file, handle, kind, text, why, substr(checked,1,10) as checked from claims where verdict='failed' order by file, line"})
	return s[:]
}

// Older_Note is a dated note holding lines that name what a newer bullet
// names: a plan or handoff written before the bullet settled the matter,
// which an agent may quote over the bullet (tools/proof saw a plan's line
// beat the bullet above it). A note is matched by a bullet's handle or
// alias as a phrase of two or more words and ten or more characters, so a
// common word does not flag every note in the vault, and a line that cites
// the bullet by name is already deferring to it and is not counted. Lines
// are grouped by file: the file is what a person marks or retires.
Older_Note :: struct {
	file, date: string,
	lines:      int,
	first:      i64, // the first flagged line
	handles:    [dynamic]string,
}

older_notes :: proc(db: sqlite3.Db) -> []Older_Note {
	order := make([dynamic]string)
	by := make(map[string]^Older_Note)
	seen := make(map[string]bool)
	stmt, err := sqlite3.query(db, "select handle, aliases, date from bullets where file in " + CSV_CORE + " and date <> ''")
	if err != nil {
		return nil
	}
	defer sqlite3.finish(&stmt)
	for sqlite3.next(&stmt) {
		handle := strings.clone(sqlite3.text(stmt, 0))
		aliases := strings.clone(sqlite3.text(stmt, 1))
		date := strings.clone(sqlite3.text(stmt, 2))
		cite := strings.concatenate({"**", handle, "**"})
		terms := make([dynamic]string)
		append(&terms, handle)
		for a in strings.split(aliases, ",") {
			append(&terms, a)
		}
		for t in terms {
			toks := query_terms(t)
			phrase := strings.join(toks, " ")
			if len(toks) < 2 || len(phrase) < 10 {
				continue
			}
			rows, rerr := sqlite3.query(
				db,
				`select l.file, l.line, d.date, l.text
				 from lines_fts f join lines l on l.id = f.rowid join docs d on d.file = l.file
				 where lines_fts match ? and d.date <> '' and d.date < ?
				   and l.file not in ` + CSV_CORE + `
				 order by l.file, l.line limit 40`,
				quoted(phrase),
				date,
			)
			if rerr != nil {
				continue
			}
			for sqlite3.next(&rows) {
				file := sqlite3.text(rows, 0)
				line := sqlite3.integer(rows, 1)
				if strings.contains(sqlite3.text(rows, 3), cite) {
					continue
				}
				key := strings.concatenate({file, ":", int_str(line)})
				if seen[key] {
					continue
				}
				seen[key] = true
				n, has := by[file]
				if !has {
					n = new(Older_Note)
					n.file = strings.clone(file)
					n.date = strings.clone(sqlite3.text(rows, 2))
					n.first = line
					by[n.file] = n
					append(&order, n.file)
				}
				n.lines += 1
				if line < n.first {
					n.first = line
				}
				known := false
				for h in n.handles {
					if h == handle {
						known = true
					}
				}
				if !known {
					append(&n.handles, handle)
				}
			}
			sqlite3.finish(&rows)
		}
	}
	out := make([dynamic]Older_Note)
	for f in order {
		append(&out, by[f]^)
	}
	// The heaviest file first: the one an agent is likeliest to quote.
	slice.sort_by(out[:], proc(a, b: Older_Note) -> bool {return a.lines > b.lines})
	return out[:]
}

cmd_doctor :: proc(cli: ^Cli, args: []string) -> int {
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	db, oerr := open_db(cli.db)
	if oerr != "" {
		return fail(cli, oerr)
	}
	defer sqlite3.close(&db)
	nq := scalar_int(db, "select count(*) from queries")
	sections := doctor_sections(nq)
	older := older_notes(db)
	suspect := suspects(cli, db)
	contra := contradictions(db)
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field_int(&w, "queries_logged", i64(nq))
		for s in sections {
			jw_key(&w, s.key)
			if s.has_arg {
				jw_rows(&w, db, s.sql, s.arg)
			} else {
				jw_rows(&w, db, s.sql)
			}
		}
		jw_key(&w, "older_notes")
		jw_arr(&w)
		for o in older {
			jw_obj(&w)
			jw_field(&w, "file", o.file)
			jw_field(&w, "date", o.date)
			jw_field_int(&w, "lines", i64(o.lines))
			jw_field_int(&w, "first_line", o.first)
			jw_key(&w, "handles")
			jw_arr(&w)
			for h in o.handles {
				jw_str(&w, h)
			}
			jw_end_arr(&w)
			jw_end_obj(&w)
		}
		jw_end_arr(&w)
		jw_key(&w, "suspect")
		jw_arr(&w)
		for x in suspect {
			jw_obj(&w)
			jw_field(&w, "handle", x.handle)
			jw_field(&w, "file", x.file)
			jw_field(&w, "session", x.session)
			jw_field(&w, "served", x.served)
			jw_field(&w, "correction", x.user)
			jw_end_obj(&w)
		}
		jw_end_arr(&w)
		jw_key(&w, "contradictions")
		jw_arr(&w)
		for c in contra {
			jw_obj(&w)
			jw_field(&w, "name", c.name)
			jw_field(&w, "a", c.a)
			jw_field(&w, "a_file", c.a_file)
			jw_field(&w, "b", c.b)
			jw_field(&w, "b_file", c.b_file)
			jw_end_obj(&w)
		}
		jw_end_arr(&w)
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	for s, i in sections {
		outf(cli, "%s== %s ==\n", i == 0 ? "" : "\n", s.title)
		if s.has_arg {
			print_box(cli, db, s.sql, s.arg)
		} else {
			print_box(cli, db, s.sql)
		}
		if s.key == "promote" && nq < 50 {
			outf(cli, "\n== never returned by any query (prune candidates, from %d queries) ==\n", nq)
			out(cli, "   too few queries logged to mean anything yet — this needs months of real use\n")
		}
	}
	out(cli, "\n== older notes that name what a newer bullet names: an agent may quote them over the bullet; mark or retire them ==\n")
	for o in older {
		outf(cli, "%s (%s): %d line(s) from :%d name **%s**\n", o.file, o.date, o.lines, o.first, strings.join(o.handles[:], "**, **"))
	}
	out(cli, "\n== suspect: served within ten turns before the person corrected the agent; the serve may have misled it ==\n")
	for x in suspect {
		outf(cli, "%s **%s** served %s, then: %s\n", x.file, x.handle, x.served, x.user)
	}
	out(cli, "\n== contradictions: two bullets answer to the same name and share no content word; one is wrong or they want merging ==\n")
	for c in contra {
		outf(cli, "%s: **%s** (%s) and **%s** (%s)\n", c.name, c.a, c.a_file, c.b, c.b_file)
	}
	return 0
}

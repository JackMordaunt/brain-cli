package brain

import "core:fmt"

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
	return s[:]
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
	return 0
}

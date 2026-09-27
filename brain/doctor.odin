package brain

import "core:fmt"

import "jm:sqlite3"

CSV_CORE :: "('AI/MEMORY.md','AI/LEARNINGS.md','AI/TUNINGS.md')"

cmd_doctor :: proc(cli: ^Cli, args: []string) -> int {
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	db, oerr := open_db(cli.db)
	if oerr != "" {
		return fail(cli, oerr)
	}
	defer sqlite3.close(&db)

	outf(cli, "== stale: not verified in %dd ==\n", STALE_DAYS)
	print_box(
		cli,
		db,
		fmt.tprintf(
			`select date, file, handle from bullets
			 where date <> '' and date < date('now','-%d day')
			 order by date limit 40`,
			STALE_DAYS,
		),
	)

	out(cli, "\n== thin aliases (<2) — a future searcher's vocabulary is missing ==\n")
	print_box(
		cli,
		db,
		`select file, handle, aliases from bullets
		 where file in ` + CSV_CORE + ` and
		   (aliases='' or (length(aliases)-length(replace(aliases,',',''))) < 1)
		 order by file, handle`,
	)

	outf(cli, "\n== oversized bullets (fact > %d chars) ==\n", MAXLEN)
	print_box(cli, db, "select file, handle, len from bullets where len > ? order by len desc", i64(MAXLEN))

	out(cli, "\n== duplicate handles ==\n")
	print_box(
		cli,
		db,
		`select handle, count(*) n, group_concat(file,' + ') files
		 from bullets group by lower(handle) having n > 1`,
	)

	out(cli, "\n== dead wikilinks ==\n")
	print_box(
		cli,
		db,
		`select l.file, l.line, l.target from links l
		 where not exists (select 1 from docs d where d.file like '%' || l.target || '.md')
		   and not exists (select 1 from bullets b where lower(b.handle)=lower(replace(l.target,'-',' ')))
		 order by l.file limit 30`,
	)

	out(cli, "\n== orphan artifacts (no bullet or document points at them) ==\n")
	print_box(
		cli,
		db,
		`select d.file from docs d
		 where d.file like 'AI/artifacts/%'
		   and not exists (select 1 from bullets b where b.raw like '%' || replace(d.file,'AI/','') || '%')
		   and not exists (select 1 from lines l where l.file <> d.file and l.text like '%' || replace(d.file,'AI/','') || '%')
		 order by d.file`,
	)

	// Frequency is the promote signal: a bullet that keeps answering queries is
	// being paid for in tokens on every hit, and a gate, shim or project file
	// would answer it for free.
	outf(
		cli,
		"\n== promote candidates: returned by %d+ queries — a gate or project file would answer for free ==\n",
		PROMOTE_QUERIES,
	)
	print_box(
		cli,
		db,
		`select h.file, h.handle, count(distinct h.query_id) as queries,
		   count(distinct nullif(q.session,'')) as sessions,
		   substr(group_concat(distinct q.q), 1, 40) as asked_as
		 from query_hits h join queries q on q.id = h.query_id
		 where h.rank <= 3
		 group by h.file, h.handle having queries >= ?
		 order by queries desc, sessions desc limit 20`,
		i64(PROMOTE_QUERIES),
	)

	nq := scalar_int(db, "select count(*) from queries")
	outf(cli, "\n== never returned by any query (prune candidates, from %d queries) ==\n", nq)
	if nq < 50 {
		out(cli, "   too few queries logged to mean anything yet — this needs months of real use\n")
	} else {
		print_box(
			cli,
			db,
			`select b.file, b.handle, b.date from bullets b
			 where not exists (select 1 from query_hits h where h.handle = b.handle)
			 order by b.date limit 30`,
		)
	}

	out(cli, "\n== zero-hit queries ==\n")
	print_box(cli, db, "select q, count(*) n from queries where hits=0 group by q order by n desc limit 15")
	return 0
}

package brain

import "core:strings"

import "jm:sqlite3"

// A miss is only a backlog item while it still misses. Most are a session
// asking about the thing it is in the middle of writing down — "agenda" missed
// at 17:42 and its bullet was committed at 18:15 — so every zero-hit query is
// re-run against the current index and the ones that now answer are set aside.
cmd_log :: proc(cli: ^Cli, args: []string) -> int {
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	db, oerr := open_db(cli.db)
	if oerr != "" {
		return fail(cli, oerr)
	}
	defer sqlite3.close(&db)

	answered := make([dynamic]string)
	for q in column_texts(db, "select distinct q from queries where hits=0") {
		if q == "" {
			continue
		}
		m, ok := build_match(db, q)
		if !ok {
			continue
		}
		if len(query_fts(db, m.and)) > 0 ||
		   len(query_fts(db, m.or)) > 0 ||
		   len(query_lines(db, m.prose_and)) > 0 ||
		   len(query_lines(db, m.prose_or)) > 0 {
			append(&answered, q)
		}
	}

	out(cli, "== zero-hit queries that still miss (the synonym backlog) ==\n")
	args_v := make([]sqlite3.Value, len(answered))
	for q, i in answered {
		args_v[i] = q
	}
	exclude := len(answered) > 0 ? strings.concatenate({" and q not in ", in_list(len(answered))}) : ""
	print_box(
		cli,
		db,
		strings.concatenate(
			{
				"select q as query, count(*) as misses, max(ts) as last from queries where hits=0",
				exclude,
				" group by q order by misses desc, last desc limit 30",
			},
		),
		..args_v,
	)
	if len(answered) > 0 {
		outf(cli, "(%d missed then answered by a later edit: %s)\n", len(answered), strings.join(answered[:], ","))
	}
	out(cli, "\n== recent queries ==\n")
	print_box(cli, db, "select ts, q as query, hits, caller from queries order by ts desc limit 15")
	out(cli, "\n== who asks: queries, sessions and bytes returned per caller ==\n")
	print_box(
		cli,
		db,
		`select coalesce(nullif(caller,''),'?') as caller, count(*) as queries,
		   count(distinct nullif(session,'')) as sessions, sum(hits=0) as misses,
		   sum(coalesce(bytes,0)) as bytes
		 from queries group by 1 order by 2 desc`,
	)
	return 0
}

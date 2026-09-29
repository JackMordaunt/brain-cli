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

	args_v := make([]sqlite3.Value, len(answered))
	for q, i in answered {
		args_v[i] = q
	}
	exclude := len(answered) > 0 ? strings.concatenate({" and q not in ", in_list(len(answered))}) : ""
	backlog := strings.concatenate(
		{
			"select q as query, count(*) as misses, max(ts) as last from queries where hits=0",
			exclude,
			" group by q order by misses desc, last desc limit 30",
		},
	)
	recent :: "select ts, q as query, hits, caller from queries order by ts desc limit 15"
	callers :: `select coalesce(nullif(caller,''),'?') as caller, count(*) as queries,
		   count(distinct nullif(session,'')) as sessions, sum(hits=0) as misses,
		   sum(coalesce(bytes,0)) as bytes
		 from queries group by 1 order by 2 desc`
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_key(&w, "backlog")
		jw_rows(&w, db, backlog, ..args_v)
		jw_key(&w, "answered")
		jw_arr(&w)
		for q in answered {
			jw_str(&w, q)
		}
		jw_end_arr(&w)
		jw_key(&w, "recent")
		jw_rows(&w, db, recent)
		jw_key(&w, "callers")
		jw_rows(&w, db, callers)
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	out(cli, "== what still misses (the synonym backlog) ==\n")
	print_box(cli, db, backlog, ..args_v)
	if len(answered) > 0 {
		outf(cli, "(%d missed then answered by a later edit: %s)\n", len(answered), strings.join(answered[:], ","))
	}
	out(cli, "\n== recent lookups ==\n")
	print_box(cli, db, recent)
	out(cli, "\n== who asks: lookups, sessions and bytes returned per caller ==\n")
	print_box(cli, db, callers)
	return 0
}

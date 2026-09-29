package brain

import "core:os"
import "core:strings"

import "jm:path"
import "jm:sqlite3"

// The ledger is what the vault's lookups cost, and what they saved, read
// from the find log. The baseline is the alternative an agent has without
// an index: reading the three core files whole, so every lookup that
// answered is credited with the core files' size less what it printed.
// Tokens are bytes over four, the same estimate the README uses.

cmd_ledger :: proc(cli: ^Cli, args: []string) -> int {
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	db, oerr := open_db(cli.db)
	if oerr != "" {
		return fail(cli, oerr)
	}
	defer sqlite3.close(&db)
	baseline := core_bytes(cli)
	days := 14
	if len(args) >= 2 && args[0] == "--days" {
		if n, ok := parse_positive(args[1]); ok {
			days = n
		}
	}
	// A lookup that answered saved the baseline less its own bytes; a miss
	// cost only itself.
	cols :: `count(*) as lookups, sum(hits>0) as answered,
	   sum(coalesce(bytes,0))/4 as tokens_returned,
	   sum(case when hits>0 then ? - coalesce(bytes,0) else -coalesce(bytes,0) end)/4 as tokens_saved`
	by_caller := "select coalesce(nullif(caller,''),'?') as caller, count(distinct nullif(session,'')) as sessions, " + cols + " from queries group by 1 order by lookups desc"
	by_session := "select session, coalesce(nullif(caller,''),'?') as caller, min(ts) as first, max(ts) as last, " + cols + " from queries where session <> '' group by session order by last desc limit 20"
	by_day := "select date(ts) as day, " + cols + " from queries where ts >= date('now', ? ) group by 1 order by 1 desc"
	since_arg := strings.concatenate({"-", int_str(i64(days)), " day"})
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field_int(&w, "baseline_bytes", i64(baseline))
		jw_field_int(&w, "baseline_tokens", i64(baseline / 4))
		jw_key(&w, "callers")
		jw_rows(&w, db, by_caller, i64(baseline))
		jw_key(&w, "sessions")
		jw_rows(&w, db, by_session, i64(baseline))
		jw_key(&w, "days")
		jw_rows(&w, db, by_day, i64(baseline), since_arg)
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	outf(cli, "Tokens are bytes over four. Saved is against reading the three core files instead: %d KB, ~%d tokens per lookup.\n", baseline / 1000, baseline / 4)
	out(cli, "\n== by caller ==\n")
	print_box(cli, db, by_caller, i64(baseline))
	out(cli, "\n== recent sessions ==\n")
	print_box(cli, db, by_session, i64(baseline))
	outf(cli, "\n== last %d days ==\n", days)
	print_box(cli, db, by_day, i64(baseline), since_arg)
	return 0
}

// core_bytes is the size of the three core files together.
core_bytes :: proc(cli: ^Cli) -> int {
	total := 0
	core := CORE
	for f in core {
		if info, err := os.stat(path.join(cli.vault, f), context.temp_allocator); err == nil {
			total += int(info.size)
		}
	}
	return total
}

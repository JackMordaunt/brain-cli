package brain

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "jm:path"
import "jm:sqlite3"

// The index is disposable and rebuilt on demand, so no agent needs to know
// that 'brain reindex' exists: a missing or stale database resyncs itself.
ensure_db :: proc(cli: ^Cli) -> string {
	if err := need_vault(cli); err != "" {
		return err
	}
	if !nonempty_file(cli.db) {
		return sync(cli, quiet = true)
	}
	// An index built by an older CLI rebuilds itself; the logs carry over.
	if db, err := open_db(cli.db); err == "" {
		v := scalar_int(db, "pragma user_version")
		sqlite3.close(&db)
		if v != SCHEMA {
			return sync(cli, quiet = true)
		}
	}
	if newer_md_than(cli, cli.db) {
		return sync(cli, quiet = true)
	}
	// A changed review setting changes what the index holds.
	if db, err := open_db(cli.db); err == "" {
		was := scalar_text(db, "select value from meta where key='review'")
		sqlite3.close(&db)
		if was != review_name(review_mode(cli)) {
			return sync(cli, quiet = true)
		}
	}
	return ""
}

// index_files is what the index is built from: every markdown file but the
// inbox and the dropped list, and the inbox too when review comes after.
index_files :: proc(cli: ^Cli) -> ([]string, os.Error) {
	files, err := list_md(cli.vault)
	if err != nil || review_mode(cli) == .Before || !os.is_file(path.join(cli.vault, INBOX_FILE)) {
		return files, err
	}
	all := make([dynamic]string)
	append(&all, ..files)
	append(&all, INBOX_FILE)
	slice.sort(all[:])
	return all[:], nil
}

// open_db opens an index database; the message on failure names the file.
open_db :: proc(p: string) -> (db: sqlite3.Db, err: string) {
	d, e := sqlite3.open(p)
	if e != nil {
		return {}, fmt.aprintf("cannot open %s: %s", p, sql_err(e))
	}
	return d, ""
}

sql_err :: proc(e: sqlite3.Error) -> string {
	if f, ok := e.(sqlite3.Fault); ok {
		return f.text
	}
	return "ok"
}

nonempty_file :: proc(p: string) -> bool {
	info, err := os.stat(p, context.temp_allocator)
	return err == nil && info.size > 0
}

// newer_md_than reports whether any markdown under the vault changed after
// the index was written. A file stamped the same instant as the index counts
// as newer: file times are coarse, so an edit made just after a write can
// carry the write's own time, as log_sets_an_answered_miss_aside shows. A
// spare rebuild is cheaper than a missed edit.
newer_md_than :: proc(cli: ^Cli, db: string) -> bool {
	vault := cli.vault
	db_time, err := os.modification_time_by_path(db)
	if err != nil {
		return true
	}
	files, lerr := index_files(cli)
	if lerr != nil {
		return false
	}
	for f in files {
		t, terr := os.modification_time_by_path(path.join(vault, f))
		if terr == nil && time.diff(db_time, t) >= 0 {
			return true
		}
	}
	// The vocabulary is indexed too, so an edited synonyms file re-indexes.
	if t, terr := os.modification_time_by_path(path.join(vault, SYNONYMS_FILE)); terr == nil && time.diff(db_time, t) >= 0 {
		return true
	}
	return false
}

cmd_reindex :: proc(cli: ^Cli, args: []string) -> int {
	if err := sync(cli, quiet = cli.json); err != "" {
		return fail(cli, err)
	}
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field_int(&w, "bullets", i64(cli.indexed.bullets))
		jw_field_int(&w, "links", i64(cli.indexed.links))
		jw_field_int(&w, "files", i64(cli.indexed.files))
		jw_end_obj(&w)
		jw_flush(cli, &w)
	}
	return 0
}

// Both FTS tables stem with porter over unicode61, so `install` finds a
// bullet that says "installs" and `rebuild` one that says "rebuilds"; FTS5
// stems the query the same way. Before 2026-10-02 the tokenizer was plain
// unicode61 and the proof's conflict experiment watched `brainfold install
// linux` miss the bullet that said "installs" and land on a stale note.

// The vault's query vocabulary, relative to the vault root.
SYNONYMS_FILE :: "AI/synonyms.tsv"

INDEX_SCHEMA :: `
create table bullets(
  id integer primary key, file text, line integer, section text,
  handle text, aliases text, fact text, source text, date text,
  raw text, len integer);
create table links(file text, line integer, target text);
create table docs(file text primary key, title text, date text);
create virtual table bullets_fts using fts5(handle, aliases, fact, tokenize='porter unicode61');
create table lines(id integer primary key, file text, line integer, text text);
create virtual table lines_fts using fts5(text, tokenize='porter unicode61');
create table synonyms(term text, expansion text);
create table queries(id integer primary key, ts text, q text, hits integer,
  caller text, session text, bytes integer);
create table query_hits(query_id integer, file text, handle text, rank integer);
create table claims(file text, line integer, handle text, kind text, text text,
  verdict text, why text, checked text);
create table serve_outcome(query_id integer, handle text, used integer, strong integer);
create table meta(key text primary key, value text);
`

// sync rebuilds the index from the markdown into a fresh file and swaps it
// in. The query log is carried across: it is evidence, not derived data.
sync :: proc(cli: ^Cli, quiet: bool) -> string {
	if err := need_vault(cli); err != "" {
		return err
	}
	if err := path.mkdirs(cli.state); err != nil {
		return fmt.aprintf("cannot create %s: %v", cli.state, err)
	}
	files, lerr := index_files(cli)
	if lerr != nil {
		return fmt.aprintf("cannot read %s: %v", cli.vault, lerr)
	}
	if len(files) == 0 {
		return fmt.aprintf("no markdown found under %s", cli.vault)
	}

	tmp := strings.concatenate({cli.db, ".new"})
	os.remove(tmp)
	db, oerr := open_db(tmp)
	if oerr != "" {
		return oerr
	}
	if err := build_index(cli, db, files); err != "" {
		sqlite3.close(&db)
		os.remove(tmp)
		return fmt.aprintf("index build failed: %s", err)
	}
	if nonempty_file(cli.db) {
		carry_log(db, cli.db)
	}
	sqlite3.exec(db, fmt.tprintf("pragma user_version=%d", SCHEMA))
	sqlite3.exec_args(db, "insert into meta(key,value) values('review',?)", review_name(review_mode(cli)))
	bullets := scalar_int(db, "select count(*) from bullets")
	links := scalar_int(db, "select count(*) from links")
	cli.indexed = {bullets, links, len(files)}
	sqlite3.close(&db)

	if err := replace_file(tmp, cli.db); err != "" {
		return err
	}
	os.remove(strings.concatenate({tmp, "-wal"}))
	os.remove(strings.concatenate({tmp, "-shm"}))
	if !quiet {
		outf(cli, "indexed %d bullets, %d links, %d files\n", bullets, links, len(files))
	}
	return ""
}

// build_index fills a fresh database from the vault's files and the tool's
// synonyms. Every value is bound, never spliced into SQL.
build_index :: proc(cli: ^Cli, db: sqlite3.Db, files: []string) -> string {
	if e := sqlite3.exec(db, INDEX_SCHEMA); e != nil {
		return sql_err(e)
	}
	if e := sqlite3.exec(db, "begin"); e != nil {
		return sql_err(e)
	}
	ins_bullet, e1 := sqlite3.prepare(
		db,
		"insert into bullets(file,line,section,handle,aliases,fact,source,date,raw,len) values(?,?,?,?,?,?,?,?,?,?)",
	)
	ins_link, e2 := sqlite3.prepare(db, "insert into links(file,line,target) values(?,?,?)")
	ins_line, e3 := sqlite3.prepare(db, "insert into lines(file,line,text) values(?,?,?)")
	ins_doc, e4 := sqlite3.prepare(db, "insert into docs(file,title,date) values(?,?,?)")
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil {
		return "cannot prepare the index statements"
	}
	defer sqlite3.finish(&ins_bullet)
	defer sqlite3.finish(&ins_link)
	defer sqlite3.finish(&ins_line)
	defer sqlite3.finish(&ins_doc)

	for f in files {
		s, serr := scan_file(cli.vault, f)
		if serr != nil {
			return fmt.aprintf("cannot read %s: %v", f, serr)
		}
		for b in s.bullets {
			if f == INBOX_FILE && is_tend(b) {
				continue // a hygiene item is an action for a person, not an answer
			}
			if e := step(&ins_bullet, b.file, i64(b.line), b.section, b.handle, b.aliases, b.fact, b.source, b.date, b.raw, i64(b.len)); e != "" {
				return e
			}
		}
		for l in s.links {
			if e := step(&ins_link, l.file, i64(l.line), l.target); e != "" {
				return e
			}
		}
		for l in s.lines {
			if e := step(&ins_line, l.file, i64(l.line), l.text); e != "" {
				return e
			}
		}
		if e := step(&ins_doc, s.file, s.title, s.date); e != "" {
			return e
		}
	}
	// Synonyms are the vault's vocabulary, kept beside the notes they
	// describe: a tab-separated `term expansion` file with a header row,
	// reloaded whole on every sync. A vault without one has no expansion.
	if tsv, err := os.read_entire_file_from_path(path.join(cli.vault, SYNONYMS_FILE), context.allocator); err == nil {
		ins_syn, e5 := sqlite3.prepare(db, "insert into synonyms(term,expansion) values(?,?)")
		if e5 != nil {
			return sql_err(e5)
		}
		defer sqlite3.finish(&ins_syn)
		rest := string(tsv)
		n := 0
		for line in strings.split_lines_iterator(&rest) {
			n += 1
			if n == 1 {
				continue // the header row
			}
			cols := strings.split(strings.trim_suffix(line, "\r"), "\t")
			if len(cols) < 2 {
				continue
			}
			if e := step(&ins_syn, cols[0], cols[1]); e != "" {
				return e
			}
		}
	}
	// The build stamp names this index: a pack cached against it is served
	// until the next sync, whatever the files' clocks say.
	if e := sqlite3.exec(db, `insert into bullets_fts(rowid,handle,aliases,fact) select id,handle,aliases,fact from bullets;
		insert into lines_fts(rowid,text) select id,text from lines;
		insert into meta(key,value) values('built', strftime('%Y-%m-%dT%H:%M:%fZ','now') || ' ' || (select count(*) from bullets) || ' ' || (select count(*) from lines));
		commit;`); e != nil {
		return sql_err(e)
	}
	return ""
}

// step binds args, runs a prepared statement once, and resets it.
step :: proc(stmt: ^sqlite3.Stmt, args: ..sqlite3.Value) -> string {
	if e := sqlite3.bind(stmt, ..args); e != nil {
		return sql_err(e)
	}
	for sqlite3.next(stmt) {}
	if stmt.err != nil {
		return sql_err(stmt.err)
	}
	if e := sqlite3.reset(stmt); e != nil {
		return sql_err(e)
	}
	return ""
}

// carry_log copies the query log from the previous index. A log written
// before the caller or bytes columns existed carries over with them empty. Bullet
// row ids are reassigned on every sync, so hits are recorded by handle and
// copy across unchanged. Failures are ignored: an old file that cannot be
// read costs the log, not the index.
carry_log :: proc(db: sqlite3.Db, old_path: string) {
	if e := sqlite3.exec_args(db, "attach ? as old", old_path); e != nil {
		return
	}
	defer sqlite3.exec(db, "detach old")
	if sqlite3.exec(db, "select bytes from old.queries limit 0") == nil {
		sqlite3.exec(db, `insert into queries(id,ts,q,hits,caller,session,bytes)
			select rowid,ts,q,hits,caller,session,bytes from old.queries`)
	} else if sqlite3.exec(db, "select caller, session from old.queries limit 0") == nil {
		sqlite3.exec(db, `insert into queries(id,ts,q,hits,caller,session)
			select rowid,ts,q,hits,caller,session from old.queries`)
	} else {
		sqlite3.exec(db, `insert into queries(id,ts,q,hits,caller,session)
			select rowid,ts,q,hits,'','' from old.queries`)
	}
	sqlite3.exec(db, "insert into query_hits select * from old.query_hits")
	// Verdicts are evidence of a run, carried until the next one.
	sqlite3.exec(db, "insert into claims select * from old.claims")
	sqlite3.exec(db, "insert into serve_outcome select * from old.serve_outcome")
}

// replace_file moves src over dst, which may exist.
replace_file :: proc(src, dst: string) -> string {
	if os.exists(dst) {
		if err := os.remove(dst); err != nil {
			return fmt.aprintf("cannot replace %s: %v", dst, err)
		}
	}
	if err := os.rename(src, dst); err != nil {
		return fmt.aprintf("cannot move %s to %s: %v", src, dst, err)
	}
	return ""
}

// scalar_int runs a one-value query; 0 when it fails or returns nothing.
scalar_int :: proc(db: sqlite3.Db, sql: string, args: ..sqlite3.Value) -> int {
	stmt, err := sqlite3.query(db, sql, ..args)
	if err != nil {
		return 0
	}
	defer sqlite3.finish(&stmt)
	if sqlite3.next(&stmt) {
		return int(sqlite3.integer(stmt, 0))
	}
	return 0
}

// scalar_text runs a one-value query; "" when it fails or returns nothing.
scalar_text :: proc(db: sqlite3.Db, sql: string, args: ..sqlite3.Value) -> string {
	stmt, err := sqlite3.query(db, sql, ..args)
	if err != nil {
		return ""
	}
	defer sqlite3.finish(&stmt)
	if sqlite3.next(&stmt) {
		return sqlite3.text(stmt, 0)
	}
	return ""
}

// column_texts runs a query and returns its first column, one string per row.
column_texts :: proc(db: sqlite3.Db, sql: string, args: ..sqlite3.Value) -> []string {
	rows := make([dynamic]string)
	stmt, err := sqlite3.query(db, sql, ..args)
	if err != nil {
		return nil
	}
	defer sqlite3.finish(&stmt)
	for sqlite3.next(&stmt) {
		append(&rows, sqlite3.text(stmt, 0))
	}
	return rows[:]
}

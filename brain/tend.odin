package brain

import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import "jm:path"
import "jm:sqlite3"

// Tending is the sweep that keeps the vault true without anyone remembering
// to look. Doctor, verify and learn can already see what goes wrong; tend
// runs them, applies the changes that cost nothing to undo (a date on a
// bullet whose claims all verified, an alias three sessions already asked
// by), and puts everything that changes meaning in the inbox as an item a
// person approves, beside the fact proposals: mark a note superseded, drop a
// bullet whose every claim failed, merge two bullets with one name. Settle
// runs it once a day when an agent stops, quickly and silently; `brain
// tend` runs it by hand. The 2026-10-02 proof showed why the vault's state
// is the product's: a stale note read as an answer, a fact living only in a
// long note, and a reviewed inbox were what separated the good runs from
// the bad.

// TEND_FILE logs the hygiene items a person applied.
TEND_FILE :: "AI/TENDED.md"
TEND_HEAD :: "# Tended\n\nHygiene items from `brain tend` that a person approved, as applied.\n\n"

// TEND_NOTE_LINES is how many lines of a note must name what newer bullets
// name before tend proposes marking the note superseded.
TEND_NOTE_LINES :: 2

// is_tend says whether an inbox bullet is a hygiene item: its source names
// the action tend_apply runs.
is_tend :: proc(b: Bullet) -> bool {
	return strings.has_prefix(b.source, "tend ")
}

cmd_tend :: proc(cli: ^Cli, args: []string) -> int {
	quick, dry := false, false
	for a in args {
		switch a {
		case "--quick":
			quick = true
		case "--dry-run":
			dry = true
		case:
			return fail(cli, "usage: brain tend [--quick] [--dry-run]")
		}
	}
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	r, err := tend(cli, quick, dry)
	if err != "" {
		return fail(cli, err)
	}
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field_int(&w, "dated", i64(r.dated))
		jw_field_int(&w, "aliases", i64(r.aliases))
		jw_field_int(&w, "proposed", i64(r.proposed))
		jw_field_int(&w, "lessons", i64(r.lessons))
		jw_field(&w, "dry_run", dry ? "true" : "false")
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	if dry {
		outf(cli, "tend would add %d aliases and propose %d hygiene items (%d verified bullets to date)\n", r.aliases, r.proposed, r.dated)
		return 0
	}
	outf(cli, "tend: added %d aliases, proposed %d hygiene items", r.aliases, r.proposed)
	if r.lessons > 0 {
		outf(cli, ", %d lessons", r.lessons)
	}
	if r.proposed > 0 || r.lessons > 0 {
		out(cli, "; brain inbox lists them")
	}
	out(cli, "\n")
	return 0
}

Tend_Result :: struct {
	dated, aliases, proposed, lessons: int,
}

// tend is one sweep. Automatic: dates and aliases. Proposed: supersede,
// drop, merge. quick leaves out the slow reads (commit claims, the
// transcripts) for the Stop hook; dry changes nothing and counts.
tend :: proc(cli: ^Cli, quick, dry: bool) -> (r: Tend_Result, err: string) {
	db, oerr := open_db(cli.db)
	if oerr != "" {
		return r, oerr
	}
	claims, _ := verify_all(cli, db, nil, quick)
	candidates := alias_candidates(db)
	older := retelling_notes(db)
	dups := merge_items(db)
	r.dated = count_undated(db, claims)
	if dry {
		r.aliases = len(candidates)
		r.proposed = (r.dated > 0 ? 1 : 0) + len(supersede_items(cli, older)) + len(drop_items(claims)) + len(dups)
		sqlite3.close(&db)
		return r, ""
	}
	r.aliases = apply_aliases(cli, candidates)
	sqlite3.close(&db)

	items := make([dynamic]string)
	// Dating is a proposal, not automatic: Jack chose on 2026-10-02 that a
	// bullet's date changes only when a person agrees, after a sweep
	// re-dated 31 bullets of the real vault on its first run.
	if r.dated > 0 {
		append(&items, date_item(r.dated))
	}
	append(&items, ..supersede_items(cli, older))
	append(&items, ..drop_items(claims))
	for d in dups {
		append(&items, d)
	}
	for line in items {
		b, ok := parse_bullet(line, "")
		if !ok {
			continue
		}
		mark := strings.builder_len(cli.out)
		inbox_write(cli, line, b)
		if strings.has_prefix(strings.to_string(cli.out)[mark:], "proposed") {
			r.proposed += 1
		}
	}
	if !quick && len(adapters_on(cli)) > 0 {
		if rdb, rerr := open_recall_db(cli); rerr == "" {
			recall_sync(cli, rdb, full = false)
			moments := lesson_moments(rdb, 7, "", "")
			sqlite3.close(&rdb)
			mark := strings.builder_len(cli.out)
			lessons_propose(cli, moments)
			r.lessons = strings.count(strings.to_string(cli.out)[mark:], "proposed #")
			resize(&cli.out.buf, mark)
		}
	}
	if r.dated > 0 || r.aliases > 0 || r.proposed > 0 || r.lessons > 0 {
		if serr := sync(cli, quiet = true); serr != "" {
			return r, serr
		}
	}
	return r, ""
}

// tend_daily runs a quick sweep once a day, silently: the stamp is the
// day, under the state directory, so every session of the day but the
// first finds it and moves on.
tend_daily :: proc(cli: ^Cli) {
	if cli.vault == "" || getenv(cli, "BRAIN_NO_TEND") != "" {
		return
	}
	stamp := path.join(cli.state, "tend", today_iso())
	if os.exists(stamp) {
		return
	}
	path.mkdirs(path.dir(stamp))
	path.write(stamp, "")
	if ensure_db(cli) != "" {
		return
	}
	mark := strings.builder_len(cli.out)
	tend(cli, quick = true, dry = false)
	resize(&cli.out.buf, mark)
}

// count_undated is how many bullets every claim of which passed and whose
// date is not today: what the date item would change.
count_undated :: proc(db: sqlite3.Db, claims: []Claim) -> int {
	Loc :: struct {
		file: string,
		line: i64,
	}
	clean := make(map[string]bool)
	order := make([dynamic]string)
	locs := make(map[string]Loc)
	for c in claims {
		key := strings.concatenate({c.file, ":", int_str(c.line)})
		was, known := clean[key]
		if !known {
			append(&order, key)
			locs[key] = Loc{c.file, c.line}
		}
		clean[key] = (was || !known) && c.verdict == "passed"
	}
	n := 0
	today := today_iso()
	for key in order {
		if !clean[key] {
			continue
		}
		at := locs[key]
		if scalar_text(db, "select date from bullets where file=? and line=?", at.file, at.line) != today {
			n += 1
		}
	}
	return n
}

// date_item proposes dating the bullets whose claims all verified.
date_item :: proc(n: int) -> string {
	return strings.concatenate(
		{
			"- **tend date verified bullets** (aliases: re-date, verified today) — ",
			int_str(i64(n)),
			" bullets make only claims that verify on this machine (paths, vault files, commands); approve dates them today, which is what a bullet's date means — tend date — ",
			today_iso(),
		},
	)
}

// apply_date re-verifies and dates every bullet whose claims all pass.
apply_date :: proc(cli: ^Cli) -> string {
	if err := ensure_db(cli); err != "" {
		return err
	}
	db, oerr := open_db(cli.db)
	if oerr != "" {
		return oerr
	}
	defer sqlite3.close(&db)
	claims, _ := verify_all(cli, db, nil, quick = true)
	apply_verified(cli, claims)
	return ""
}

// supersede_items proposes marking a dated note that TEND_NOTE_LINES or more
// lines of which name what newer bullets name, unless it is marked already.
supersede_items :: proc(cli: ^Cli, older: []Older_Note) -> []string {
	items := make([dynamic]string)
	for n in older {
		if n.lines < TEND_NOTE_LINES || note_superseded(cli, n.file) {
			continue
		}
		handles := make([dynamic]string)
		for h, i in n.handles {
			if i == 4 {
				append(&handles, "…")
				break
			}
			append(&handles, strings.concatenate({"**", h, "**"}))
		}
		append(
			&items,
			strings.concatenate(
				{
					"- **tend supersede ",
					path.base(n.file),
					"** (aliases: ",
					n.file,
					") — this ",
					n.date,
					" note retells what ",
					strings.join(handles[:], ", "),
					" settled later; approve writes a superseded header naming them, so a reader takes the bullets — tend supersede ",
					n.file,
					" — ",
					today_iso(),
				},
			),
		)
	}
	return items[:]
}

// TEND_RETELL_OVERLAP is the distinctive words a note line must share with a
// newer bullet's fact for the sweep to count it as a retelling. Serve time
// uses SHADOW_OVERLAP (3) on lines a query already selected; across the
// whole vault three words on two lines flagged 73 of 139 notes on
// 2026-10-02, so the sweep asks for five, against the same bullet, on
// TEND_NOTE_LINES lines.
TEND_RETELL_OVERLAP :: 5

// retelling_notes finds dated notes older than a bullet whose lines share
// TEND_RETELL_OVERLAP distinctive words with the bullet's fact: the content
// rule serve time uses, at a stricter bar. It does not use doctor's
// name rule (a note naming a handle): a handoff about a project names the
// project, and on 2026-10-02 that rule flagged 33 of 139 notes while the
// planted note, which contradicted five bullets and named none, needed the
// content rule to be found at all.
retelling_notes :: proc(db: sqlite3.Db) -> []Older_Note {
	by := make(map[string]^Older_Note)
	order := make([dynamic]string)
	// Lines per (file, handle): a note retells a bullet when TEND_NOTE_LINES
	// of its lines retell that one bullet, not when scattered lines each
	// brush a different one.
	per := make(map[string]int)
	add := proc(by: ^map[string]^Older_Note, order: ^[dynamic]string, per: ^map[string]int, file, date, handle: string, line: i64, lines: int) {
		key := strings.concatenate({file, "\x1f", handle})
		per[key] += lines
		if per[key] < TEND_NOTE_LINES {
			return
		}
		n, has := by[file]
		if !has {
			n = new(Older_Note)
			n.file = strings.clone(file)
			n.date = strings.clone(date)
			n.first = line
			by[n.file] = n
			append(order, n.file)
		}
		if line < n.first {
			n.first = line
		}
		for h in n.handles {
			if h == handle {
				n.lines = max(n.lines, per[key])
				return
			}
		}
		append(&n.handles, strings.clone(handle))
		n.lines = max(n.lines, per[key])
	}
	stop := PRIME_STOP
	stmt, err := sqlite3.query(db, "select handle, fact, date from bullets where file in " + CSV_CORE + " and date <> ''")
	if err != nil {
		return nil
	}
	defer sqlite3.finish(&stmt)
	for sqlite3.next(&stmt) {
		handle := strings.clone(sqlite3.text(stmt, 0))
		fact := strings.clone(sqlite3.text(stmt, 1))
		date := strings.clone(sqlite3.text(stmt, 2))
		words := make([dynamic]string)
		for t in query_terms(fact) {
			if len(words) == 12 {
				break
			}
			if utf8.rune_count_in_string(t) >= 4 && !slice.contains(stop[:], t) && !slice.contains(words[:], t) {
				append(&words, t)
			}
		}
		if len(words) < TEND_RETELL_OVERLAP {
			continue
		}
		groups := make([dynamic]string)
		for w in words {
			append(&groups, quoted(w))
		}
		rows, rerr := sqlite3.query(
			db,
			`select l.file, l.line, d.date, l.text
			 from lines_fts f join lines l on l.id = f.rowid join docs d on d.file = l.file
			 where lines_fts match ? and d.date <> '' and d.date < ?
			   and l.file not in ` + CSV_CORE + `
			 order by bm25(lines_fts) limit 30`,
			strings.join(groups[:], " OR "),
			date,
		)
		if rerr != nil {
			continue
		}
		for sqlite3.next(&rows) {
			text := sqlite3.text(rows, 3)
			if strings.contains(text, strings.concatenate({"**", handle, "**"})) {
				continue
			}
			if count_met_terms(text, words[:]) >= TEND_RETELL_OVERLAP {
				add(&by, &order, &per, sqlite3.text(rows, 0), sqlite3.text(rows, 2), handle, sqlite3.integer(rows, 1), 1)
			}
		}
		sqlite3.finish(&rows)
	}
	out := make([dynamic]Older_Note)
	for f in order {
		append(&out, by[f]^)
	}
	slice.sort_by(out[:], proc(a, b: Older_Note) -> bool {return a.lines > b.lines})
	return out[:]
}

// note_superseded says whether a note already carries a superseded header
// in its first lines.
note_superseded :: proc(cli: ^Cli, file: string) -> bool {
	text, ok := read_text(path.join(cli.vault, file))
	if !ok {
		return false
	}
	for l, i in strings.split_lines(text) {
		if i == 8 {
			break
		}
		if strings.contains(strings.to_lower(l), "superseded") {
			return true
		}
	}
	return false
}

// TEND_DROP_CLAIMS is how many claims must fail, with none passing, before
// tend proposes dropping a bullet. Verify reads some prose as claims (a
// Windows path, "brain calls" as a subcommand), and on 2026-10-02 both
// one-claim drop proposals on the real vault were that; two failing
// claims is a bullet about something gone.
TEND_DROP_CLAIMS :: 2

// drop_items proposes dropping a bullet every checkable claim of which
// failed, TEND_DROP_CLAIMS at least: the paths, files or commands it
// names are not there.
drop_items :: proc(claims: []Claim) -> []string {
	State :: struct {
		file, handle: string,
		failed, other: int,
		why:          string,
	}
	by := make(map[string]State)
	order := make([dynamic]string)
	for c in claims {
		key := strings.concatenate({c.file, ":", int_str(c.line)})
		st, known := by[key]
		if !known {
			st = State{file = c.file, handle = c.handle}
			append(&order, key)
		}
		if c.verdict == "failed" {
			st.failed += 1
			if st.why == "" {
				st.why = strings.concatenate({c.kind, " ", c.text})
			}
		} else {
			st.other += 1
		}
		by[key] = st
	}
	items := make([dynamic]string)
	for key in order {
		st := by[key]
		if st.failed < TEND_DROP_CLAIMS || st.other > 0 {
			continue
		}
		append(
			&items,
			strings.concatenate(
				{
					"- **tend drop ",
					st.handle,
					"** (aliases: ",
					st.file,
					") — every claim this bullet makes failed verification (",
					st.why,
					"); approve moves it to AI/DROPPED.md — tend drop ",
					st.file,
					" ",
					st.handle,
					" — ",
					today_iso(),
				},
			),
		)
	}
	return items[:]
}

// merge_items proposes merging core bullets that share a name: keep the
// most recently dated, drop the rest.
merge_items :: proc(db: sqlite3.Db) -> []string {
	items := make([dynamic]string)
	stmt, err := sqlite3.query(db, "select handle, count(*) n, group_concat(file, ', ') from bullets where file in " + CSV_CORE + " group by lower(handle) having n > 1")
	if err != nil {
		return nil
	}
	defer sqlite3.finish(&stmt)
	for sqlite3.next(&stmt) {
		handle := strings.clone(sqlite3.text(stmt, 0))
		append(
			&items,
			strings.concatenate(
				{
					"- **tend merge ",
					handle,
					"** (aliases: duplicate handle) — ",
					int_str(sqlite3.integer(stmt, 1)),
					" bullets answer to this name (",
					strings.clone(sqlite3.text(stmt, 2)),
					"); approve keeps the one most recently dated (a bullet that verified today is) and moves the others to AI/DROPPED.md — tend merge ",
					handle,
					" — ",
					today_iso(),
				},
			),
		)
	}
	return items[:]
}

// tend_apply runs the action a hygiene item names. The source is
// `tend <action> <args>`.
tend_apply :: proc(cli: ^Cli, b: Bullet) -> string {
	words := strings.fields(b.source)
	if len(words) < 2 || words[0] != "tend" {
		return "not a hygiene item"
	}
	if words[1] == "date" {
		return apply_date(cli)
	}
	if len(words) < 3 {
		return "not a hygiene item"
	}
	switch words[1] {
	case "supersede":
		return apply_supersede(cli, words[2], b.fact)
	case "drop":
		return apply_drop(cli, words[2], strings.join(words[3:], " "))
	case "merge":
		return apply_merge(cli, strings.join(words[2:], " "))
	}
	return strings.concatenate({"unknown hygiene action: ", words[1]})
}

// apply_supersede writes the header after the note's title, naming the
// bullets the item named.
apply_supersede :: proc(cli: ^Cli, file, fact: string) -> string {
	full := path.join(cli.vault, file)
	text, ok := read_text(full)
	if !ok {
		return strings.concatenate({"no such note: ", file})
	}
	names := make([dynamic]string)
	rest := fact
	for {
		i := strings.index(rest, "**")
		if i < 0 {
			break
		}
		rest = rest[i + 2:]
		j := strings.index(rest, "**")
		if j < 0 {
			break
		}
		append(&names, strings.concatenate({"**", rest[:j], "**"}))
		rest = rest[j + 2:]
	}
	header := strings.concatenate(
		{"> Superseded (brain tend, ", today_iso(), "): ", len(names) > 0 ? strings.join(names[:], ", ") : "newer bullets", " in the core files are current; this note is kept as history.\n"},
	)
	lines := strings.split_lines(text)
	at := 0
	for l, i in lines {
		if strings.has_prefix(l, "# ") {
			at = i + 1
			break
		}
	}
	b := strings.builder_make()
	for l, i in lines {
		if i == at {
			if at > 0 {
				strings.write_string(&b, "\n")
			}
			strings.write_string(&b, header)
			if at == 0 {
				strings.write_string(&b, "\n")
			}
		}
		strings.write_string(&b, l)
		if i < len(lines) - 1 {
			strings.write_string(&b, "\n")
		}
	}
	if at >= len(lines) {
		strings.write_string(&b, "\n")
		strings.write_string(&b, header)
	}
	if werr := path.write(full, strings.to_string(b)); werr != nil {
		return strings.concatenate({"cannot write ", file})
	}
	return ""
}

// apply_drop moves the named bullet out of its core file into the dropped
// list.
apply_drop :: proc(cli: ^Cli, file, handle: string) -> string {
	full := path.join(cli.vault, file)
	text, ok := read_text(full)
	if !ok {
		return strings.concatenate({"no such file: ", file})
	}
	kept := make([dynamic]string)
	moved := make([dynamic]string)
	for l in strings.split_lines(text) {
		if b, is := parse_bullet(l, ""); is && strings.equal_fold(b.handle, handle) {
			append(&moved, l)
			continue
		}
		append(&kept, l)
	}
	if len(moved) == 0 {
		return strings.concatenate({"no bullet named ", handle, " in ", file})
	}
	if err := append_dropped(cli, moved[:]); err != "" {
		return err
	}
	if werr := path.write(full, strings.join(kept[:], "\n")); werr != nil {
		return strings.concatenate({"cannot write ", file})
	}
	return ""
}

// apply_merge keeps the most recently dated core bullet of a name and drops
// the rest. Tend dates a bullet whose claims all verified before it judges
// duplicates, so where one telling verifies and another does not, the one
// that verifies is the one kept.
apply_merge :: proc(cli: ^Cli, handle: string) -> string {
	Found :: struct {
		file, line, date: string,
	}
	all := make([dynamic]Found)
	for rel in ([3]string{"AI/MEMORY.md", "AI/LEARNINGS.md", "AI/TUNINGS.md"}) {
		text, ok := read_text(path.join(cli.vault, rel))
		if !ok {
			continue
		}
		for l in strings.split_lines(text) {
			if b, is := parse_bullet(l, ""); is && strings.equal_fold(b.handle, handle) {
				append(&all, Found{file = rel, line = l, date = b.date})
			}
		}
	}
	if len(all) < 2 {
		return strings.concatenate({"fewer than two bullets named ", handle})
	}
	keep := 0
	for f, i in all {
		if f.date > all[keep].date {
			keep = i
		}
	}
	for f, i in all {
		if i == keep {
			continue
		}
		if err := apply_drop_line(cli, f.file, f.line); err != "" {
			return err
		}
	}
	return ""
}

// apply_drop_line moves one exact line out of a core file into the dropped list.
apply_drop_line :: proc(cli: ^Cli, file, line: string) -> string {
	full := path.join(cli.vault, file)
	text, ok := read_text(full)
	if !ok {
		return strings.concatenate({"no such file: ", file})
	}
	kept := make([dynamic]string)
	taken := false
	for l in strings.split_lines(text) {
		if !taken && l == line {
			taken = true
			continue
		}
		append(&kept, l)
	}
	if !taken {
		return "the bullet changed since tend read it; run brain tend again"
	}
	if err := append_dropped(cli, {line}); err != "" {
		return err
	}
	if werr := path.write(full, strings.join(kept[:], "\n")); werr != nil {
		return strings.concatenate({"cannot write ", file})
	}
	return ""
}

// append_dropped adds lines to AI/DROPPED.md, which propose checks.
append_dropped :: proc(cli: ^Cli, lines: []string) -> string {
	dropped := path.join(cli.vault, DROPPED_FILE)
	text, exists := read_text(dropped)
	if !exists {
		text = DROPPED_HEAD
	}
	if !strings.has_suffix(text, "\n") {
		text = strings.concatenate({text, "\n"})
	}
	b := strings.builder_make()
	strings.write_string(&b, text)
	for l in lines {
		strings.write_string(&b, l)
		strings.write_string(&b, "\n")
	}
	if werr := path.write(dropped, strings.to_string(b)); werr != nil {
		return "cannot write AI/DROPPED.md"
	}
	return ""
}

// tend_log records an applied item, so the vault says what tend did and when.
tend_log :: proc(cli: ^Cli, line: string) {
	full := path.join(cli.vault, TEND_FILE)
	text, exists := read_text(full)
	if !exists {
		text = TEND_HEAD
	}
	if !strings.has_suffix(text, "\n") {
		text = strings.concatenate({text, "\n"})
	}
	path.write(full, strings.concatenate({text, line, "\n"}))
}


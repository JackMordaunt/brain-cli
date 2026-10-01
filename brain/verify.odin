package brain

import "core:os"
import "core:strings"

import "jm:path"
import "jm:sh"
import "jm:sqlite3"

// A bullet is stale by its date alone until something checks it. Many
// facts make a claim a machine can test: a path exists, a file in the
// vault is there, a brain subcommand is real, a commit is in a
// repository on this machine. `brain verify` extracts those claims from
// the core bullets, tests them, keeps the verdicts in the index for
// doctor, and names the failures. --apply rewrites the date on every
// bullet whose claims all passed, so the date means checked, not old.

// The subcommands a bullet may name, so `brain foo` is a claim.
COMMANDS :: [?]string {
	"locate", "find", "pack", "prime", "recall", "howto", "day", "week", "propose", "lessons", "settle",
	"inbox", "review", "import", "export", "mcp", "doctor", "verify", "learn", "log", "ledger", "lint",
	"secrets", "reindex", "sync", "install", "uninstall", "hooks", "update", "version", "help",
}

GIT_SHA_MIN :: 7 // hex characters before a word is a commit
SHA_REPOS :: 40 // repositories looked in for a commit no bullet places

// An absolute path claims to exist only under a root a machine has; a
// lone /flag or /url/path is not one.
PATH_ROOTS :: [?]string {
	"home", "usr", "etc", "opt", "tmp", "var", "mnt", "srv", "root", "run", "nix", "bin", "sbin", "lib",
	"Users", "Applications", "Library", "Volumes", "c", "C:", "d", "D:",
}

Claim :: struct {
	file:    string,
	line:    i64,
	handle:  string,
	kind:    string, // path, vault-file, command, sha
	text:    string,
	verdict: string, // passed, failed, unchecked
	why:     string,
}

cmd_verify :: proc(cli: ^Cli, args: []string) -> int {
	apply := false
	only := make([dynamic]string)
	for a in args {
		switch a {
		case "--apply":
			apply = true
		case:
			if strings.has_prefix(a, "-") {
				return fail(cli, "usage: brain verify [<handle>...] [--apply]")
			}
			append(&only, strings.to_lower(a))
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

	claims := make([dynamic]Claim)
	bullets := 0
	stmt, qerr := sqlite3.query(db, "select file, line, handle, aliases, fact from bullets where file in " + CSV_CORE + " order by file, line")
	if qerr != nil {
		return fail(cli, sql_err(qerr))
	}
	for sqlite3.next(&stmt) {
		handle := strings.clone(sqlite3.text(stmt, 2))
		if len(only) > 0 && !names_any(handle, strings.clone(sqlite3.text(stmt, 3)), only[:]) {
			continue
		}
		found := extract_claims(cli, strings.clone(sqlite3.text(stmt, 0)), sqlite3.integer(stmt, 1), handle, strings.clone(sqlite3.text(stmt, 4)))
		if len(found) > 0 {
			bullets += 1
		}
		append(&claims, ..found)
	}
	sqlite3.finish(&stmt)
	for &c in claims {
		check_claim(cli, &c)
	}
	// The verdicts replace the last run's, for doctor to read.
	sqlite3.exec(db, "begin")
	if len(only) == 0 {
		sqlite3.exec(db, "delete from claims")
	} else {
		for c in claims {
			sqlite3.exec_args(db, "delete from claims where handle=?", c.handle)
		}
	}
	for c in claims {
		sqlite3.exec_args(
			db,
			"insert into claims(file,line,handle,kind,text,verdict,why,checked) values(?,?,?,?,?,?,?,datetime('now'))",
			c.file,
			c.line,
			c.handle,
			c.kind,
			c.text,
			c.verdict,
			c.why,
		)
	}
	sqlite3.exec(db, "commit")

	failed := 0
	for c in claims {
		if c.verdict == "failed" {
			failed += 1
		}
	}
	applied := 0
	if apply {
		applied = apply_verified(cli, claims[:])
	}
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field_int(&w, "bullets", i64(bullets))
		jw_field_int(&w, "claims", i64(len(claims)))
		jw_field_int(&w, "failed", i64(failed))
		jw_field_int(&w, "applied", i64(applied))
		jw_key(&w, "failures")
		jw_arr(&w)
		for c in claims {
			if c.verdict != "failed" {
				continue
			}
			jw_obj(&w)
			jw_field(&w, "file", c.file)
			jw_field_int(&w, "line", c.line)
			jw_field(&w, "handle", c.handle)
			jw_field(&w, "kind", c.kind)
			jw_field(&w, "text", c.text)
			jw_field(&w, "why", c.why)
			jw_end_obj(&w)
		}
		jw_end_arr(&w)
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return failed > 0 ? 1 : 0
	}
	outf(cli, "%d bullets make %d checkable claims; %d failed\n", bullets, len(claims), failed)
	for c in claims {
		if c.verdict == "failed" {
			outf(cli, "%s:%d **%s** %s %s: %s\n", c.file, c.line, c.handle, c.kind, c.text, c.why)
		}
	}
	if apply {
		outf(cli, "dated today: %d bullets whose claims all passed\n", applied)
	}
	return failed > 0 ? 1 : 0
}

names_any :: proc(handle, aliases: string, wanted: []string) -> bool {
	h := strings.to_lower(handle)
	for w in wanted {
		if h == w {
			return true
		}
		for a in strings.split(strings.to_lower(aliases), ",") {
			if strings.trim_space(a) == w {
				return true
			}
		}
	}
	return false
}

// extract_claims reads one bullet's fact for the claims a machine can
// test. Tokens are words of the fact with backticks and the punctuation
// around them dropped; anything inside a URL is left alone.
extract_claims :: proc(cli: ^Cli, file: string, line: i64, handle, fact: string) -> []Claim {
	claims := make([dynamic]Claim)
	words := strings.fields(fact)
	for w, i in words {
		if strings.contains(w, "://") {
			continue
		}
		tok := strings.trim(w, "`'\"(),;:.!?[]<>")
		if tok == "" {
			continue
		}
		at := Claim{file = file, line = line, handle = handle, text = tok}
		switch {
		case is_path_claim(tok):
			at.kind = "path"
			append(&claims, at)
		case strings.contains(tok, "/") && !strings.has_prefix(tok, ".") && !strings.contains_any(tok, "*?=") && (strings.has_suffix(tok, ".md") || strings.has_suffix(tok, ".tsv")):
			at.kind = "vault-file"
			append(&claims, at)
		case tok == "brain" && i + 1 < len(words):
			sub := strings.trim(words[i + 1], "`'\"(),;:.!?[]<>")
			if sub != "" && !strings.has_prefix(sub, "-") && is_plain_word(sub) {
				at.text = strings.concatenate({"brain ", sub})
				at.kind = "command"
				append(&claims, at)
			}
		case len(tok) >= GIT_SHA_MIN && len(tok) <= 40 && is_sha(tok):
			at.kind = "sha"
			append(&claims, at)
		}
	}
	return claims[:]
}

// is_path_claim is a token that names a place on a machine: under the
// home directory, or absolute under a root machines have, with no glob,
// variable or query inside it.
is_path_claim :: proc(tok: string) -> bool {
	if len(tok) <= 3 || strings.contains_any(tok, "*$<>{}|?=") || strings.has_prefix(tok, "//") {
		return false
	}
	if strings.has_prefix(tok, "~/") {
		return true
	}
	if !strings.has_prefix(tok, "/") {
		return false
	}
	first := tok[1:]
	if i := strings.index_byte(first, '/'); i >= 0 {
		first = first[:i]
	} else {
		return false // one segment is a flag or a route, not a place
	}
	roots := PATH_ROOTS
	for r in roots {
		if first == r {
			return true
		}
	}
	return false
}

is_plain_word :: proc(s: string) -> bool {
	for c in transmute([]byte)s {
		if !((c >= 'a' && c <= 'z') || c == '-') {
			return false
		}
	}
	return true
}

// is_sha is a run of lowercase hex holding both a digit and a letter,
// which a word or a number is not.
is_sha :: proc(s: string) -> bool {
	digit, letter := false, false
	for c in transmute([]byte)s {
		switch {
		case c >= '0' && c <= '9':
			digit = true
		case c >= 'a' && c <= 'f':
			letter = true
		case:
			return false
		}
	}
	return digit && letter
}

// check_claim tests one claim against this machine.
check_claim :: proc(cli: ^Cli, c: ^Claim) {
	switch c.kind {
	case "path":
		p := c.text
		if strings.has_prefix(p, "~/") {
			p = path.join(cli.home, p[2:])
		}
		if os.exists(p) {
			c.verdict = "passed"
		} else {
			c.verdict, c.why = "failed", "not on this machine"
		}
	case "vault-file":
		// Bullets name AI/ files with and without the prefix.
		if os.exists(path.join(cli.vault, c.text)) || os.exists(path.join(cli.vault, "AI", c.text)) {
			c.verdict = "passed"
		} else {
			c.verdict, c.why = "failed", "not in the vault"
		}
	case "command":
		sub := c.text[len("brain "):]
		commands := COMMANDS
		for k in commands {
			if k == sub {
				c.verdict = "passed"
				return
			}
		}
		c.verdict, c.why = "failed", "no such subcommand"
	case "sha":
		repos := sha_repos(cli, c.file, c.line)
		if _, found := sh.which("git"); !found || len(repos) == 0 {
			c.verdict, c.why = "unchecked", "no repository to look in"
			return
		}
		for repo in repos {
			r := sh.exec({"git", "cat-file", "-e", strings.concatenate({c.text, "^{commit}"})}, {dir = repo, timeout = GIT_TIMEOUT})
			if r.ok {
				c.verdict = "passed"
				return
			}
		}
		if len(repos) == 1 {
			c.verdict, c.why = "failed", strings.concatenate({"no such commit in ", repos[0]})
		} else {
			c.verdict, c.why = "failed", strings.concatenate({"in none of the ", int_str(i64(len(repos))), " repositories agents have worked in here"})
		}
	}
}

// sha_repos is where a bullet's commit is looked up: the paths the same
// bullet names that are repositories on this machine, else every
// repository the transcripts saw an agent work in.
sha_repos :: proc(cli: ^Cli, file: string, line: i64) -> []string {
	repos := make([dynamic]string)
	if s, serr := scan_file(cli.vault, file); serr == nil {
		for b in s.bullets {
			if i64(b.line) != line {
				continue
			}
			for c in extract_claims(cli, file, line, b.handle, b.fact) {
				p := c.text
				if strings.has_prefix(p, "~/") {
					p = path.join(cli.home, p[2:])
				}
				if c.kind == "path" && os.exists(path.join(p, ".git")) {
					append(&repos, p)
				}
			}
		}
	}
	if len(repos) > 0 {
		return repos[:]
	}
	return worked_repos(cli)
}

// worked_repos is every directory the transcripts saw an agent run in
// that is a repository on this machine, most recent first.
worked_repos :: proc(cli: ^Cli) -> []string {
	if len(adapters_on(cli)) == 0 || !os.exists(cli.recall_db) {
		return nil
	}
	rc, err := open_recall_db(cli)
	if err != "" {
		return nil
	}
	defer sqlite3.close(&rc)
	repos := make([dynamic]string)
	for cwd in column_texts(rc, "select cwd from turn where cwd <> '' group by cwd order by max(ts) desc limit ?", i64(SHA_REPOS)) {
		if os.exists(path.join(cwd, ".git")) {
			append(&repos, strings.clone(cwd))
		}
	}
	return repos[:]
}

// apply_verified dates today every bullet whose claims all passed, in its
// own file, and resyncs. A bullet with an unchecked claim keeps its date.
apply_verified :: proc(cli: ^Cli, claims: []Claim) -> int {
	Bullet_State :: struct {
		file:  string,
		line:  i64,
		clean: bool,
	}
	by_key := make(map[string]Bullet_State)
	order := make([dynamic]string)
	for c in claims {
		key := strings.concatenate({c.file, ":", int_str(c.line)})
		st, known := by_key[key]
		if !known {
			st = Bullet_State{file = c.file, line = c.line, clean = true}
			append(&order, key)
		}
		if c.verdict != "passed" {
			st.clean = false
		}
		by_key[key] = st
	}
	today := today_iso()
	changed := make(map[string][]string)
	applied := 0
	for key in order {
		st := by_key[key]
		if !st.clean {
			continue
		}
		lines, has := changed[st.file]
		if !has {
			text, ok := read_text(path.join(cli.vault, st.file))
			if !ok {
				continue
			}
			lines = strings.split_lines(text)
		}
		i := int(st.line) - 1
		if i < 0 || i >= len(lines) {
			continue
		}
		b, ok := parse_bullet(lines[i], "")
		if !ok || b.date == today {
			continue
		}
		lines[i] = strings.concatenate({strings.trim_suffix(lines[i], b.date), today})
		changed[st.file] = lines
		applied += 1
	}
	for file, lines in changed {
		path.write(path.join(cli.vault, file), strings.join(lines, "\n"))
	}
	if applied > 0 {
		sync(cli, quiet = true)
	}
	return applied
}

// ---- doctor's reads --------------------------------------------------------

// Suspect is a bullet served shortly before the person corrected the
// agent: the serve may have misled it.
Suspect :: struct {
	handle, file, session, served, user: string,
}

SUSPECT_TURNS :: 10 // turns between the serve and the correction, at most

// suspects joins the find log to the transcripts: every correction in the
// window, and the bullets served at rank three or better in its session
// within SUSPECT_TURNS turns before it.
suspects :: proc(cli: ^Cli, db: sqlite3.Db) -> []Suspect {
	if len(adapters_on(cli)) == 0 || !os.exists(cli.recall_db) {
		return nil
	}
	rc, err := open_recall_db(cli)
	if err != "" {
		return nil
	}
	defer sqlite3.close(&rc)
	found := make([dynamic]Suspect)
	seen := make(map[string]bool)
	for m in lesson_moments(rc, 0, "", "") {
		if m.kind != "correction" || m.session == "" {
			continue
		}
		at := log_time(m.ts)
		stmt, qerr := sqlite3.query(
			db,
			`select h.handle, h.file, q.ts from query_hits h join queries q on q.id = h.query_id
			 where q.session = ? and h.rank <= 3 and q.ts <= ? order by q.ts desc`,
			m.session,
			at,
		)
		if qerr != nil {
			continue
		}
		for sqlite3.next(&stmt) {
			served := sqlite3.text(stmt, 2)
			between := scalar_int(rc, "select count(*) from turn where session=? and ts > ? and ts <= ?", m.session, turn_time(served), m.ts)
			if between > SUSPECT_TURNS {
				continue
			}
			key := strings.concatenate({m.session, "/", sqlite3.text(stmt, 0)})
			if seen[key] {
				continue
			}
			seen[key] = true
			append(
				&found,
				Suspect {
					handle = strings.clone(sqlite3.text(stmt, 0)),
					file = strings.clone(sqlite3.text(stmt, 1)),
					session = m.session,
					served = strings.clone(served),
					user = rune_prefix(strings.trim_space(m.user), 80),
				},
			)
		}
		sqlite3.finish(&stmt)
	}
	return found[:]
}

// log_time turns a transcript's 2026-01-01T10:00:00.000Z into the find
// log's 2026-01-01 10:00:00, and turn_time goes back.
log_time :: proc(ts: string) -> string {
	t, _ := strings.replace_all(rune_prefix(ts, 19), "T", " ")
	return t
}

turn_time :: proc(ts: string) -> string {
	t, _ := strings.replace_all(ts, " ", "T")
	return t
}

// Contradiction is two core bullets that answer to the same name and say
// nothing in common: one of them is likely wrong, or they want merging.
Contradiction :: struct {
	name, a, b, a_file, b_file: string,
}

CONTRADICTION_LIMIT :: 20

contradictions :: proc(db: sqlite3.Db) -> []Contradiction {
	Named :: struct {
		handle, file, fact: string,
		words:              map[string]bool,
	}
	all := make([dynamic]Named)
	by_name := make(map[string][dynamic]int)
	stmt, err := sqlite3.query(db, "select handle, aliases, fact, file from bullets where file in " + CSV_CORE)
	if err != nil {
		return nil
	}
	defer sqlite3.finish(&stmt)
	stop := PRIME_STOP
	for sqlite3.next(&stmt) {
		n := Named{handle = strings.clone(sqlite3.text(stmt, 0)), fact = strings.clone(sqlite3.text(stmt, 2)), file = strings.clone(sqlite3.text(stmt, 3))}
		n.words = make(map[string]bool)
		outer: for w in query_terms(n.fact) {
			if len(w) < 4 {
				continue
			}
			for s in stop {
				if w == s {
					continue outer
				}
			}
			n.words[w] = true
		}
		idx := len(all)
		append(&all, n)
		names := make([dynamic]string)
		append(&names, strings.join(query_terms(n.handle), " "))
		for a in strings.split(sqlite3.text(stmt, 1), ",") {
			if p := strings.join(query_terms(a), " "); p != "" {
				append(&names, p)
			}
		}
		for name in names {
			list, has := by_name[name]
			if !has {
				list = make([dynamic]int)
			}
			append(&list, idx)
			by_name[strings.clone(name)] = list
		}
	}
	found := make([dynamic]Contradiction)
	seen := make(map[string]bool)
	for name, list in by_name {
		for i in 0 ..< len(list) {
			for j in i + 1 ..< len(list) {
				a, b := all[list[i]], all[list[j]]
				if a.handle == b.handle {
					continue
				}
				key := strings.concatenate({a.handle, "|", b.handle})
				if seen[key] {
					continue
				}
				shared := false
				for w in a.words {
					if b.words[w] {
						shared = true
						break
					}
				}
				if shared {
					continue
				}
				seen[key] = true
				append(&found, Contradiction{name = name, a = a.handle, b = b.handle, a_file = a.file, b_file = b.file})
				if len(found) == CONTRADICTION_LIMIT {
					return found[:]
				}
			}
		}
	}
	return found[:]
}

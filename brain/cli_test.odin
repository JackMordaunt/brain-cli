package brain

import "core:os"
import "core:strings"
import "core:testing"

import "jm:path"
import "jm:selfupdate"
import "jm:sqlite3"

// Fixture is a copy of testdata/vault in a fresh temp directory with its own
// state and config, so a test can edit the vault and never touches anyone's
// real notes, index or home.
Fixture :: struct {
	root:  string,
	vault: string,
	state: string,
	home:  string,
	cli:   ^Cli,
}

fixture :: proc(t: ^testing.T) -> Fixture {
	root, err := path.temp_dir("brain-test-")
	testing.expect_value(t, err, nil)
	f := Fixture {
		root  = root,
		vault = path.join(root, "vault"),
		state = path.join(root, "state"),
		home  = path.join(root, "home"),
	}
	copy_tree(t, "testdata/vault", f.vault)
	f.cli = fixture_cli(f)
	return f
}

fixture_cli :: proc(f: Fixture) -> ^Cli {
	env := make(map[string]string)
	env["BRAIN_VAULT"] = f.vault
	env["BRAIN_STATE"] = f.state
	env["HOME"] = f.home
	env["XDG_CONFIG_HOME"] = path.join(f.home, ".config")
	env["BRAIN_CALLER"] = ""
	env["BRAIN_SESSION"] = ""
	env["CLAUDECODE"] = ""
	env["CLAUDE_CODE_SESSION_ID"] = ""
	env["BRAIN_TOOL"] = ""
	return new_cli(env)
}

fixture_destroy :: proc(f: Fixture) {
	os.remove_all(f.root)
}

copy_tree :: proc(t: ^testing.T, from, to: string) {
	files, err := path.walk(from)
	testing.expect_value(t, err, nil)
	for src in files {
		rel := relative(from, src)
		dst := path.join(to, rel)
		testing.expect_value(t, path.mkdirs(path.dir(dst)), nil)
		testing.expect_value(t, os.copy_file(dst, src), nil)
	}
}

// exec runs one command in-process and returns what it printed.
exec :: proc(cli: ^Cli, args: ..string) -> (stdout, stderr: string, code: int) {
	strings.builder_reset(&cli.out)
	strings.builder_reset(&cli.err)
	code = run(cli, args)
	return strings.clone(strings.to_string(cli.out)), strings.clone(strings.to_string(cli.err)), code
}

// count_int runs a one-value query against the fixture's index.
count_int :: proc(t: ^testing.T, f: Fixture, sql: string) -> int {
	db, err := open_db(f.cli.db)
	testing.expect_value(t, err, "")
	defer sqlite3.close(&db)
	return scalar_int(db, sql)
}

last_query_row :: proc(t: ^testing.T, f: Fixture) -> string {
	db, err := open_db(f.cli.db)
	testing.expect_value(t, err, "")
	defer sqlite3.close(&db)
	return scalar_text(db, "select hits || ' ' || caller || ' ' || session from queries order by id desc limit 1")
}

@(test)
sync_indexes_the_fixture :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, e, code := exec(f.cli, "sync")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, e, "")
	testing.expect_value(t, o, "indexed 5 bullets, 0 links, 4 files\n")
}

@(test)
locate_prints_the_vault_and_the_tool :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, code := exec(f.cli, "locate")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, strings.trim_space(o), f.vault)
	o, _, code = exec(f.cli, "locate", "--tool")
	testing.expect_value(t, code, 0)
	testing.expect(t, os.is_file(path.join(strings.trim_space(o), "bin", "hooks", "pre-commit")), "--tool names the checkout")
}

@(test)
find_ranks_a_handle_and_reaches_a_document :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, code := exec(f.cli, "find", "sqlite")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "**sqlite**"), "find bullet")
	testing.expect(t, strings.has_prefix(o, "AI/MEMORY.md:"), "a locator precedes the bullet")
	o, _, code = exec(f.cli, "find", "handoff")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "-- documents --"), "find document")
	o, _, code = exec(f.cli, "find", "zzzznope")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.has_prefix(o, "no hits for: zzzznope"), "a miss says so")
}

// The vault's AI/synonyms.tsv is the query vocabulary: a term in it expands
// to its rows, and a vault without the file simply has no expansion.
@(test)
find_expands_terms_from_the_vaults_synonyms :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, code := exec(f.cli, "find", "fulltext")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "**sqlite**"), "fulltext expands to sqlite through the fixture's synonyms")
	// A removed file leaves nothing to be newer than the index, so this
	// resyncs by hand; an edited file re-indexes on its own.
	testing.expect_value(t, os.remove(path.join(f.vault, SYNONYMS_FILE)), nil)
	_, _, code = exec(f.cli, "sync")
	testing.expect_value(t, code, 0)
	_, _, code = exec(f.cli, "find", "fulltext")
	testing.expect_value(t, code, 1)
	testing.expect_value(t, count_int(t, f, "select count(*) from synonyms"), 0)
}

@(test)
find_logs_entries_and_the_caller :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.env["BRAIN_CALLER"] = "fixture-agent"
	f.cli.env["BRAIN_SESSION"] = "sess-a"
	o, _, _ := exec(f.cli, "find", "sqlite")
	entries := strings.count(o, ".md:")
	testing.expect(t, entries >= 1)
	got := last_query_row(t, f)
	want := strings.concatenate({int_str(i64(entries)), " fixture-agent sess-a"})
	testing.expect_value(t, got, want)
}

// The log is evidence and must survive a rebuild. On Windows the shell
// version's carry-over once attached a path sqlite3.exe could not open, and
// every sync erased it.
@(test)
log_survives_sync :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	exec(f.cli, "find", "sqlite")
	exec(f.cli, "find", "zzzznope")
	before := count_int(t, f, "select count(*) from queries")
	testing.expect_value(t, before, 2)
	_, _, code := exec(f.cli, "sync")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, count_int(t, f, "select count(*) from queries"), before)
	testing.expect(t, count_int(t, f, "select count(*) from query_hits") >= 1, "hits carry over too")
}

// A miss that a later edit answers leaves the backlog on its own.
@(test)
log_sets_an_answered_miss_aside :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	exec(f.cli, "find", "zzzznope")
	testing.expect_value(
		t,
		path.append_file(
			path.join(f.vault, "AI", "MEMORY.md"),
			"- **zzzznope** (aliases: nope) — now written down — fixture — 2026-01-02\n",
		),
		nil,
	)
	o, _, code := exec(f.cli, "log")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "missed then answered"), "the answered miss is reported")
	testing.expect(t, strings.contains(o, "zzzznope"), "and named")
	testing.expect(t, !strings.contains(o, "\n│ zzzznope"), "but is out of the backlog table")
}

// A local build has no version, so it reports "dev" and refuses to update
// itself; only a release build carries a tag and an update path.
@(test)
version_and_update_on_a_development_build :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, code := exec(f.cli, "version")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "brain dev ("), o)
	testing.expect(t, strings.contains(o, ASSET), o)
	e: string
	_, e, code = exec(f.cli, "update")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "development build"), e)
	key: [32]byte
	testing.expect(t, selfupdate.key_from_hex(PUBLIC_KEY, key[:]), "the embedded public key decodes")
}

@(test)
find_reads_a_crlf_vault :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	for name in ([3]string{"MEMORY.md", "LEARNINGS.md", "TUNINGS.md"}) {
		p := path.join(f.vault, "AI", name)
		text, err := path.read(p)
		testing.expect_value(t, err, nil)
		crlf, _ := strings.replace_all(text, "\n", "\r\n")
		testing.expect_value(t, path.write(p, crlf), nil)
	}
	o, _, code := exec(f.cli, "find", "sqlite")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "**sqlite**"), "find on a CRLF vault")
}

// A term of three or more characters also matches the start of a handle or
// alias, so a stem or a typo's tail still lands. Prose keeps exact terms.
@(test)
find_matches_a_handle_by_prefix :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, code := exec(f.cli, "find", "libgi")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "**libgit2**"), "libgi reaches libgit2")
	_, _, code = exec(f.cli, "find", "li")
	testing.expect_value(t, code, 1)
}

// An agent gets one line per hit without the aliases or the source; --raw
// brings the line as written back, and a terminal gets it by default.
@(test)
find_prints_terse_for_an_agent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, _ := exec(f.cli, "find", "sqlite")
	testing.expect(t, strings.contains(o, "(aliases:"), "a terminal sees the aliases")
	f.cli.env["BRAIN_CALLER"] = "fixture-agent"
	o, _, _ = exec(f.cli, "find", "sqlite")
	testing.expect(t, !strings.contains(o, "(aliases:"), "an agent does not")
	testing.expect(t, !strings.contains(o, "— fixture —"), "nor the source")
	testing.expect(t, strings.has_prefix(o, "AI/MEMORY.md:"), "the locator leads the line")
	testing.expect(t, strings.contains(o, " **sqlite** — the index is SQLite"), "handle then fact")
	testing.expect(t, strings.contains(o, "— 2026-01-01\n"), "the date closes it")
	o, _, _ = exec(f.cli, "find", "sqlite", "--raw")
	testing.expect(t, strings.contains(o, "(aliases:"), "--raw restores the line")
	delete_key(&f.cli.env, "BRAIN_CALLER")
	o, _, _ = exec(f.cli, "find", "sqlite", "--terse")
	testing.expect(t, !strings.contains(o, "(aliases:"), "--terse asks for the short form")
}

// A query that is a bullet's handle or alias returns that bullet and only
// its near ties, in front.
@(test)
find_cuts_to_the_named_bullet :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, code := exec(f.cli, "find", "jm:git")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "AI/MEMORY.md:"), "a hit")
	testing.expect(t, strings.contains(o, "**libgit2**"), "the alias names libgit2")
	testing.expect_value(t, strings.count(o, ".md:"), 1)
}

// --budget caps the output in tokens, and the bytes printed are logged.
@(test)
find_honours_a_budget_and_logs_bytes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, code := exec(f.cli, "find", "fixture", "--budget", "10")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "output capped"), "a tiny budget caps")
	e: string
	_, e, code = exec(f.cli, "find", "fixture", "--budget", "x")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "--budget <tokens>"), "a bad budget says so")
	o, _, code = exec(f.cli, "find", "fixture")
	testing.expect_value(t, code, 0)
	db, err := open_db(f.cli.db)
	testing.expect_value(t, err, "")
	defer sqlite3.close(&db)
	got := scalar_text(db, "select bytes from queries order by id desc limit 1")
	testing.expect_value(t, got, int_str(i64(len(o))))
}

// A pack leads with the bullets that name the project, points at its newest
// handoff, is served from the cache until the vault changes, and is logged
// with its bytes like a find.
@(test)
pack_briefs_a_project_and_caches_it :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, code := exec(f.cli, "pack", "fixture")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "# brain pack fixture: "), "a header says what this is")
	testing.expect(t, strings.contains(o, "\nAI/MEMORY.md:"), "then a terse bullet line")
	testing.expect(t, strings.contains(o, " **fixture tool** — "), "the alias names fixture tool")
	testing.expect(t, !strings.contains(o, "(aliases:"), "terse")
	testing.expect(t, strings.contains(o, "handoff: AI/handoffs/2026-01-01-fixture.md\n"), "the newest handoff is named")
	cache := path.join(f.state, "packs", "fixture-1500.txt")
	testing.expect(t, os.is_file(cache), "the pack is cached")
	db, err := open_db(f.cli.db)
	testing.expect_value(t, err, "")
	got := scalar_text(db, "select q || ' ' || bytes from queries order by id desc limit 1")
	sqlite3.close(&db)
	testing.expect_value(t, got, strings.concatenate({"pack fixture ", int_str(i64(len(o)))}))

	// A cache carrying the index's build stamp is served as it is; a sync
	// writes a new stamp and the next pack is built again.
	db, err = open_db(f.cli.db)
	testing.expect_value(t, err, "")
	built := scalar_text(db, "select value from meta where key='built'")
	sqlite3.close(&db)
	planted := "AI/MEMORY.md:1 **planted** — a line only the cache holds — 2026-01-01\n"
	testing.expect_value(t, path.write(cache, strings.concatenate({"built ", built, "\n", planted})), nil)
	o2, _, _ := exec(f.cli, "pack", "fixture")
	testing.expect_value(t, o2, planted)
	testing.expect_value(t, path.append_file(path.join(f.vault, "AI", "MEMORY.md"), "- **fixture pack** (aliases: fixture) — a bullet added after the pack was cached — fixture — 2026-01-03\n"), nil)
	_, _, code = exec(f.cli, "sync")
	testing.expect_value(t, code, 0)
	o3, _, _ := exec(f.cli, "pack", "fixture")
	testing.expect(t, strings.contains(o3, "**fixture pack**"), "a sync invalidates the cache")

	e: string
	o, e, code = exec(f.cli, "pack", "fixture", "--budget", "1")
	testing.expect_value(t, code, 1)
	testing.expect_value(t, o, "")
	testing.expect(t, strings.has_prefix(e, "no bullets for: fixture"), "a budget too small for one line says so, on stderr")
	_, _, code = exec(f.cli, "pack", "zzzznope")
	testing.expect_value(t, code, 1)
}

// With no project named, pack takes the repository the caller is in: the
// nearest .git above the working directory.
@(test)
pack_infers_the_project_from_the_working_directory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	repo := path.join(f.root, "sqlite")
	testing.expect_value(t, path.mkdirs(path.join(repo, ".git")), nil)
	testing.expect_value(t, path.mkdirs(path.join(repo, "src", "deep")), nil)
	f.cli.env["PWD"] = path.join(repo, "src", "deep")
	o, _, code := exec(f.cli, "pack")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "# brain pack sqlite: "), "a pack for the repo")
	testing.expect(t, strings.contains(o, " **sqlite** — "), "named after the repo")
	db, err := open_db(f.cli.db)
	testing.expect_value(t, err, "")
	defer sqlite3.close(&db)
	testing.expect_value(t, scalar_text(db, "select q from queries order by id desc limit 1"), "pack sqlite")
	// No .git above: the working directory's own name.
	f.cli.env["PWD"] = path.join(f.root, "fixture")
	testing.expect_value(t, path.mkdirs(path.join(f.root, "fixture")), nil)
	_, _, code = exec(f.cli, "pack")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, scalar_text(db, "select q from queries order by id desc limit 1"), "pack fixture")
}

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
	testing.expect_value(t, o, "indexed 4 bullets, 0 links, 4 files\n")
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
	testing.expect(t, os.is_file(path.join(strings.trim_space(o), "bin", "synonyms.tsv")), "--tool names the checkout")
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

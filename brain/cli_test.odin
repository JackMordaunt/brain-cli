package brain

import "core:os"
import "core:strings"
import "core:testing"

import "jm:path"
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


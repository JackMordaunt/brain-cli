package brain

import "core:encoding/json"
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
	testing.expect(t, strings.has_prefix(o, "nothing in the vault for: zzzznope"), "a miss says so")
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

// A proposal is completed, queued in the inbox, invisible to find until a
// person approves it into a core file, and gone once dropped.
@(test)
propose_queues_and_inbox_approves :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.env["BRAIN_CALLER"] = "fixture-agent"
	o, _, code := exec(f.cli, "propose", "- **new thing** (aliases: nt) — a fact an agent learned")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "proposed #1 **new thing**"), o)
	inbox, _ := path.read(path.join(f.vault, INBOX_FILE))
	testing.expect(t, strings.contains(inbox, "— a fact an agent learned — fixture-agent — "), "source filled in")
	tail := strings.trim_space(inbox)
	testing.expect(t, len(tail) > 10 && tail[len(tail) - 10:] == today_iso() && is_iso_date(today_iso()), "today's date filled in")
	_, _, code = exec(f.cli, "find", "new", "thing")
	testing.expect_value(t, code, 1)
	o, _, code = exec(f.cli, "propose", "- **new thing** — again")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "already proposed as #1"), o)
	e: string
	_, e, code = exec(f.cli, "propose", "not a bullet")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "not a bullet"), e)
	_, _, code = exec(f.cli, "propose", "- **second** — another — someone — 2026-01-05")
	testing.expect_value(t, code, 0)
	o, _, code = exec(f.cli, "inbox")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "#1 - **new thing**") && strings.contains(o, "\n#2 - **second**"), o)
	o, _, code = exec(f.cli, "inbox", "approve", "1", "--to", "LEARNINGS")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "approved #1 **new thing** -> AI/LEARNINGS.md"), o)
	learn, _ := path.read(path.join(f.vault, "AI", "LEARNINGS.md"))
	testing.expect(t, strings.contains(learn, "- **new thing** (aliases: nt) — a fact an agent learned — fixture-agent — "), "moved")
	o, _, code = exec(f.cli, "find", "new", "thing")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "**new thing**"), "findable once approved")
	o, _, code = exec(f.cli, "inbox", "drop", "1")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "dropped #1 **second**"), o)
	o, _, _ = exec(f.cli, "inbox")
	testing.expect_value(t, o, "inbox empty\n")
	_, _, code = exec(f.cli, "inbox", "approve", "1")
	testing.expect_value(t, code, 1)
}

// The MCP server answers initialize, lists its tools, runs a tool as the
// command it stands for, ignores notifications and refuses what it does
// not know.
@(test)
mcp_serves_the_commands_as_tools :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	client := "mcp"
	r := mcp_handle(f.cli, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"fixture-client"}}}`, &client, "s1")
	testing.expect(t, strings.has_prefix(r, `{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"`), r)
	testing.expect_value(t, client, "fixture-client")
	testing.expect_value(t, mcp_handle(f.cli, `{"jsonrpc":"2.0","method":"notifications/initialized"}`, &client, "s1"), "")
	r = mcp_handle(f.cli, `{"jsonrpc":"2.0","id":"a","method":"tools/list"}`, &client, "s1")
	testing.expect(t, strings.has_prefix(r, `{"jsonrpc":"2.0","id":"a","result":{"tools":[`), r)
	testing.expect(t, strings.contains(r, `"name":"propose"`), "propose is a tool")
	r = mcp_handle(f.cli, `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"find","arguments":{"terms":"sqlite","budget":200}}}`, &client, "s1")
	testing.expect(t, strings.has_prefix(r, `{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"AI/MEMORY.md:`), r)
	testing.expect(t, strings.contains(r, `**sqlite**`) && strings.has_suffix(r, `"isError":false}}`), r)
	testing.expect(t, !strings.contains(r, "(aliases:"), "an mcp caller is an agent: terse")
	db, err := open_db(f.cli.db)
	testing.expect_value(t, err, "")
	testing.expect_value(t, scalar_text(db, "select caller || ' ' || session from queries order by id desc limit 1"), "mcp:fixture-client s1")
	sqlite3.close(&db)
	r = mcp_handle(f.cli, `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"find","arguments":{"terms":"zzzznope"}}}`, &client, "s1")
	testing.expect(t, strings.has_suffix(r, `"isError":true}}`), r)
	r = mcp_handle(f.cli, `{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope","arguments":{}}}`, &client, "s1")
	testing.expect(t, strings.contains(r, `"error":{"code":-32602`), r)
	r = mcp_handle(f.cli, `{"jsonrpc":"2.0","id":5,"method":"resources/list"}`, &client, "s1")
	testing.expect(t, strings.contains(r, `"error":{"code":-32601`), r)
	r = mcp_handle(f.cli, `not json`, &client, "s1")
	testing.expect(t, strings.contains(r, `"id":null,"error":{"code":-32700`), r)
	r = mcp_handle(f.cli, `{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"propose","arguments":{"bullet":"- **via mcp** — a \"quoted\" fact"}}}`, &client, "s1")
	testing.expect(t, strings.contains(r, `proposed #1 **via mcp**`), r)
	inbox, _ := path.read(path.join(f.vault, INBOX_FILE))
	testing.expect(t, strings.contains(inbox, `a "quoted" fact — mcp:fixture-client — `), inbox)
}

// Export writes the repository's pack into each agent's file: a managed
// block in a shared file, the whole file where the file is brain's, with
// the frontmatter that agent expects; a second run changes nothing.
@(test)
export_writes_each_agents_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	repo := path.join(f.root, "sqlite")
	testing.expect_value(t, path.mkdirs(path.join(repo, ".git")), nil)
	testing.expect_value(t, path.write(path.join(repo, "CLAUDE.md"), "# My repo\n\nKeep this.\n"), nil)
	f.cli.env["PWD"] = repo
	o, _, code := exec(f.cli, "export", "claude", "codex", "cursor", "kiro")
	testing.expect_value(t, code, 0)
	claude, _ := path.read(path.join(repo, "CLAUDE.md"))
	testing.expect(t, strings.has_prefix(claude, "<!-- brain:memory >>> managed by `brain export`"), claude)
	testing.expect(t, strings.contains(claude, "\n# brain pack sqlite: ") && strings.contains(claude, " **sqlite** — "), "the pack is the block")
	testing.expect(t, strings.has_suffix(claude, "brain:memory <<< -->\n\n# My repo\n\nKeep this.\n"), "the file's own text follows")
	agents, _ := path.read(path.join(repo, "AGENTS.md"))
	testing.expect(t, strings.contains(agents, "brain:memory >>>") && strings.contains(agents, "**sqlite**"), "codex is AGENTS.md")
	cursor, _ := path.read(path.join(repo, ".cursor", "rules", "brain.mdc"))
	testing.expect(t, strings.has_prefix(cursor, "---\ndescription: ") && strings.contains(cursor, "\nalwaysApply: true\n---\n# brain pack sqlite"), cursor)
	kiro, _ := path.read(path.join(repo, ".kiro", "steering", "brain.md"))
	testing.expect(t, strings.has_prefix(kiro, "---\ninclusion: always\n---\n# brain pack sqlite"), kiro)
	testing.expect(t, !strings.contains(cursor, "brain:memory"), "an owned file has no block markers")
	o, _, code = exec(f.cli, "export", "claude", "cursor")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, strings.count(o, "already current"), 2)
	e: string
	_, e, code = exec(f.cli, "export", "emacs")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "unknown agent: emacs") && strings.contains(e, "kiro"), e)
	_, _, code = exec(f.cli, "export", "--all")
	testing.expect_value(t, code, 0)
	for rel in ([2]string{".github/copilot-instructions.md", "GEMINI.md"}) {
		text, _ := path.read(path.join(repo, rel))
		testing.expect(t, strings.contains(text, "brain:memory >>>") && strings.contains(text, "**sqlite**"), rel)
	}
	cline, _ := path.read(path.join(repo, ".clinerules", "brain.md"))
	testing.expect(t, strings.has_prefix(cline, "# brain pack sqlite"), cline)
}

// Import proposes what Claude Code remembered on its own, one bullet per
// memory with the memory file's body as the fact, and reads any other
// markdown list as proposals with the first words as handles.
@(test)
import_proposes_claude_memories_and_lists :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	repo := path.join(f.root, "sqlite")
	testing.expect_value(t, path.mkdirs(path.join(repo, ".git")), nil)
	f.cli.env["PWD"] = repo
	mem := path.join(f.home, ".claude", "projects", claude_slug(repo), "memory")
	testing.expect_value(t, path.mkdirs(mem), nil)
	testing.expect_value(t, path.write(path.join(mem, "MEMORY.md"), "- [Canonical remote](canonical-remote.md) — the hook\n- [Loose](nowhere.md) — just the hook\nnot a memory\n"), nil)
	testing.expect_value(t, path.write(path.join(mem, "canonical-remote.md"), "---\nname: canonical-remote\ndescription: d\nmetadata:\n  type: user\n---\n\nUse the forge\nfor remotes.\n"), nil)
	o, _, code := exec(f.cli, "import", "claude")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "2 proposal(s) from 2 memories"), o)
	inbox, _ := path.read(path.join(f.vault, INBOX_FILE))
	testing.expect(t, strings.contains(inbox, "- **Canonical remote** — Use the forge for remotes. — claude memory (user) — "), inbox)
	testing.expect(t, strings.contains(inbox, "- **Loose** — just the hook — claude memory — "), inbox)
	list := path.join(f.root, "notes.md")
	testing.expect_value(t, path.write(list, "# Notes\n\n- the build needs the jm submodule checked out.\n* second one\n- **kept** (aliases: k) — as it is\n"), nil)
	o, _, code = exec(f.cli, "import", list)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "3 proposal(s) from 3 memories"), o)
	inbox, _ = path.read(path.join(f.vault, INBOX_FILE))
	testing.expect(t, strings.contains(inbox, "- **the build needs the jm** — the build needs the jm submodule checked out. — imported from notes.md — "), inbox)
	testing.expect(t, strings.contains(inbox, "- **second one** — second one — imported from notes.md — "), inbox)
	testing.expect(t, strings.contains(inbox, "- **kept** (aliases: k) — as it is — imported from notes.md — "), inbox)
	e: string
	_, e, code = exec(f.cli, "import", path.join(f.root, "missing.md"))
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "cannot read"), e)
}

// Every state command answers --json with one parseable object whose first
// key names what it is, and an error under --json is an object too.
@(test)
every_state_command_speaks_json :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	repo := path.join(f.root, "sqlite")
	testing.expect_value(t, path.mkdirs(path.join(repo, ".git")), nil)
	f.cli.env["PWD"] = repo
	f.cli.env["BRAIN_CALLER"] = "fixture-agent"
	f.cli.env["BRAIN_SESSION"] = "sess-j"
	// command, the key its object leads with, and that key's value: a quoted
	// string, true, "array", or "number" for a count above zero.
	cases := [?][3]string {
		{"locate", "vault", strings.concatenate({"\"", f.vault, "\""})},
		{"version", "version", "\"dev\""},
		{"reindex", "bullets", "number"},
		{"find sqlite", "query", "\"sqlite\""},
		{"pack", "project", "\"sqlite\""},
		{"propose - **json thing** — a fact", "status", "\"proposed\""},
		{"inbox", "proposals", "array"},
		{"inbox approve 1", "action", "\"approved\""},
		{"export claude cursor", "project", "\"sqlite\""},
		{"doctor", "queries_logged", "number"},
		{"log", "backlog", "array"},
		{"ledger", "baseline_bytes", "number"},
		{"lint", "ok", "true"},
	}
	for c in cases {
		args := strings.split(c[0], " ")
		append_args := make([dynamic]string)
		append(&append_args, "--json")
		for a in args {
			append(&append_args, a)
		}
		o, e, _ := exec(f.cli, ..append_args[:])
		testing.expect_value(t, e, "")
		v, perr := json.parse_string(o)
		testing.expect(t, perr == nil, strings.concatenate({c[0], ": ", o}))
		obj, ok := v.(json.Object)
		testing.expect(t, ok, c[0])
		val, has := obj[c[1]]
		testing.expect(t, has, strings.concatenate({c[0], " has ", c[1], ": ", o}))
		right := false
		switch c[2] {
		case "array":
			_, right = val.(json.Array)
		case "number":
			#partial switch n in val {
			case json.Integer:
				right = n > 0
			case json.Float:
				right = n > 0
			}
		case "true":
			b, is_bool := val.(json.Boolean)
			right = is_bool && bool(b)
		case:
			s, is_str := val.(json.String)
			right = is_str && strings.concatenate({"\"", string(s), "\""}) == c[2]
		}
		testing.expect(t, right, strings.concatenate({c[0], ": ", c[1], " should be ", c[2], ": ", o}))
	}
	o, e, code := exec(f.cli, "find", "sqlite", "--json")
	testing.expect(t, strings.contains(o, `"hits":[{"file":"AI/MEMORY.md","line":`) && strings.contains(o, `"handle":"sqlite"`), o)
	o, _, code = exec(f.cli, "--json", "find", "zzzznope")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.has_prefix(o, `{"query":"zzzznope","hits":[],`), o)
	o, e, code = exec(f.cli, "--json", "export", "emacs")
	testing.expect_value(t, code, 1)
	testing.expect_value(t, e, "")
	testing.expect(t, strings.has_prefix(o, `{"error":"unknown agent: emacs`), o)
	o, _, _ = exec(f.cli, "--json", "ledger")
	testing.expect(t, strings.contains(o, `"callers":[{"caller":"fixture-agent"`) && strings.contains(o, `"tokens_saved":`), o)
}

// The ledger credits an answered lookup with the core files' size less what
// it printed, and a miss with only its own cost.
@(test)
ledger_counts_tokens_against_the_core_files :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.env["BRAIN_CALLER"] = "fixture-agent"
	f.cli.env["BRAIN_SESSION"] = "sess-l"
	o, _, _ := exec(f.cli, "find", "sqlite")
	returned := len(o)
	exec(f.cli, "find", "zzzznope")
	baseline := core_bytes(f.cli)
	testing.expect(t, baseline > returned, "the core files outweigh one answer")
	code: int
	o, _, code = exec(f.cli, "ledger", "--days", "7")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "Tokens are bytes over four."), o)
	testing.expect(t, strings.contains(o, "== by caller ==") && strings.contains(o, "fixture-agent") && strings.contains(o, "== last 7 days =="), o)
	o, _, _ = exec(f.cli, "ledger", "--json")
	want := strings.concatenate({`{"caller":"fixture-agent","sessions":1,"lookups":2,"answered":1,"tokens_returned":`, int_str(i64(returned / 4)), `,"tokens_saved":`, int_str(i64((baseline - returned) / 4)), `}`})
	testing.expect(t, strings.contains(o, want), strings.concatenate({want, "\n", o}))
}

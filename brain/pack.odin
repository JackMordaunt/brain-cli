package brain

import "core:os"
import "core:strconv"
import "core:strings"

import "jm:path"
import "jm:sqlite3"

// A pack is the briefing an agent opens a project with: the bullets that
// name or mention it, terse, within a token budget, then a pointer to the
// project's newest handoff and its state folder in the vault. It replaces
// the first lookups of every session with one read at the start of context,
// where a host's prompt cache can hold it. The pack is cached under the
// state directory against the index's build stamp, so a session hook can
// ask for it every time and only pay after the vault changes.

PACK_BUDGET :: 1500 // tokens
PACK_LIMIT  :: 64 // bullets considered before the budget is filled

cmd_pack :: proc(cli: ^Cli, args: []string) -> int {
	// A session opens with what other machines wrote since: a receive started
	// in the background, so the session is never held for the network; what
	// arrives reaches the agent through prime on the next prompt.
	sync_in_background(cli, .Receive)
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	budget := PACK_BUDGET * 4
	fresh := false
	terms := make([dynamic]string)
	rest := args
	for len(rest) > 0 {
		arg := rest[0]
		rest = rest[1:]
		switch arg {
		case "--fresh":
			fresh = true
		case "--budget":
			n, ok := 0, false
			if len(rest) > 0 {
				n, ok = strconv.parse_int(rest[0])
				rest = rest[1:]
			}
			if !ok || n <= 0 {
				return fail(cli, "usage: brain pack --budget <tokens>")
			}
			budget = n * 4
		case:
			append(&terms, arg)
		}
	}
	if len(terms) == 0 {
		_, name := repo_here(cli)
		append(&terms, name)
	}
	db, oerr := open_db(cli.db)
	if oerr != "" {
		return fail(cli, oerr)
	}
	defer sqlite3.close(&db)

	project := strings.join(terms[:], " ")
	slug := strings.join(query_terms(project), "-")
	built := scalar_text(db, "select value from meta where key='built'")
	cache := path.join(cli.state, "packs", strings.concatenate({slug, "-", int_str(i64(budget / 4)), ".txt"}))
	stamp := strings.concatenate({"built ", built, "\n"})

	if cli.json {
		p := select_pack(db, project, slug, budget)
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "project", project)
		jw_key(&w, "bullets")
		jw_arr(&w)
		for h in p.hits {
			jw_hit(&w, h)
		}
		jw_end_arr(&w)
		jw_field(&w, "handoff", p.handoff)
		jw_field_int(&w, "state_files", i64(p.state))
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return len(p.hits) > 0 ? 0 : 1
	}
	body := ""
	cached := false
	if !fresh {
		if c, rerr := path.read(cache); rerr == nil && strings.has_prefix(c, stamp) {
			body = c[len(stamp):]
			cached = true
		}
	}
	if body == "" {
		body = build_pack(db, project, slug, budget)
		path.mkdirs(path.dir(cache))
		path.write(cache, strings.concatenate({stamp, body}))
	}
	_ = cached
	// The served handles are logged with the query, so a prime in the same
	// session does not repeat the pack.
	served := make([dynamic]Hit)
	for line in strings.split_lines(body) {
		if strings.contains(line, ".md:") && !strings.has_prefix(line, "handoff:") {
			h := Hit{file = line[:strings.index(line, ":")]}
			if handle, found := between(line, "**", "**"); found {
				h.handle = handle
			}
			append(&served, h)
		}
	}
	n := len(served)
	log_query(db, strings.concatenate({"pack ", project}), served[:], caller_id(cli), session_id(cli), len(body))
	if n == 0 {
		errf(cli, "no bullets for: %s\n", project)
		return 1
	}
	out(cli, body)
	return 0
}

// repo_here is the repository the caller is in: the nearest directory, from
// the working directory up, that holds a .git, else the working directory
// itself; and its name. PWD is read first so a hook, or a test, can say
// where it is.
repo_here :: proc(cli: ^Cli) -> (root, name: string) {
	cwd := getenv(cli, "PWD")
	if cwd == "" {
		cwd, _ = os.get_working_directory(context.allocator)
	}
	start, _ := path.clean(cwd)
	d := start
	for {
		if os.exists(path.join(d, ".git")) {
			return d, path.base(d)
		}
		parent := path.dir(d)
		if parent == d || parent == "" {
			break
		}
		d = parent
	}
	return start, path.base(start)
}

// Pack is what a project's briefing holds: its bullets in order, within the
// budget, and where the longer state is.
Pack :: struct {
	hits:    []Hit,
	handoff: string,
	state:   int, // files in the project's state folder
}

// select_pack chooses the pack. Bullets whose handle or alias is the project
// come first, then the rest by score; each is one terse line until the
// budget is spent.
select_pack :: proc(db: sqlite3.Db, project, slug: string, budget: int) -> (p: Pack) {
	m, ok := build_match(db, project)
	if !ok {
		return
	}
	hits := query_fts(db, m.and, PACK_LIMIT)
	if len(hits) == 0 {
		hits = query_fts(db, m.or, PACK_LIMIT)
	}
	q := strings.join(query_terms(project), " ")
	ordered := make([dynamic]Hit)
	for h in hits {
		if names(h, q) {
			append(&ordered, h)
		}
	}
	for h in hits {
		if !names(h, q) {
			append(&ordered, h)
		}
	}
	kept := make([dynamic]Hit)
	written := 0
	for h in ordered {
		line := format_hit(h, .Terse)
		if written + len(line) > budget {
			break
		}
		append(&kept, h)
		written += len(line)
	}
	p.hits = kept[:]
	if len(p.hits) == 0 {
		return
	}
	p.handoff = scalar_text(
		db,
		"select file from docs where file like '%handoffs/%' and file like ? order by file desc limit 1",
		strings.concatenate({"%", slug, "%"}),
	)
	p.state = scalar_int(db, "select count(*) from docs where file like ?", strings.concatenate({slug, "/%"}))
	return
}

// build_pack renders the pack as text: a header, one terse line per bullet,
// then the pointers, which are outside the budget: two short lines that say
// where the longer state is.
build_pack :: proc(db: sqlite3.Db, project, slug: string, budget: int) -> string {
	p := select_pack(db, project, slug, budget)
	if len(p.hits) == 0 {
		return ""
	}
	b := strings.builder_make()
	strings.write_string(&b, strings.concatenate({"# brain pack ", project, ": what the vault knows; `brain find <terms>` for more\n"}))
	for h in p.hits {
		strings.write_string(&b, format_hit(h, .Terse))
	}
	if p.handoff != "" {
		strings.write_string(&b, strings.concatenate({"handoff: ", p.handoff, "\n"}))
	}
	if p.state > 0 {
		strings.write_string(&b, strings.concatenate({"state: ", slug, "/ (", int_str(i64(p.state)), " files)\n"}))
	}
	return strings.to_string(b)
}

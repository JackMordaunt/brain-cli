package brain

import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import "jm:path"
import "jm:sqlite3"

// Memory that happens without the agent asking for it. `brain prime` runs
// as a UserPromptSubmit hook: it reads the prompt from the hook's JSON on
// stdin, finds the bullets that answer it, and prints them, which Claude
// Code adds beside the prompt. A bullet already served to the session,
// by prime or by the pack, is not served again. `brain settle` runs as a
// Stop hook: once per session, when work happened and nothing was
// proposed, it asks the model to propose what the session settled, with
// the corrections the session holds, and then lets it stop.

PRIME_BUDGET :: 600 // tokens per prompt
PRIME_TERMS :: 12 // query terms taken from a prompt
PRIME_OR_LIMIT :: 40 // bullets considered when no bullet holds every term
PRIME_DOC_LIMIT :: 25 // note lines considered when none holds every term
PRIME_DOCS :: 5 // note lines served at most
PRIME_HEAD :: "# brain: what the vault knows about this prompt; `brain find <terms>` for more, the files are under `brain locate`\n"
PRIME_HINT :: "# brain: nothing in the vault names this prompt; `brain find <terms>` searches it, `brain recall <terms>` past conversations\n"

SETTLE_MIN_TURNS :: 6 // assistant turns before a session is worth settling
SETTLE_CORRECTIONS :: 5 // corrections quoted back at most

// Words a prompt is full of that name nothing in a vault.
PRIME_STOP :: [?]string {
	"the", "and", "for", "with", "that", "this", "from", "what", "how", "can", "you", "your", "are",
	"was", "were", "will", "would", "should", "could", "have", "has", "had", "not", "but", "all",
	"any", "into", "out", "about", "when", "where", "which", "who", "why", "does", "did", "just",
	"like", "make", "need", "want", "use", "using", "please", "let's", "lets", "then", "than", "them",
	"they", "there", "their", "here", "also", "some", "more", "most", "our", "its", "it's", "get",
	"got", "see", "run", "add", "now", "one", "two", "way", "thing", "things", "don't", "dont",
	"i'm", "i'll", "i've", "we're", "we've", "me", "my", "mine", "do", "so", "if", "in", "on", "at",
	"to", "of", "is", "it", "be", "as", "by", "or", "an", "a", "up", "no", "yes", "ok", "okay",
	"something", "anything", "everything", "think", "know", "look", "give", "show", "tell", "find",
	"write", "read", "change", "fix", "check", "work", "working", "works", "still", "again", "same",
	"new", "old", "first", "last", "next", "other", "each", "every", "much", "many", "very", "really",
	"say", "says", "said", "list", "lists", "name", "names", "plan", "plans", "handle", "through",
	"should", "mean", "means", "approach", "approaches", "kind", "sort", "part", "between",
}

cmd_prime :: proc(cli: ^Cli, args: []string) -> int {
	usage := "usage: brain prime [--budget <tokens>] [--harness <name>] [--session <id>] [<prompt...>]"
	budget := PRIME_BUDGET * 4
	harness := ""
	flags: Hook_Event
	words := make([dynamic]string)
	rest := args
	for len(rest) > 0 {
		arg := rest[0]
		rest = rest[1:]
		switch arg {
		case "--budget":
			n, ok := 0, false
			if len(rest) > 0 {
				n, ok = strconv.parse_int(rest[0])
				rest = rest[1:]
			}
			if !ok || n <= 0 {
				return fail(cli, usage)
			}
			budget = n * 4
		case "--harness", "--session", "--cwd":
			if len(rest) == 0 {
				return fail(cli, usage)
			}
			switch arg {
			case "--harness":
				harness = rest[0]
			case "--session":
				flags.session = rest[0]
			case "--cwd":
				flags.cwd = rest[0]
			}
			rest = rest[1:]
		case "--":
			append(&words, ..rest)
			rest = nil
		case:
			append(&words, arg)
		}
	}
	flags.prompt = strings.join(words[:], " ")
	ev, h, got := hook_event(cli, .Prompt, flags, harness)
	if !got {
		return 0
	}
	caller := caller_id(cli)
	if caller == "" {
		caller = h.name
	}
	session := ev.session
	terms := prime_terms(ev.prompt)
	if len(terms) == 0 {
		return 0
	}
	// A vault that is not there yet is not an error a hook should raise.
	if err := ensure_db(cli); err != "" {
		return 0
	}
	db, oerr := open_db(cli.db)
	if oerr != "" {
		return 0
	}
	defer sqlite3.close(&db)
	raw := strings.join(terms, " ")
	m, ok := build_match(db, raw)
	if !ok {
		return 0
	}
	// A prompt is a sentence, not a query: a bullet rarely holds every word
	// of it. When none does, the bullets holding enough of them answer,
	// most covered first, so one shared word like git brings nothing.
	hits := query_fts(db, m.and)
	if len(hits) == 0 {
		hits = covered(query_fts(db, m.or, PRIME_OR_LIMIT), terms)
	}
	hits, _ = cut_to_exact(hits, raw)
	found := len(hits) > 0
	if session != "" {
		hits = unserved(db, hits, session)
	}
	// A fact that lives only in a note, a plan or a handoff, follows the
	// bullets the way find prints it: the lines holding every term, else
	// the ones holding enough of them, most covered first.
	docs := query_lines(db, m.prose_and)
	if len(docs) == 0 {
		docs = covered_docs(query_lines(db, m.prose_or, PRIME_DOC_LIMIT), terms)
	}
	if session != "" {
		docs = unserved_docs(db, docs, session)
	}
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "terms", raw)
		jw_key(&w, "hits")
		jw_arr(&w)
		for h in hits {
			jw_hit(&w, h)
		}
		jw_end_arr(&w)
		jw_key(&w, "documents")
		jw_arr(&w)
		for d in docs {
			jw_obj(&w)
			jw_field(&w, "locator", d.locator)
			jw_field(&w, "text", d.text)
			jw_end_obj(&w)
		}
		jw_end_arr(&w)
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	if len(hits) == 0 && len(docs) == 0 {
		// Once a session, a prompt that found nothing says that brain is
		// there to ask, since no instruction may name it. A hit already
		// served is not nothing.
		if !found && session != "" && scalar_int(db, "select count(*) from queries where session=? and q like 'prime %'", session) == 0 {
			log_query(db, strings.concatenate({"prime ", raw}), nil, caller, session, len(PRIME_HINT))
			out(cli, PRIME_HINT)
		}
		return 0
	}
	// Only what is printed is logged as served, so the budget's cut is
	// served next time.
	b := strings.builder_make()
	strings.write_string(&b, PRIME_HEAD)
	kept := make([dynamic]Hit)
	for h in hits {
		line := format_hit(h, .Terse)
		if strings.builder_len(b) + len(line) > budget {
			break
		}
		strings.write_string(&b, line)
		append(&kept, h)
	}
	if len(docs) > 0 {
		for d, i in docs {
			line := strings.concatenate({rune_prefix(strings.concatenate({d.locator, "  ", d.text}), 220), "\n"})
			head := i == 0 ? len(NOTES_HEAD) : 0
			if strings.builder_len(b) + head + len(line) > budget {
				break
			}
			if i == 0 {
				strings.write_string(&b, NOTES_HEAD)
			}
			strings.write_string(&b, line)
			// A served line is logged by its locator, so it too is served
			// once a session.
			file, _, _ := strings.partition(d.locator, ":")
			append(&kept, Hit{file = file, handle = d.locator})
		}
	}
	if len(kept) == 0 {
		return 0
	}
	log_query(db, strings.concatenate({"prime ", raw}), kept[:], caller, session, strings.builder_len(b))
	out(cli, strings.to_string(b))
	return 0
}

// prime_terms is what a prompt asks about: its words less the ones that
// carry nothing, pasted text set aside, the first PRIME_TERMS kept.
prime_terms :: proc(prompt: string) -> []string {
	text := without_pasted(prompt)
	terms := make([dynamic]string)
	seen := make(map[string]bool)
	stop := PRIME_STOP
	outer: for t in query_terms(text) {
		if len(t) < 3 || seen[t] {
			continue
		}
		for s in stop {
			if t == s {
				continue outer
			}
		}
		seen[t] = true
		append(&terms, t)
		if len(terms) == PRIME_TERMS {
			break
		}
	}
	return terms[:]
}

// without_pasted drops the <pasted_content ...>…</pasted_content ...>
// blocks a prompt may carry (code.claude.com/docs/en/hooks, "UserPromptSubmit
// input": pasted text arrives expanded between those two lines), so a
// pasted log does not drive the query.
without_pasted :: proc(prompt: string) -> string {
	b := strings.builder_make()
	rest := prompt
	for {
		i := strings.index(rest, "<pasted_content")
		if i < 0 {
			strings.write_string(&b, rest)
			break
		}
		strings.write_string(&b, rest[:i])
		j := strings.index(rest[i:], "</pasted_content")
		if j < 0 {
			break
		}
		after := rest[i + j:]
		k := strings.index_byte(after, '>')
		if k < 0 {
			break
		}
		rest = after[k + 1:]
	}
	return strings.to_string(b)
}

// covered keeps the hits that hold enough of the terms, and orders them by
// how many they hold, bm25 breaking ties. A short prompt is specific and
// one term is enough; a sentence needs a third of its terms and at least
// two. A term counts when the handle, an alias or the fact contains it.
covered :: proc(hits: []Hit, terms: []string) -> []Hit {
	need := len(terms) <= 3 ? 1 : max(2, (len(terms) + 2) / 3)
	Scored :: struct {
		hit:   Hit,
		count: int,
	}
	kept := make([dynamic]Scored)
	for h in hits {
		text := strings.to_lower(strings.concatenate({h.handle, " ", h.aliases, " ", h.fact}))
		n := 0
		for t in terms {
			if strings.contains(text, t) {
				n += 1
			}
		}
		if n >= need {
			append(&kept, Scored{hit = h, count = n})
		}
	}
	slice.sort_by(kept[:], proc(a, b: Scored) -> bool {
		if a.count != b.count {
			return a.count > b.count
		}
		return a.hit.score < b.hit.score
	})
	ordered := make([]Hit, len(kept))
	for k, i in kept {
		ordered[i] = k.hit
	}
	return ordered
}

// covered_docs is covered for note lines: the ones holding enough of the
// terms, most covered first, PRIME_DOCS at most. A line is a snapshot,
// so it needs two terms however short the prompt; and a line is one
// wrapped line of a paragraph, so a quarter of a long prompt is enough.
covered_docs :: proc(docs: []Doc, terms: []string) -> []Doc {
	need := min(len(terms), max(2, (len(terms) + 3) / 4))
	Scored :: struct {
		doc:   Doc,
		count: int,
		order: int,
	}
	kept := make([dynamic]Scored)
	for d, i in docs {
		text := strings.to_lower(d.text)
		n := 0
		for t in terms {
			if strings.contains(text, t) {
				n += 1
			}
		}
		if n >= need {
			append(&kept, Scored{doc = d, count = n, order = i})
		}
	}
	slice.sort_by(kept[:], proc(a, b: Scored) -> bool {
		if a.count != b.count {
			return a.count > b.count
		}
		return a.order < b.order
	})
	ordered := make([dynamic]Doc)
	for k in kept {
		if len(ordered) == PRIME_DOCS {
			break
		}
		append(&ordered, k.doc)
	}
	return ordered[:]
}

// served_keys is everything this session was already given, by prime,
// pack or find: bullets by handle, note lines by locator.
served_keys :: proc(db: sqlite3.Db, session: string) -> map[string]bool {
	served := make(map[string]bool)
	for h in column_texts(db, "select distinct h.handle from query_hits h join queries q on q.id = h.query_id where q.session = ?", session) {
		served[strings.clone(h)] = true
	}
	return served
}

// unserved is hits less the ones this session was already given.
unserved :: proc(db: sqlite3.Db, hits: []Hit, session: string) -> []Hit {
	served := served_keys(db, session)
	kept := make([dynamic]Hit)
	for h in hits {
		if !served[h.handle] {
			append(&kept, h)
		}
	}
	return kept[:]
}

// unserved_docs is docs less the lines this session was already given.
unserved_docs :: proc(db: sqlite3.Db, docs: []Doc, session: string) -> []Doc {
	served := served_keys(db, session)
	kept := make([dynamic]Doc)
	for d in docs {
		if !served[d.locator] {
			append(&kept, d)
		}
	}
	return kept[:]
}

// log_query records a lookup and the bullets it served, which is what
// the ledger costs, doctor promotes and unserved reads.
log_query :: proc(db: sqlite3.Db, q: string, hits: []Hit, caller, session: string, bytes: int) {
	sqlite3.exec_args(
		db,
		"insert into queries(ts,q,hits,caller,session,bytes) values(datetime('now'),?,?,?,?,?)",
		q,
		i64(len(hits)),
		caller,
		session,
		i64(bytes),
	)
	qid := sqlite3.last_id(db)
	for h, i in hits {
		sqlite3.exec_args(db, "insert into query_hits(query_id,file,handle,rank) values(?,?,?,?)", qid, h.file, h.handle, i64(i + 1))
	}
}

// ---- settle ---------------------------------------------------------------

cmd_settle :: proc(cli: ^Cli, args: []string) -> int {
	usage := "usage: brain settle [--harness <name>] [--session <id>] [--transcript <file>] [--continuing]"
	harness := ""
	flags: Hook_Event
	rest := args
	for len(rest) > 0 {
		arg := rest[0]
		rest = rest[1:]
		switch arg {
		case "--continuing":
			flags.continuing = true
		case "--harness", "--session", "--transcript", "--cwd":
			if len(rest) == 0 {
				return fail(cli, usage)
			}
			switch arg {
			case "--harness":
				harness = rest[0]
			case "--session":
				flags.session = rest[0]
			case "--transcript":
				flags.transcript = rest[0]
			case "--cwd":
				flags.cwd = rest[0]
			}
			rest = rest[1:]
		case:
			return fail(cli, usage)
		}
	}
	ev, h, ok := hook_event(cli, .Stop, flags, harness)
	if !ok || ev.continuing {
		return 0
	}
	session, transcript := ev.session, ev.transcript
	if session == "" || transcript == "" || !os.is_file(transcript) {
		return 0
	}
	stamp := path.join(cli.state, "settle", session)
	if os.exists(stamp) {
		return 0
	}
	adapter, has := find_adapter(cli, h.transcripts)
	if !has {
		return 0
	}
	turns, worked, proposed := settle_scan(adapter.scan(cli, transcript))
	if turns < SETTLE_MIN_TURNS || !worked || proposed {
		return 0
	}
	path.mkdirs(path.dir(stamp))
	path.write(stamp, "")

	reason := strings.builder_make()
	strings.write_string(
		&reason,
		"brain settle: this session edited files and proposed nothing to memory. For each durable fact it settled (a decision and why, a path, a command that worked, a constraint), run `brain propose '- **handle** (aliases: what a searcher might type) — fact'`. If nothing durable was settled, reply none and stop.",
	)
	if len(adapters_on(cli)) > 0 {
		if db, err := open_recall_db(cli); err == "" {
			defer sqlite3.close(&db)
			recall_sync(cli, db, full = false)
			n := 0
			for m in lesson_moments(db, 2, "", session) {
				if m.kind != "correction" {
					continue
				}
				if n == 0 {
					strings.write_string(&reason, " The user corrected you this session; for each correction that will matter next time, propose a lesson:")
				}
				n += 1
				if n > SETTLE_CORRECTIONS {
					break
				}
				strings.write_string(&reason, strings.concatenate({"\n- ", strings.trim_space(m.user)}))
			}
		}
	}
	out(cli, h.reply(strings.to_string(reason)))
	return 0
}

// settle_scan reads a transcript, as its adapter emits it without the
// title requirement, for what settle decides on: how many times the
// assistant spoke, whether it changed anything (an edit, a write or a
// shell command), and whether it already proposed to memory. Tool names
// are compared in lower case, since harnesses spell them differently.
settle_scan :: proc(tr: Transcript) -> (turns: int, worked, proposed: bool) {
	for t in tr.turns {
		if t.role == "assistant" {
			turns += 1
		}
	}
	for c in tr.tools {
		switch strings.to_lower(c.name) {
		case "edit", "write", "notebookedit", "multiedit":
			worked = true
		case "bash", "powershell":
			worked = true
			if strings.contains(c.input, "brain propose") {
				proposed = true
			}
		}
	}
	return
}

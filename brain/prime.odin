package brain

import "core:encoding/json"
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

PRIME_BUDGET :: 400 // tokens per prompt
PRIME_TERMS :: 12 // query terms taken from a prompt
PRIME_OR_LIMIT :: 40 // bullets considered when no bullet holds every term
PRIME_HEAD :: "# brain: what the vault knows about this prompt; `brain find <terms>` for more\n"

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
}

// wants_stdin says whether a command line reads the hook's JSON: settle
// always, prime only when no prompt word was given as an argument.
wants_stdin :: proc(args: []string) -> bool {
	switch args[0] {
	case "settle":
		return true
	case "prime":
		skip := false
		for a in args[1:] {
			if skip {
				skip = false
				continue
			}
			if a == "--budget" {
				skip = true
				continue
			}
			if !strings.has_prefix(a, "-") {
				return false
			}
		}
		return true
	}
	return false
}

// read_stdin is what the hook handed over, or what a test set.
read_stdin :: proc(cli: ^Cli) -> string {
	if cli.has_stdin {
		return cli.stdin
	}
	b := strings.builder_make()
	buf: [16384]byte
	for {
		n, err := os.read(os.stdin, buf[:])
		if n > 0 {
			strings.write_bytes(&b, buf[:n])
		}
		if err != nil || n == 0 {
			break
		}
	}
	return strings.to_string(b)
}

// hook_input is the JSON a hook gets on stdin, or nothing when stdin
// was not JSON, in which case a caller typed the prompt itself.
hook_input :: proc(text: string) -> (v: json.Value, ok: bool) {
	t := strings.trim_space(text)
	if !strings.has_prefix(t, "{") {
		return nil, false
	}
	parsed, err := json.parse_string(t)
	if err != nil {
		return nil, false
	}
	_, is_obj := parsed.(json.Object)
	return parsed, is_obj
}

cmd_prime :: proc(cli: ^Cli, args: []string) -> int {
	budget := PRIME_BUDGET * 4
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
				return fail(cli, "usage: brain prime [--budget <tokens>] [<prompt...>]")
			}
			budget = n * 4
		case:
			append(&words, arg)
		}
	}
	prompt := strings.join(words[:], " ")
	session := session_id(cli)
	caller := caller_id(cli)
	if prompt == "" {
		text := read_stdin(cli)
		if v, is_hook := hook_input(text); is_hook {
			prompt = json_string(v, "prompt")
			if s := json_string(v, "session_id"); s != "" {
				session = s
			}
			if caller == "" && json_string(v, "hook_event_name") != "" {
				caller = "claude"
			}
		} else {
			prompt = text
		}
	}
	terms := prime_terms(prompt)
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
	if session != "" {
		hits = unserved(db, hits, session)
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
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	if len(hits) == 0 {
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

// unserved is hits less the ones this session was already given, by
// prime, pack or find.
unserved :: proc(db: sqlite3.Db, hits: []Hit, session: string) -> []Hit {
	served := make(map[string]bool)
	for h in column_texts(db, "select distinct h.handle from query_hits h join queries q on q.id = h.query_id where q.session = ?", session) {
		served[strings.clone(h)] = true
	}
	kept := make([dynamic]Hit)
	for h in hits {
		if !served[h.handle] {
			append(&kept, h)
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
	if len(args) > 0 {
		return fail(cli, "usage: brain settle  (a Claude Code Stop hook; reads the hook's JSON on stdin)")
	}
	v, is_hook := hook_input(read_stdin(cli))
	if !is_hook || json_bool(v, "stop_hook_active") {
		return 0
	}
	session := json_string(v, "session_id")
	transcript := json_string(v, "transcript_path")
	if session == "" || transcript == "" || !os.is_file(transcript) {
		return 0
	}
	stamp := path.join(cli.state, "settle", session)
	if os.exists(stamp) {
		return 0
	}
	turns, worked, proposed := settle_scan(transcript)
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
	w := jw_make()
	jw_obj(&w)
	jw_field(&w, "decision", "block")
	jw_field(&w, "reason", strings.to_string(reason))
	jw_end_obj(&w)
	jw_flush(cli, &w)
	return 0
}

// settle_scan reads a transcript for what settle decides on: how many
// times the assistant spoke, whether it changed anything (an edit, a write
// or a shell command), and whether it already proposed to memory.
settle_scan :: proc(file: string) -> (turns: int, worked, proposed: bool) {
	text, err := os.read_entire_file_from_path(file, context.allocator)
	if err != nil {
		return
	}
	lines := strings.split_lines(string(text))
	for l in lines {
		v := parse_line(l)
		obj, is_obj := v.(json.Object)
		if !is_obj || json_string(v, "type") != "assistant" || json_bool(v, "isSidechain") {
			continue
		}
		turns += 1
		for block in content_blocks(obj["message"]) {
			if json_string(block, "type") != "tool_use" {
				continue
			}
			switch json_string(block, "name") {
			case "Edit", "Write", "NotebookEdit":
				worked = true
			case "Bash":
				worked = true
				if strings.contains(json_string(block, "input", "command"), "brain propose") {
					proposed = true
				}
			}
		}
	}
	return
}

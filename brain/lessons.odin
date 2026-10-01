package brain

import "core:strconv"
import "core:strings"

import "jm:path"
import "jm:sqlite3"

// A lesson is a moment the transcripts hold and nothing reads back: the
// person correcting the agent, or a command that failed and the one that
// then worked. Both are found without a model. `brain lessons` lists them;
// --propose turns each into an inbox bullet whose source is the turn that
// produced it, so `brain recall --full <id>` shows why, and the agent
// sees the lesson the next time the topic comes up.

LESSON_DAYS :: 30 // the window --since defaults to
LESSON_MAX_BODY :: 300 // a correction is short; a brief is not one
LESSON_SNIPPET :: 160 // characters of the assistant turn kept
LESSON_RETRY_LOOKAHEAD :: 3 // shell calls after a failure that may be its fix
LESSON_BUDGET :: 1500 // tokens

// A user turn that opens with one of these is a correction. Each is
// matched as whole words at the start of the turn, so "now" is not "no".
LESSON_STARTS :: [?]string {
	"no", "nope", "don't", "dont", "do not", "stop", "wrong", "not that", "undo", "revert",
	"that's not", "thats not", "that is not", "i said", "i told you", "why did you",
	"not what i", "you broke", "that broke", "this broke", "incorrect", "instead",
}

// Openings that read as one of LESSON_STARTS and are not corrections.
LESSON_NOT_STARTS :: [?]string{"no problem", "no worries", "no need", "no rush", "no idea", "no changes", "no further"}

// A turn holding one of these anywhere is a correction, whatever it opens with.
LESSON_PHRASES :: [?]string {
	"i said", "i told you", "not what i asked", "don't do that", "do not do that", "revert that",
	"undo that", "that's wrong", "that is wrong", "you broke", "stop doing", "as i said",
}

Moment :: struct {
	kind:                                            string, // correction or retry
	id, ts, date, session, title, cwd, repo:         string,
	agent, user:                                     string, // correction: what was said, then the reply
	failed, worked:                                  string, // retry: the command that failed, the one that worked
}

cmd_lessons :: proc(cli: ^Cli, args: []string) -> int {
	days := LESSON_DAYS
	budget := LESSON_BUDGET * 4
	propose := false
	project, session := "", ""
	rest := args
	for len(rest) > 0 {
		arg := rest[0]
		rest = rest[1:]
		switch arg {
		case "--propose":
			propose = true
		case "--since":
			n, ok := 0, false
			if len(rest) > 0 {
				n, ok = strconv.parse_int(strings.trim_suffix(rest[0], "d"))
				rest = rest[1:]
			}
			if !ok || n <= 0 {
				return fail(cli, "usage: brain lessons --since <days>d")
			}
			days = n
		case "--project", "--session":
			if len(rest) == 0 {
				return fail(cli, strings.concatenate({"usage: brain lessons ", arg, " <name>"}))
			}
			if arg == "--project" {
				project = rest[0]
			} else {
				session = rest[0]
			}
			rest = rest[1:]
		case "--budget":
			n, ok := 0, false
			if len(rest) > 0 {
				n, ok = strconv.parse_int(rest[0])
				rest = rest[1:]
			}
			if !ok || n <= 0 {
				return fail(cli, "usage: --budget <tokens>")
			}
			budget = n * 4
		case:
			return fail(cli, "usage: brain lessons [--since <days>d] [--project <name>] [--session <id>] [--propose]")
		}
	}
	if !recall_enabled(cli) {
		return 1
	}
	db, err := open_recall_db(cli)
	if err != "" {
		return fail(cli, err)
	}
	defer sqlite3.close(&db)
	recall_sync(cli, db, full = false)
	moments := lesson_moments(db, days, project, session)

	if propose {
		if verr := need_vault(cli); verr != "" {
			return fail(cli, verr)
		}
		return lessons_propose(cli, moments)
	}
	if cli.json {
		w := jw_make()
		jw_arr(&w)
		for m in moments {
			jw_obj(&w)
			jw_field(&w, "kind", m.kind)
			jw_field(&w, "id", m.id)
			jw_field(&w, "date", m.date)
			jw_field(&w, "session", m.session)
			jw_field(&w, "title", m.title)
			jw_field(&w, "repo", m.repo)
			jw_field(&w, "agent", m.agent)
			jw_field(&w, "user", m.user)
			jw_field(&w, "failed", m.failed)
			jw_field(&w, "worked", m.worked)
			jw_end_obj(&w)
		}
		jw_end_arr(&w)
		jw_flush(cli, &w)
		return len(moments) > 0 ? 0 : 1
	}
	if len(moments) == 0 {
		outf(cli, "no corrections or retries in the last %d days\n", days)
		return 1
	}
	out(cli, cut_lines(render_moments(moments), budget))
	return 0
}

render_moments :: proc(moments: []Moment) -> string {
	b := strings.builder_make()
	for m in moments {
		strings.write_string(&b, strings.concatenate({m.date, "  ", m.title, "  ", m.repo, "\n"}))
		if m.kind == "retry" {
			strings.write_string(&b, strings.concatenate({"    failed: ", m.failed, "\n    worked: ", m.worked, "\n"}))
		} else {
			strings.write_string(&b, strings.concatenate({"    agent: ", m.agent, "\n    user: ", m.user, "\n"}))
		}
		strings.write_string(&b, strings.concatenate({"    ", m.id, "\n\n"}))
	}
	return strings.to_string(b)
}

// lesson_moments is every correction and retry in the window, oldest
// first; days of zero is no window. project narrows to one repository by
// name and session to one conversation.
lesson_moments :: proc(db: sqlite3.Db, days: int, project, session: string) -> []Moment {
	since := days > 0 ? strings.concatenate({"-", int_str(i64(days)), " day"}) : "-100 year"
	moments := make([dynamic]Moment)

	// Corrections: a short user turn, opening with or holding a marker,
	// that answers something the agent said.
	stmt, err := sqlite3.query(
		db,
		`select id, ts, session, title, cwd, body from turn
		 where role = 'user' and length(body) < ? and ts >= date('now', ?)
		   and (? = '' or session = ?)
		 order by session, ts`,
		i64(LESSON_MAX_BODY),
		since,
		session,
		session,
	)
	if err == nil {
		for sqlite3.next(&stmt) {
			body := sqlite3.text(stmt, 5)
			if !is_correction(body) {
				continue
			}
			cwd := strings.clone(sqlite3.text(stmt, 4))
			repo := path.base(cwd)
			if project != "" && !strings.equal_fold(repo, project) {
				continue
			}
			m := Moment {
				kind    = "correction",
				id      = strings.clone(sqlite3.text(stmt, 0)),
				ts      = strings.clone(sqlite3.text(stmt, 1)),
				session = strings.clone(sqlite3.text(stmt, 2)),
				title   = strings.clone(sqlite3.text(stmt, 3)),
				cwd     = cwd,
				repo    = repo,
				user    = strings.clone(body),
			}
			m.date = rune_prefix(m.ts, 10)
			m.agent = rune_prefix(
				strings.clone(scalar_text(db, "select body from turn where session=? and role='assistant' and ts < ? order by ts desc limit 1", m.session, m.ts)),
				LESSON_SNIPPET,
			)
			if m.agent == "" {
				continue // nothing was said yet; a brief, not a correction
			}
			append(&moments, m)
		}
		sqlite3.finish(&stmt)
	}

	// Retries: a shell call that failed, then within a few calls one that
	// worked and is the same command retouched. The first failure before a
	// fix is the one kept.
	fixed := make(map[string]bool)
	fstmt, ferr := sqlite3.query(
		db,
		`select id, ts, session, title, cwd, input from tool
		 where name = ? and ok = 0 and input <> '' and ts >= date('now', ?)
		   and (? = '' or session = ?)
		 order by session, ts`,
		HOWTO_SHELL,
		since,
		session,
		session,
	)
	if ferr == nil {
		for sqlite3.next(&fstmt) {
			cwd := strings.clone(sqlite3.text(fstmt, 4))
			repo := path.base(cwd)
			if project != "" && !strings.equal_fold(repo, project) {
				continue
			}
			m := Moment {
				kind    = "retry",
				id      = strings.clone(sqlite3.text(fstmt, 0)),
				ts      = strings.clone(sqlite3.text(fstmt, 1)),
				session = strings.clone(sqlite3.text(fstmt, 2)),
				title   = strings.clone(sqlite3.text(fstmt, 3)),
				cwd     = cwd,
				repo    = repo,
				failed  = strings.clone(sqlite3.text(fstmt, 5)),
			}
			m.date = rune_prefix(m.ts, 10)
			next, nerr := sqlite3.query(
				db,
				"select id, input, ok from tool where session=? and name=? and ts > ? order by ts limit ?",
				m.session,
				HOWTO_SHELL,
				m.ts,
				i64(LESSON_RETRY_LOOKAHEAD),
			)
			if nerr != nil {
				continue
			}
			for sqlite3.next(&next) {
				if sqlite3.integer(next, 2) != 1 {
					continue
				}
				worked := sqlite3.text(next, 1)
				wid := sqlite3.text(next, 0)
				if same_command(m.failed, worked) && !fixed[wid] {
					fixed[strings.clone(wid)] = true
					m.worked = strings.clone(worked)
					append(&moments, m)
				}
				break
			}
			sqlite3.finish(&next)
		}
		sqlite3.finish(&fstmt)
	}
	return moments[:]
}

// is_correction reports whether a user turn reads as one.
is_correction :: proc(body: string) -> bool {
	lower := strings.to_lower(strings.trim_space(body))
	if lower == "" || lower[0] == '<' {
		return false
	}
	words := lead_words(lower, 4)
	not_starts := LESSON_NOT_STARTS
	for n in not_starts {
		if starts_with_words(words, n) {
			return false
		}
	}
	starts := LESSON_STARTS
	for s in starts {
		if starts_with_words(words, s) {
			return true
		}
	}
	phrases := LESSON_PHRASES
	for p in phrases {
		if strings.contains(lower, p) {
			return true
		}
	}
	return false
}

// lead_words is the first n words of lowered text with the punctuation
// around each word dropped, so "No, don't." reads no don't.
lead_words :: proc(lower: string, n: int) -> []string {
	words := make([dynamic]string)
	for w in strings.fields(lower) {
		if len(words) == n {
			break
		}
		t := strings.trim(w, ".,;:!?\"'()[]")
		if t != "" {
			append(&words, t)
		}
	}
	return words[:]
}

starts_with_words :: proc(words: []string, marker: string) -> bool {
	m := strings.fields(marker)
	if len(m) > len(words) {
		return false
	}
	for w, i in m {
		if words[i] != w {
			return false
		}
	}
	return true
}

// same_command is whether a command that worked is the failed one
// retouched: the same program, and the lines near enough that one edit
// in three characters covers the difference.
same_command :: proc(failed, worked: string) -> bool {
	if failed == worked {
		return false
	}
	fa, wa := strings.fields(failed), strings.fields(worked)
	if len(fa) == 0 || len(wa) == 0 || fa[0] != wa[0] {
		return false
	}
	d := edit_distance(failed, worked)
	return d * 3 <= max(len(failed), len(worked))
}

// edit_distance is Levenshtein over bytes, enough to compare two shell
// lines of a few hundred characters.
edit_distance :: proc(a, b: string) -> int {
	prev := make([]int, len(b) + 1)
	cur := make([]int, len(b) + 1)
	for j in 0 ..= len(b) {
		prev[j] = j
	}
	for i in 1 ..= len(a) {
		cur[0] = i
		for j in 1 ..= len(b) {
			cost := a[i - 1] == b[j - 1] ? 0 : 1
			cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}

// lessons_propose queues one bullet per moment. The handle is the lesson
// in a few words; the source is the turn it came from.
lessons_propose :: proc(cli: ^Cli, moments: []Moment) -> int {
	json_mode := cli.json
	cli.json = false
	defer cli.json = json_mode
	proposed := 0
	for m in moments {
		line := lesson_bullet(m)
		mark := strings.builder_len(cli.out)
		propose_line(cli, line)
		if strings.has_prefix(strings.to_string(cli.out)[mark:], "proposed") {
			proposed += 1
		}
	}
	if json_mode {
		strings.builder_reset(&cli.out)
		w := jw_make()
		jw_obj(&w)
		jw_field_int(&w, "moments", i64(len(moments)))
		jw_field_int(&w, "proposed", i64(proposed))
		jw_end_obj(&w)
		jw_flush(cli, &w)
	} else if len(moments) == 0 {
		out(cli, "nothing to propose\n")
	}
	return 0
}

lesson_bullet :: proc(m: Moment) -> string {
	if m.kind == "retry" {
		words := strings.fields(m.worked)
		head := strings.join(words[:min(len(words), 3)], " ")
		return strings.concatenate(
			{"- **retry: ", head, "**", SEP, "`", m.failed, "` failed; `", m.worked, "` worked", SEP, "recall:", m.id, SEP, m.date},
		)
	}
	head := strings.join(lead_words(strings.to_lower(m.user), 6), " ")
	return strings.concatenate(
		{"- **lesson: ", head, "**", SEP, strings.trim_space(m.user), " (the agent had: ", m.agent, ")", SEP, "recall:", m.id, SEP, m.date},
	)
}

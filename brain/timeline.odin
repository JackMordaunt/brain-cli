package brain

import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "jm:path"
import "jm:sh"
import "jm:sqlite3"

// A timeline is what was worked on, by day and repository, read from the
// transcripts: each session's title, its first prompt as the goal, how
// long it ran, and the repository's commits in the window. `brain day` is
// one day, `brain week` the last seven; both are the standup nobody has to
// write. Days are the machine's local days, whatever zone a transcript
// stamps its turns in.

TIMELINE_BUDGET :: 1500 // tokens
TIMELINE_COMMITS :: 30 // commits listed per repository per window
TIMELINE_GOAL :: 100 // characters of the first prompt
GIT_TIMEOUT :: 3 * time.Second

Tl_Session :: struct {
	session, adapter, title, cwd, day, first, last, goal: string,
	turns:                                               int,
}

Tl_Repo :: struct {
	repo, cwd: string,
	sessions:  [dynamic]Tl_Session,
	commits:   []string,
}

Tl_Day :: struct {
	day:   string,
	repos: [dynamic]Tl_Repo,
}

cmd_day :: proc(cli: ^Cli, args: []string) -> int {
	return cmd_timeline(cli, args, week = false)
}

cmd_week :: proc(cli: ^Cli, args: []string) -> int {
	return cmd_timeline(cli, args, week = true)
}

cmd_timeline :: proc(cli: ^Cli, args: []string, week: bool) -> int {
	budget := TIMELINE_BUDGET * 4
	with_git := true
	days := 7
	project, date := "", ""
	rest := args
	for len(rest) > 0 {
		arg := rest[0]
		rest = rest[1:]
		switch arg {
		case "--no-git":
			with_git = false
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
		case "--since":
			n, ok := 0, false
			if len(rest) > 0 {
				n, ok = strconv.parse_int(strings.trim_suffix(rest[0], "d"))
				rest = rest[1:]
			}
			if !ok || n <= 0 {
				return fail(cli, "usage: brain week --since <days>d")
			}
			days = n
		case "--project":
			if len(rest) == 0 {
				return fail(cli, "usage: --project <name>")
			}
			project = rest[0]
			rest = rest[1:]
		case:
			if strings.has_prefix(arg, "-") {
				return fail(cli, strings.concatenate({"unknown flag ", arg}))
			}
			if week || !is_iso_date(arg) {
				return fail(cli, week ? "usage: brain week [--since <days>d] [--project <name>] [--no-git]" : "usage: brain day [YYYY-MM-DD] [--project <name>] [--no-git]")
			}
			date = arg
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

	from, to: string
	if week {
		from = scalar_text(db, "select date('now','localtime',?)", strings.concatenate({"-", int_str(i64(days - 1)), " day"}))
		to = scalar_text(db, "select date('now','localtime')")
	} else {
		from = date != "" ? date : scalar_text(db, "select date('now','localtime')")
		to = from
	}
	tl := timeline_days(db, from, to, project)
	if with_git {
		for &d in tl {
			for &r in d.repos {
				r.commits = repo_commits(r.cwd, d.day)
			}
		}
	}
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "from", from)
		jw_field(&w, "to", to)
		jw_key(&w, "days")
		jw_arr(&w)
		for d in tl {
			jw_obj(&w)
			jw_field(&w, "day", d.day)
			jw_key(&w, "repos")
			jw_arr(&w)
			for r in d.repos {
				jw_obj(&w)
				jw_field(&w, "repo", r.repo)
				jw_field(&w, "cwd", r.cwd)
				jw_key(&w, "sessions")
				jw_arr(&w)
				for s in r.sessions {
					jw_obj(&w)
					jw_field(&w, "session", s.session)
					jw_field(&w, "agent", s.adapter)
					jw_field(&w, "title", s.title)
					jw_field(&w, "first", s.first)
					jw_field(&w, "last", s.last)
					jw_field_int(&w, "turns", i64(s.turns))
					jw_field(&w, "goal", s.goal)
					jw_end_obj(&w)
				}
				jw_end_arr(&w)
				jw_key(&w, "commits")
				jw_arr(&w)
				for c in r.commits {
					jw_str(&w, c)
				}
				jw_end_arr(&w)
				jw_end_obj(&w)
			}
			jw_end_arr(&w)
			jw_end_obj(&w)
		}
		jw_end_arr(&w)
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return len(tl) > 0 ? 0 : 1
	}
	if len(tl) == 0 {
		if from == to {
			outf(cli, "nothing recorded on %s\n", from)
		} else {
			outf(cli, "nothing recorded between %s and %s\n", from, to)
		}
		return 1
	}
	body := render_timeline(tl)
	out(cli, cut_lines(body, budget))
	return 0
}

// timeline_days groups the window's sessions by local day, then by the
// directory they ran in. A session that crossed midnight lists on each day.
timeline_days :: proc(db: sqlite3.Db, from, to, project: string) -> []Tl_Day {
	days := make([dynamic]Tl_Day)
	stmt, err := sqlite3.query(
		db,
		`select date(ts,'localtime') as day, session, adapter, title, cwd,
		        time(min(ts),'localtime'), time(max(ts),'localtime'), count(*)
		 from turn
		 where date(ts,'localtime') between ? and ?
		 group by day, session
		 order by day, cwd, min(ts)`,
		from,
		to,
	)
	if err != nil {
		return nil
	}
	defer sqlite3.finish(&stmt)
	for sqlite3.next(&stmt) {
		cwd := strings.clone(sqlite3.text(stmt, 4))
		repo := path.base(cwd)
		if project != "" && !strings.equal_fold(repo, project) {
			continue
		}
		s := Tl_Session {
			day     = strings.clone(sqlite3.text(stmt, 0)),
			session = strings.clone(sqlite3.text(stmt, 1)),
			adapter = strings.clone(sqlite3.text(stmt, 2)),
			title   = strings.clone(sqlite3.text(stmt, 3)),
			cwd     = cwd,
			first   = rune_prefix(strings.clone(sqlite3.text(stmt, 5)), 5),
			last    = rune_prefix(strings.clone(sqlite3.text(stmt, 6)), 5),
			turns   = int(sqlite3.integer(stmt, 7)),
		}
		if len(days) == 0 || days[len(days) - 1].day != s.day {
			append(&days, Tl_Day{day = s.day})
		}
		d := &days[len(days) - 1]
		if len(d.repos) == 0 || d.repos[len(d.repos) - 1].cwd != cwd {
			append(&d.repos, Tl_Repo{repo = repo, cwd = cwd})
		}
		append(&d.repos[len(d.repos) - 1].sessions, s)
	}
	// The goal is the session's first prompt, fetched per session so the
	// grouping query stays one group-by.
	for &d in days {
		for &r in d.repos {
			for &s in r.sessions {
				s.goal = rune_prefix(
					scalar_text(db, "select body from turn where session=? and role='user' order by ts limit 1", s.session),
					TIMELINE_GOAL,
				)
			}
		}
	}
	return days[:]
}

// repo_commits is the subjects of the commits made in cwd on one local
// day, when cwd is on this machine and git answers in time. A directory
// that is not a repository, or has none, is an empty list.
repo_commits :: proc(cwd, day: string) -> []string {
	if cwd == "" || !os.is_dir(cwd) {
		return nil
	}
	r := sh.exec(
		{"git", "log", strings.concatenate({"--since=", day, "T00:00:00"}), strings.concatenate({"--until=", day, "T23:59:59"}), "--format=%s", "-n", int_str(TIMELINE_COMMITS)},
		{dir = cwd, timeout = GIT_TIMEOUT},
	)
	if !r.ok {
		return nil
	}
	lines := make([dynamic]string)
	for l in strings.split_lines(r.stdout) {
		if strings.trim_space(l) != "" {
			append(&lines, l)
		}
	}
	return lines[:]
}

render_timeline :: proc(tl: []Tl_Day) -> string {
	b := strings.builder_make()
	for d in tl {
		strings.write_string(&b, d.day)
		strings.write_byte(&b, '\n')
		for r in d.repos {
			strings.write_string(&b, "  ")
			strings.write_string(&b, r.repo)
			strings.write_string(&b, "  ")
			strings.write_string(&b, r.cwd)
			strings.write_byte(&b, '\n')
			for s in r.sessions {
				strings.write_string(&b, "    ")
				strings.write_string(&b, s.first)
				strings.write_byte(&b, '-')
				strings.write_string(&b, s.last)
				strings.write_string(&b, "  ")
				strings.write_string(&b, s.title)
				strings.write_string(&b, "  (")
				strings.write_string(&b, int_str(i64(s.turns)))
				strings.write_string(&b, " turns, ")
				strings.write_string(&b, s.adapter)
				strings.write_string(&b, ")\n")
				if s.goal != "" {
					strings.write_string(&b, "      ")
					strings.write_string(&b, s.goal)
					strings.write_byte(&b, '\n')
				}
			}
			if len(r.commits) > 0 {
				strings.write_string(&b, "    commits:\n")
				for c in r.commits {
					strings.write_string(&b, "      - ")
					strings.write_string(&b, c)
					strings.write_byte(&b, '\n')
				}
			}
		}
	}
	return strings.to_string(b)
}

// cut_lines keeps whole lines of text up to budget bytes and says so when
// it stopped short.
cut_lines :: proc(text: string, budget: int) -> string {
	if len(text) <= budget {
		return text
	}
	b := strings.builder_make()
	written := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if written + len(line) + 1 > budget {
			break
		}
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
		written += len(line) + 1
	}
	strings.write_string(&b, "… output capped; narrow the window or raise --budget\n")
	return strings.to_string(b)
}

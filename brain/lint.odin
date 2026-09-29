package brain

import "core:fmt"
import "core:os"
import "core:strings"
import "core:text/regex"
import "core:time"
import "core:unicode/utf8"

import "jm:path"
import "jm:sh"
import "jm:sqlite3"

// Hard failures block a commit. Warnings never do. A line that does not parse
// is skipped rather than rejected, so the bullet format never becomes
// load-bearing.

// Checked is one line lint looks at: which file it belongs to and its text.
Checked :: struct {
	file, text: string,
}

cmd_lint :: proc(cli: ^Cli, args: []string) -> int {
	if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	staged := false
	rest := args
	if len(rest) > 0 && rest[0] == "--staged" {
		staged = true
		rest = rest[1:]
	}
	lines: []Checked
	if staged {
		lines = staged_lines(cli.vault)
	} else {
		files := rest
		if len(files) == 0 {
			core := CORE
			files = core[:]
		}
		lines = file_lines(cli.vault, files)
	}

	secret_re, _ := regex.create(
		`(password|secret|token|api[_-]?key)\s*[:=]\s*[A-Za-z0-9/+_-]{16,}`,
		{.Case_Insensitive},
	)
	placeholder_re, _ := regex.create(`\$[A-Z_]{3,}|<[a-z]`)
	key_re, _ := regex.create(`BEGIN [A-Z ]*PRIVATE KEY`)
	today := today_iso()

	findings := make([dynamic]Finding)
	for l in lines {
		if !is_core(l.file) || !strings.has_prefix(l.text, "- **") {
			continue
		}
		handle, found := between(l.text, "- **", "**")
		if !found || handle == "" {
			continue
		}
		date := trailing_date(l.text)
		fact := l.text
		if i := strings.index(l.text, "— "); i >= 0 {
			fact = l.text[i + len("— "):]
		}
		header := l.text
		if i := strings.index(l.text, "— "); i >= 0 {
			header = l.text[:i]
		}

		if date == "" {
			append(&findings, Finding{true, l.file, handle, "date", "has no trailing ISO date"})
		} else if date > today {
			append(&findings, Finding{true, l.file, handle, "date", fmt.aprintf("is dated in the future (%s)", date)})
		}
		if matches(secret_re, l.text) && !matches(placeholder_re, l.text) {
			append(&findings, Finding{true, l.file, handle, "secret", "looks like it carries a literal secret"})
		}
		if matches(key_re, l.text) {
			append(&findings, Finding{true, l.file, handle, "secret", "contains a private key"})
		}
		if n := utf8.rune_count_in_string(fact); n > MAXLEN {
			append(&findings, Finding{false, l.file, handle, "length", fmt.aprintf("fact is %d chars (cap %d) — spill to an artifact and point at it", n, MAXLEN)})
		}
		if !strings.contains(header, "(") {
			append(&findings, Finding{false, l.file, handle, "aliases", "has no aliases — name the words a future searcher will type"})
		}
	}

	if staged && nonempty_file(cli.db) {
		if db, err := open_db(cli.db); err == "" {
			for h in column_texts(db, "select handle from bullets group by lower(handle) having count(*)>1") {
				append(&findings, Finding{false, "", h, "duplicate", "duplicate handle in the index"})
			}
			sqlite3.close(&db)
		}
	}

	fails, warns := 0, 0
	for f in findings {
		if f.fail {
			fails += 1
		} else {
			warns += 1
		}
	}
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field_bool(&w, "ok", fails == 0)
		for level in ([2]string{"failures", "warnings"}) {
			jw_key(&w, level)
			jw_arr(&w)
			for f in findings {
				if f.fail != (level == "failures") {
					continue
				}
				jw_obj(&w)
				jw_field(&w, "file", f.file)
				jw_field(&w, "handle", f.handle)
				jw_field(&w, "rule", f.rule)
				jw_field(&w, "message", f.message)
				jw_end_obj(&w)
			}
			jw_end_arr(&w)
		}
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return fails == 0 ? 0 : 1
	}
	for f in findings {
		if f.file == "" {
			outf(cli, "warn %s: **%s**\n", f.message, f.handle)
		} else {
			outf(cli, "%s %s: **%s** %s\n", f.fail ? "FAIL" : "warn", f.file, f.handle, f.message)
		}
	}
	outf(cli, "brain lint: %d failure(s), %d warning(s)\n", fails, warns)
	return fails == 0 ? 0 : 1
}

// Finding is one thing lint has to say: a failure blocks a commit, a
// warning never does.
Finding :: struct {
	fail:                         bool,
	file, handle, rule, message: string,
}

// staged_lines returns every added line of markdown in the vault's index,
// tagged with its file.
staged_lines :: proc(vault: string) -> []Checked {
	r := sh.exec(
		{"git", "diff", "--cached", "-U0", "--src-prefix=a/", "--dst-prefix=b/", "--", "*.md"},
		{dir = vault},
	)
	lines := make([dynamic]Checked)
	file := ""
	rest := r.stdout
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_suffix(raw, "\r")
		if strings.has_prefix(line, "+++ b/") {
			file = line[len("+++ b/"):]
		} else if strings.has_prefix(line, "+") && !strings.has_prefix(line, "++") {
			append(&lines, Checked{file = file, text = line[1:]})
		}
	}
	return lines[:]
}

// file_lines reads whole files, tagged with their vault-relative names.
file_lines :: proc(vault: string, files: []string) -> []Checked {
	lines := make([dynamic]Checked)
	for f in files {
		data, err := os.read_entire_file_from_path(path.join(vault, f), context.allocator)
		if err != nil {
			continue
		}
		rest := string(data)
		for raw in strings.split_lines_iterator(&rest) {
			append(&lines, Checked{file = f, text = strings.trim_suffix(raw, "\r")})
		}
	}
	return lines[:]
}

// trailing_date returns the YYYY-MM-DD a line ends with, or "".
trailing_date :: proc(s: string) -> string {
	if len(s) < 10 {
		return ""
	}
	tail := s[len(s) - 10:]
	return is_iso_date(tail) ? tail : ""
}

// today_iso is the current UTC date; the same calendar sqlite's date('now')
// uses, so a bullet dated today passes both.
today_iso :: proc() -> string {
	buf := make([]byte, time.MIN_YYYY_DATE_LEN)
	return time.to_string_yyyy_mm_dd(time.now(), buf)
}

matches :: proc(re: regex.Regular_Expression, s: string) -> bool {
	_, ok := regex.match(re, s, context.temp_allocator, context.temp_allocator)
	return ok
}

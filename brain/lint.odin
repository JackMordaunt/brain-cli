package brain

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

	fails, warns := 0, 0
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
			outf(cli, "FAIL %s: **%s** has no trailing ISO date\n", l.file, handle)
			fails += 1
		} else if date > today {
			outf(cli, "FAIL %s: **%s** is dated in the future (%s)\n", l.file, handle, date)
			fails += 1
		}
		if matches(secret_re, l.text) && !matches(placeholder_re, l.text) {
			outf(cli, "FAIL %s: **%s** looks like it carries a literal secret\n", l.file, handle)
			fails += 1
		}
		if matches(key_re, l.text) {
			outf(cli, "FAIL %s: **%s** contains a private key\n", l.file, handle)
			fails += 1
		}
		if n := utf8.rune_count_in_string(fact); n > MAXLEN {
			outf(
				cli,
				"warn %s: **%s** fact is %d chars (cap %d) — spill to an artifact and point at it\n",
				l.file,
				handle,
				n,
				MAXLEN,
			)
			warns += 1
		}
		if !strings.contains(header, "(") {
			outf(cli, "warn %s: **%s** has no aliases — name the words a future searcher will type\n", l.file, handle)
			warns += 1
		}
	}

	if staged && nonempty_file(cli.db) {
		if db, err := open_db(cli.db); err == "" {
			for h in column_texts(db, "select handle from bullets group by lower(handle) having count(*)>1") {
				outf(cli, "warn duplicate handle in the index: **%s**\n", h)
				warns += 1
			}
			sqlite3.close(&db)
		}
	}

	outf(cli, "brain lint: %d failure(s), %d warning(s)\n", fails, warns)
	return fails == 0 ? 0 : 1
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

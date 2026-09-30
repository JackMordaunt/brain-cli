package brain

import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import "jm:path"

// Bullet is one fact line, parsed from
//
//	- **handle** (aliases) — fact — source — YYYY-MM-DD
//
// A line that does not parse is skipped, never fatal: markdown stays
// authoritative and the index stays advisory.
Bullet :: struct {
	file:    string,
	line:    int,
	section: string,
	handle:  string,
	aliases: string,
	fact:    string,
	source:  string,
	date:    string,
	raw:     string,
	len:     int, // characters in fact
}

// Link is one [[target]] wikilink; an alias after | is dropped.
Link :: struct {
	file:   string,
	line:   int,
	target: string,
}

// Line is a prose line worth indexing: longer than 20 characters and not a
// bullet, which is indexed with structure instead.
Line :: struct {
	file: string,
	line: int,
	text: string,
}

// Scan is everything the index wants from one markdown file.
Scan :: struct {
	file:    string,
	title:   string, // the first `# ` heading in the first 20 lines
	date:    string, // the YYYY-MM-DD in the file's name, if it has one
	bullets: [dynamic]Bullet,
	links:   [dynamic]Link,
	lines:   [dynamic]Line,
}

SEP :: " — "

// list_md returns every .md file under the vault, relative with forward
// slashes and in byte order, skipping .git.
list_md :: proc(vault: string) -> ([]string, os.Error) {
	all, err := path.walk(vault)
	if err != nil {
		return nil, err
	}
	files := make([dynamic]string)
	for f in all {
		rel := relative(vault, f)
		if !strings.has_suffix(rel, ".md") {
			continue
		}
		if strings.has_prefix(rel, ".git/") || strings.contains(rel, "/.git/") {
			continue
		}
		// The inbox joins the index only by the review setting, and what a
		// person dropped never does; index_files decides.
		if rel == INBOX_FILE || rel == DROPPED_FILE {
			continue
		}
		append(&files, rel)
	}
	slice.sort(files[:])
	return files[:], nil
}

// relative strips root from p and normalises the separators to /. The walker
// hands back absolute paths whatever root it was given, so root is made
// absolute too; on Windows the two may differ in case.
relative :: proc(root, p: string) -> string {
	r := root
	if abs, err := path.abs(root); err == nil {
		r = abs
	}
	r, _ = strings.replace_all(r, "\\", "/")
	rel, _ := strings.replace_all(p, "\\", "/")
	if len(rel) > len(r) {
		head := rel[:len(r)]
		same := head == r
		when ODIN_OS == .Windows || ODIN_OS == .Darwin {
			same = strings.equal_fold(head, r)
		}
		if same {
			rel = strings.trim_left(rel[len(r):], "/")
		}
	}
	return rel
}

// scan_file parses one file. rel is the vault-relative name recorded on
// every row; the file is read from vault/rel.
scan_file :: proc(vault, rel: string) -> (s: Scan, err: os.Error) {
	data := os.read_entire_file_from_path(path.join(vault, rel), context.allocator) or_return
	return scan_text(rel, string(data)), nil
}

// scan_text is scan_file on text already in memory. A trailing \r on any
// line is dropped, so a vault checked out with CRLF parses the same.
scan_text :: proc(rel, text: string) -> (s: Scan) {
	s.file = rel
	s.date = name_date(path.base(rel))
	section := ""
	rest := text
	n := 0
	for raw_line in strings.split_lines_iterator(&rest) {
		n += 1
		line := strings.trim_suffix(raw_line, "\r")
		if n <= 20 && s.title == "" && strings.has_prefix(line, "# ") {
			s.title = line[2:]
		}
		if strings.has_prefix(line, "## ") {
			section = line[3:]
			continue
		}
		is_bullet := strings.has_prefix(line, "- **")
		if is_bullet {
			if b, ok := parse_bullet(line, section); ok {
				b.file = rel
				b.line = n
				append(&s.bullets, b)
			}
		}
		for target in link_targets(line) {
			append(&s.links, Link{file = rel, line = n, target = target})
		}
		if !is_bullet && utf8.rune_count_in_string(line) > 20 {
			append(&s.lines, Line{file = rel, line = n, text = line})
		}
	}
	return s
}

// parse_bullet reads one `- **handle** ...` line. The date is the last
// field when it is one; the source is the field before it; the fact is
// everything between the header and those two, em dashes and all.
parse_bullet :: proc(raw: string, section: string) -> (b: Bullet, ok: bool) {
	f := strings.split(raw, SEP)
	n := len(f)
	hdr := f[0]
	b.raw = raw
	b.section = section
	if n >= 2 && is_iso_date(f[n - 1]) {
		b.date = f[n - 1]
		if n >= 3 {
			b.source = f[n - 2]
		}
		if n > 3 {
			b.fact = strings.join(f[1:n - 2], SEP)
		}
	} else if n >= 2 {
		b.fact = strings.join(f[1:], SEP)
	}
	if h, found := between(hdr, "**", "**"); found {
		b.handle = h
	}
	if a, found := between(hdr, "(", ")"); found {
		b.aliases = strings.trim_left_space(strings.trim_prefix(a, "aliases:"))
	}
	if b.handle == "" || b.date == "" {
		return b, false
	}
	b.len = utf8.rune_count_in_string(b.fact)
	return b, true
}

// between returns the text after the first open and before the next close.
between :: proc(s, open, close: string) -> (string, bool) {
	i := strings.index(s, open)
	if i < 0 {
		return "", false
	}
	rest := s[i + len(open):]
	j := strings.index(rest, close)
	if j < 0 {
		return "", false
	}
	return rest[:j], true
}

// name_date is the first YYYY-MM-DD in a file name, the vault's convention
// for handoffs, plans and reports, or "" when there is none.
name_date :: proc(name: string) -> string {
	for i in 0 ..< len(name) {
		if i + 10 <= len(name) && is_iso_date(name[i:i + 10]) {
			return name[i:i + 10]
		}
	}
	return ""
}

// is_iso_date matches YYYY-MM-DD exactly.
is_iso_date :: proc(s: string) -> bool {
	if len(s) != 10 || s[4] != '-' || s[7] != '-' {
		return false
	}
	for c, i in transmute([]byte)s {
		if i == 4 || i == 7 {
			continue
		}
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// link_targets returns every [[target]] in a line, without any |alias.
link_targets :: proc(line: string) -> []string {
	targets := make([dynamic]string)
	s := line
	for {
		i := strings.index(s, "[[")
		if i < 0 {
			break
		}
		rest := s[i + 2:]
		j := strings.index(rest, "]]")
		if j < 0 {
			break
		}
		t := rest[:j]
		if k := strings.index_byte(t, '|'); k >= 0 {
			t = t[:k]
		}
		if t != "" {
			append(&targets, t)
		}
		s = rest[j + 2:]
	}
	return targets[:]
}

// is_core reports whether a vault-relative file is one of the CORE three.
is_core :: proc(file: string) -> bool {
	for c in CORE {
		if c == file {
			return true
		}
	}
	return false
}

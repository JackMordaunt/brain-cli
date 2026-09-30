package brain

import "core:strconv"
import "core:strings"

import "jm:sqlite3"

// Every command that reports state answers `--json` with one object on
// stdout, keys in the order they are written, so the desk and any script
// read the same thing a person does without scraping tables. The writer is
// by hand, since the shapes are small and the order is part of the shape.

Jw :: struct {
	b:         strings.Builder,
	first:     [dynamic]bool, // per open container: nothing written yet
	after_key: bool,
}

jw_make :: proc() -> Jw {
	return Jw{b = strings.builder_make(), first = make([dynamic]bool)}
}

// jw_sep writes the comma a value needs, unless it is the first in its
// container or follows a key.
jw_sep :: proc(w: ^Jw) {
	if w.after_key {
		w.after_key = false
		return
	}
	if n := len(w.first); n > 0 {
		if w.first[n - 1] {
			w.first[n - 1] = false
		} else {
			strings.write_byte(&w.b, ',')
		}
	}
}

jw_obj :: proc(w: ^Jw) {
	jw_sep(w)
	strings.write_byte(&w.b, '{')
	append(&w.first, true)
}

jw_arr :: proc(w: ^Jw) {
	jw_sep(w)
	strings.write_byte(&w.b, '[')
	append(&w.first, true)
}

jw_end_obj :: proc(w: ^Jw) {
	pop(&w.first)
	strings.write_byte(&w.b, '}')
}

jw_end_arr :: proc(w: ^Jw) {
	pop(&w.first)
	strings.write_byte(&w.b, ']')
}

jw_key :: proc(w: ^Jw, k: string) {
	jw_sep(w)
	strings.write_string(&w.b, json_quote(k))
	strings.write_byte(&w.b, ':')
	w.after_key = true
}

jw_str :: proc(w: ^Jw, s: string) {
	jw_sep(w)
	strings.write_string(&w.b, json_quote(s))
}

jw_int :: proc(w: ^Jw, n: i64) {
	jw_sep(w)
	strings.write_string(&w.b, int_str(n))
}

jw_f64 :: proc(w: ^Jw, f: f64) {
	jw_sep(w)
	buf: [32]byte
	strings.write_string(&w.b, strconv.write_float(buf[:], f, 'g', 6, 64))
}

jw_bool :: proc(w: ^Jw, v: bool) {
	jw_sep(w)
	strings.write_string(&w.b, v ? "true" : "false")
}

jw_null :: proc(w: ^Jw) {
	jw_sep(w)
	strings.write_string(&w.b, "null")
}

// jw_field is a key with a string value.
jw_field :: proc(w: ^Jw, k, v: string) {
	jw_key(w, k)
	jw_str(w, v)
}

jw_field_int :: proc(w: ^Jw, k: string, n: i64) {
	jw_key(w, k)
	jw_int(w, n)
}

jw_field_bool :: proc(w: ^Jw, k: string, v: bool) {
	jw_key(w, k)
	jw_bool(w, v)
}

// jw_flush prints the document and a newline.
jw_flush :: proc(cli: ^Cli, w: ^Jw) {
	out(cli, strings.to_string(w.b))
	out(cli, "\n")
}

// jw_rows writes a query's rows as an array of objects keyed by column name,
// typed as SQLite typed them.
jw_rows :: proc(w: ^Jw, db: sqlite3.Db, sql: string, args: ..sqlite3.Value) {
	jw_arr(w)
	defer jw_end_arr(w)
	stmt, err := sqlite3.query(db, sql, ..args)
	if err != nil {
		return
	}
	defer sqlite3.finish(&stmt)
	ncol := sqlite3.column_count(stmt)
	for sqlite3.next(&stmt) {
		jw_obj(w)
		for i in 0 ..< ncol {
			jw_key(w, sqlite3.name(stmt, i))
			switch sqlite3.type_of(stmt, i) {
			case .Integer:
				jw_int(w, sqlite3.integer(stmt, i))
			case .Real:
				jw_f64(w, sqlite3.real(stmt, i))
			case .Text:
				jw_str(w, sqlite3.text(stmt, i))
			case .Blob:
				jw_str(w, "<blob>")
			case .Null:
				jw_null(w)
			}
		}
		jw_end_obj(w)
	}
}

// jw_hit writes one bullet hit.
jw_hit :: proc(w: ^Jw, h: Hit) {
	jw_obj(w)
	jw_field(w, "file", h.file)
	jw_field_int(w, "line", h.line)
	jw_field(w, "handle", h.handle)
	jw_field(w, "aliases", h.aliases)
	jw_field(w, "fact", h.fact)
	jw_field(w, "source", h.source)
	jw_field(w, "date", h.date)
	jw_field_bool(w, "reviewed", h.file != INBOX_FILE)
	jw_key(w, "score")
	jw_f64(w, h.score)
	jw_end_obj(w)
}

package brain

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import "jm:sqlite3"

// print_box runs a query and renders every row the way `sqlite3 -box` does:
// a header, text left-aligned, numbers right-aligned. Nothing is printed
// for an empty result, which is also what sqlite3 does.
print_box :: proc(cli: ^Cli, db: sqlite3.Db, sql: string, args: ..sqlite3.Value) {
	stmt, err := sqlite3.query(db, sql, ..args)
	if err != nil {
		errf(cli, "brain: %s\n", sql_err(err))
		return
	}
	defer sqlite3.finish(&stmt)
	ncol := sqlite3.column_count(stmt)
	header := make([]string, ncol)
	for i in 0 ..< ncol {
		header[i] = sqlite3.name(stmt, i)
	}
	rows := make([dynamic][]string)
	numeric := make([]bool, ncol)
	for i in 0 ..< ncol {
		numeric[i] = true
	}
	for sqlite3.next(&stmt) {
		row := make([]string, ncol)
		for i in 0 ..< ncol {
			switch sqlite3.type_of(stmt, i) {
			case .Integer:
				row[i] = int_str(sqlite3.integer(stmt, i))
			case .Real:
				row[i] = fmt.aprintf("%g", sqlite3.real(stmt, i))
			case .Text:
				row[i] = sqlite3.text(stmt, i)
				numeric[i] = false
			case .Blob:
				row[i] = "<blob>"
				numeric[i] = false
			case .Null:
				row[i] = ""
			}
		}
		append(&rows, row)
	}
	if len(rows) == 0 {
		return
	}
	width := make([]int, ncol)
	for i in 0 ..< ncol {
		width[i] = utf8.rune_count_in_string(header[i])
		for row in rows {
			width[i] = max(width[i], utf8.rune_count_in_string(row[i]))
		}
	}
	rule(cli, "┌", "┬", "┐", width)
	out(cli, "│")
	for i in 0 ..< ncol {
		out(cli, " ")
		centred(cli, header[i], width[i])
		out(cli, " │")
	}
	out(cli, "\n")
	rule(cli, "├", "┼", "┤", width)
	for row in rows {
		out(cli, "│")
		for i in 0 ..< ncol {
			out(cli, " ")
			pad := width[i] - utf8.rune_count_in_string(row[i])
			if numeric[i] {
				spaces(cli, pad)
				out(cli, row[i])
			} else {
				out(cli, row[i])
				spaces(cli, pad)
			}
			out(cli, " │")
		}
		out(cli, "\n")
	}
	rule(cli, "└", "┴", "┘", width)
}

rule :: proc(cli: ^Cli, left, mid, right: string, width: []int) {
	out(cli, left)
	for w, i in width {
		for _ in 0 ..< w + 2 {
			out(cli, "─")
		}
		out(cli, i == len(width) - 1 ? right : mid)
	}
	out(cli, "\n")
}

centred :: proc(cli: ^Cli, s: string, w: int) {
	pad := w - utf8.rune_count_in_string(s)
	spaces(cli, pad / 2)
	out(cli, s)
	spaces(cli, pad - pad / 2)
}

spaces :: proc(cli: ^Cli, n: int) {
	for _ in 0 ..< n {
		out(cli, " ")
	}
}

int_str :: proc(v: i64) -> string {
	return fmt.aprintf("%d", v)
}

// in_list builds `(?,?,?)` for n bound values.
in_list :: proc(n: int) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '(')
	for i in 0 ..< n {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '?')
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

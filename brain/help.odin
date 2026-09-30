package brain

import "core:strings"

import "../term"

// print_usage prints USAGE. Plain, it is USAGE byte for byte, which is what an
// agent reads; styled, the same text carries weight: headings and command
// names bold, the repeated `brain` and the closing notes dim.
print_usage :: proc(cli: ^Cli) {
	if !term.styled(cli.style) {
		out(cli, USAGE)
		return
	}
	s := cli.style
	b := &cli.out
	text := USAGE
	blanks := 0
	first := true
	for line in strings.split_lines_iterator(&text) {
		switch {
		case first:
			first = false
			name, _, rest := strings.partition(line, " ")
			term.paint(b, s, {.Bold}, name)
			strings.write_byte(b, ' ')
			strings.write_string(b, rest)
		case line == "":
			// The blank after the title opens the commands; the next one
			// closes them.
			blanks += 1
		case blanks >= 2:
			term.paint(b, s, {.Dim}, line)
		case line[0] != ' ':
			term.paint(b, s, {.Bold}, line)
		case strings.has_prefix(line, "  brain "):
			cmd, desc := line[2:], ""
			if i := strings.index(cmd, "  "); i >= 0 {
				cmd, desc = cmd[:i], cmd[i:]
			}
			_, _, rest := strings.partition(cmd, " ")
			sub, sp, args := strings.partition(rest, " ")
			strings.write_string(b, "  ")
			term.paint(b, s, {.Dim}, "brain")
			strings.write_byte(b, ' ')
			term.paint(b, s, {.Bold}, sub)
			strings.write_string(b, sp)
			strings.write_string(b, args)
			strings.write_string(b, desc)
		case:
			strings.write_string(b, line)
		}
		strings.write_byte(b, '\n')
	}
}

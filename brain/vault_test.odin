package brain

import "core:testing"

@(test)
bullet_parses_every_field :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	b, ok := parse_bullet(
		"- **sqlite** (aliases: sqlite3, fts5) — the index is SQLite — fixture — 2026-01-01",
		"Tools",
	)
	testing.expect(t, ok)
	testing.expect_value(t, b.handle, "sqlite")
	testing.expect_value(t, b.aliases, "sqlite3, fts5")
	testing.expect_value(t, b.fact, "the index is SQLite")
	testing.expect_value(t, b.source, "fixture")
	testing.expect_value(t, b.date, "2026-01-01")
	testing.expect_value(t, b.section, "Tools")
	testing.expect_value(t, b.len, 19)
}

@(test)
bullet_keeps_em_dashes_inside_the_fact :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	b, ok := parse_bullet("- **x** (a) — one — two — three — src — 2026-01-01", "")
	testing.expect(t, ok)
	testing.expect_value(t, b.fact, "one — two — three")
	testing.expect_value(t, b.source, "src")
}

@(test)
bullet_without_a_date_is_skipped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	_, ok := parse_bullet("- **x** (a) — a fact — src", "")
	testing.expect(t, !ok, "no trailing date means no bullet")
	_, ok = parse_bullet("- not bold — fact — 2026-01-01", "")
	testing.expect(t, !ok, "no handle means no bullet")
}

@(test)
bullet_with_only_a_date_has_an_empty_fact :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	b, ok := parse_bullet("- **x** — 2026-01-01", "")
	testing.expect(t, ok)
	testing.expect_value(t, b.fact, "")
	testing.expect_value(t, b.source, "")
}

@(test)
scan_reads_a_crlf_file_like_an_lf_one :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	lf := "# Memory\n\n## Tools\n\n- **a** (aliases: b) — a fact that is long enough — src — 2026-01-01\nA prose line that is longer than twenty characters [[target|alias]] [[other]].\n"
	crlf := "# Memory\r\n\r\n## Tools\r\n\r\n- **a** (aliases: b) — a fact that is long enough — src — 2026-01-01\r\nA prose line that is longer than twenty characters [[target|alias]] [[other]].\r\n"
	a := scan_text("AI/MEMORY.md", lf)
	b := scan_text("AI/MEMORY.md", crlf)
	testing.expect_value(t, a.title, "Memory")
	testing.expect_value(t, b.title, "Memory")
	testing.expect_value(t, len(a.bullets), 1)
	testing.expect_value(t, len(b.bullets), 1)
	testing.expect_value(t, b.bullets[0].date, "2026-01-01")
	testing.expect_value(t, b.bullets[0].section, "Tools")
	testing.expect_value(t, b.bullets[0].line, 5)
	testing.expect_value(t, len(b.links), 2)
	testing.expect_value(t, b.links[0].target, "target")
	testing.expect_value(t, b.links[1].target, "other")
	testing.expect_value(t, len(b.lines), 1)
	testing.expect_value(t, b.lines[0].line, 6)
	testing.expect(t, b.lines[0].text[len(b.lines[0].text) - 1] == '.', "no \\r survives on a prose line")
}

@(test)
list_md_is_relative_sorted_and_skips_git :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	files, err := list_md("testdata/vault")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(files), 6)
	testing.expect_value(t, files[0], "AI/LEARNINGS.md")
	testing.expect_value(t, files[1], "AI/MEMORY.md")
	testing.expect_value(t, files[2], "AI/TUNINGS.md")
	testing.expect_value(t, files[3], "AI/handoffs/2025-12-30-old-plan.md")
	testing.expect_value(t, files[4], "AI/handoffs/2025-12-31-index-note.md")
	testing.expect_value(t, files[5], "AI/handoffs/2026-01-01-fixture.md")
}

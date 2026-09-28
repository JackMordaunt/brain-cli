// brainfold desk, as a prototype: the control room over a vault, drawn
// with jm:ui/material against fixture data shaped like the real
// commands' output. Every panel is a view the CLI already has the data
// for (the find log, doctor, recall, git); wiring them to it is the next
// step, not this one. Runs as the child half of a hot-reload split, see
// `just desk`.
//
//	desk                              run as the subprocess
//	desk -page Misses -png out.png    render one page headlessly
//	desk -dark -size 960x1030 ...     the dark scheme, another window size
//	desk -dump                        the frame's scene ops as text
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "jm:ui"
import "jm:ui/child"
import m3 "jm:ui/material"
import "jm:ui/render"

WIDTH :: 1280
HEIGHT :: 840
INSET :: 24

Page :: enum {
	Activity,
	Misses,
	Doctor,
	Recall,
	Inbox,
	Vault,
}

PAGE_TITLES := [Page]string {
	.Activity = "Activity",
	.Misses   = "Misses",
	.Doctor   = "Doctor",
	.Recall   = "Recall",
	.Inbox    = "Inbox",
	.Vault    = "Vault",
}

// PAGE_NOTES is the one line under each title that says what the panel
// is for, in the words the README uses.
PAGE_NOTES := [Page]string {
	.Activity = "What your agents asked, and what it cost them.",
	.Misses   = "Queries that still find nothing. Each one is a bullet or a synonym away.",
	.Doctor   = "What is stale, thin, duplicated or orphaned.",
	.Recall   = "What was said, across every agent's transcripts.",
	.Inbox    = "Facts your agents propose. Nothing enters the vault unseen.",
	.Vault    = "Where the markdown lives, and where it is pushed.",
}

Model :: struct {
	page:     int, // index into Page, the rail's selection
	dark:     bool,
	scheme:   m3.Scheme,
	theme:    ui.Theme,
	window:   ui.Size,
	query:    ui.Text_State,
	decided:  [len(PROPOSALS)]int, // 0 pending, 1 approved, 2 rejected
	filters:  [3]bool, // recall: which agents
	hosted:   bool,
	status:   string, // a literal set by the last action; never frame memory
	list:     ui.List_State,
}

// ---------------------------------------------------------------- fixtures
// Shaped like the real commands' rows. The queries and the doctor's stale
// bullets are today's from this machine's vault.

Lookup :: struct {
	at, agent, kind, query:   string,
	hits, bytes:              int,
}

LOOKUPS := [?]Lookup {
	{"14:20", "claude", "find", "jm hot-watch", 2, 708},
	{"14:18", "claude", "recall", "hyprctl eval", 5, 898},
	{"13:55", "pi", "find", "hyprland window rule", 3, 1843},
	{"13:41", "codex", "find", "sqlite fts5", 3, 1606},
	{"13:40", "claude", "find", "rig-performance", 0, 0},
	{"12:02", "claude", "find", "brain-cli", 7, 4393},
	{"11:47", "pi", "find", "systemd user unit", 3, 2443},
	{"11:30", "claude", "recall", "logo lab", 0, 0},
	{"10:12", "codex", "find", "review must-fix", 4, 2210},
	{"09:58", "claude", "find", "odin defer loop scope", 1, 402},
}

Miss :: struct {
	query, last, hint: string,
	misses:            int,
}

MISSES := [?]Miss {
	{"rig-performance", "today 17:17", "Nearest handle: hashrate. A synonym row would answer it.", 1},
	{"harfbuzz", "2026-09-25", "Text shaping lives under the handle shaper in LEARNINGS.", 1},
	{"agenda", "2026-09-25", "No bullet. The asker was pi, in Saz/supabase-backend.", 1},
	{"BSA", "2026-09-25", "An acronym. Add a synonyms.tsv row: BSA, bulk sale agreement.", 1},
	{"Penguin", "2026-09-25", "A codename with no bullet yet.", 1},
	{"S21 XP", "2026-09-25", "A miner model. MEMORY has S21 but not the XP variant.", 1},
	{"codeberg", "2026-09-25", "No bullet. Canonical remotes are on mordaunt.dev.", 1},
}

Finding :: struct {
	file, handle, note: string,
}

STALE := [?]Finding {
	{"AI/LEARNINGS.md", "awk empty first file", "not verified since 2026-01-01"},
	{"AI/MEMORY.md", "fixture tool", "not verified since 2026-01-01"},
	{"AI/MEMORY.md", "sqlite", "not verified since 2026-01-01"},
	{"AI/TUNINGS.md", "bluf", "not verified since 2026-01-01"},
}

THIN := [?]Finding {
	{"AI/MEMORY.md", "canonical remote", "1 alias; a future searcher's vocabulary is missing"},
	{"AI/LEARNINGS.md", "jm hot-watch stdc++", "1 alias"},
}

PROMOTE := [?]Finding {
	{"AI/MEMORY.md", "jm submodule", "returned by 5 queries in 3 sessions; a project file would answer for free"},
	{"AI/TUNINGS.md", "bluf", "returned by 4 queries in 4 sessions"},
}

Turn :: struct {
	date, agent, title, snippet: string,
}

TURNS := [?]Turn {
	{"2026-09-28", "claude", "Project logo design with jm:ui", "… on Hyprland 0.56 `hyprctl keyword windowrule` is rejected (\"Use eval\"); a session-only rule is `hyprctl eval \"hl.window_rule({…})\"` …"},
	{"2026-09-22", "pi", "Dedicated workspace per project", "Found the Omarchy 2.x runtime-rule pattern: `[hyprctl eval] 'hl.workspace_rule({...})'`. Verifying …"},
	{"2026-09-22", "pi", "Named workspace scrolling mode not applying", "… `hl.workspace_rule({ workspace = \"-1340\", layout = \"scrolling\" })` # ok — tiledLayout stays \"dwindle\" …"},
	{"2026-09-26", "codex", "Port brain-cli to Odin", "… recall --sync over the 103 Claude transcripts on this machine takes 0.7 s …"},
}

Proposal :: struct {
	bullet, agent, session, source: string,
}

PROPOSALS := [?]Proposal {
	{"**jm run_host events dangling** (aliases: sdl host segfault) — Host_Loop.events lived in context.temp_allocator, freed each frame; make it on the default allocator — jm/ui/sdl/host.odin — 2026-09-28", "claude", "Project logo design with jm:ui", "AI/LEARNINGS.md"},
	{"**hyprctl runtime window rule** (aliases: hyprctl keyword windowrule) — `hyprctl keyword` is rejected on the Lua parser; use `hyprctl eval \"hl.window_rule({…})\"` — brain-cli justfile — 2026-09-28", "claude", "Project logo design with jm:ui", "AI/LEARNINGS.md"},
	{"**brainfold** (aliases: brain, brain-cli product name) — the product is brainfold, the command stays brain — naming session — 2026-09-28", "claude", "Project logo design with jm:ui", "AI/MEMORY.md"},
}

Remote :: struct {
	name, url, last: string,
	ahead, behind:   int,
}

REMOTES := [?]Remote {
	{"origin", "mordaunt.dev/code/brain", "2 h ago", 2, 0},
	{"github", "github.com/jackmordaunt/brain", "2 h ago", 2, 0},
	{"sourcehut", "git.sr.ht/~jackmordaunt/brain", "yesterday", 5, 0},
}

AGENTS := [?]string{"claude", "pi", "codex"}

// ---------------------------------------------------------------- helpers

// role_label is one line of text at an M3 type role that takes part in
// layout, the way ui.label does in the theme font.
role_label :: proc(gtx: ^ui.Ctx, s: string, role: m3.Type_Role, color: ui.Color, key: u64 = 0, loc := #caller_location) -> ui.Dims {
	p := ui.widget_begin(gtx, key, loc)
	t := m3.shape_text(gtx, s, role)
	size := ui.constrain(gtx.constraints, {t.width, t.height})
	m3.draw_text(gtx, t, {0, 0}, color)
	return ui.widget_end(gtx, &p, {size, m3.baseline_of(t)})
}

// wrapped_label is role_label over several lines: s broken at spaces to
// fit width, as tall as it needs to be. A word wider than width gets a
// line of its own and overflows it.
wrapped_label :: proc(gtx: ^ui.Ctx, s: string, role: m3.Type_Role, color: ui.Color, width: f32, key: u64 = 0, loc := #caller_location) -> ui.Dims {
	p := ui.widget_begin(gtx, key, loc)
	st := m3.TYPE_STYLES[role]
	space := m3.shape_style(gtx, " ", st).width
	line := strings.builder_make(gtx.allocator)
	line_w, y: f32
	for word in strings.split(s, " ", gtx.allocator) {
		ww := m3.shape_style(gtx, word, st).width
		if line_w > 0 && line_w + space + ww > width {
			m3.draw_text(gtx, m3.shape_style(gtx, strings.to_string(line), st), {0, y}, color)
			y += st.line_height
			strings.builder_reset(&line)
			line_w = 0
		}
		if line_w > 0 {
			strings.write_byte(&line, ' ')
			line_w += space
		}
		strings.write_string(&line, word)
		line_w += ww
	}
	if line_w > 0 {
		m3.draw_text(gtx, m3.shape_style(gtx, strings.to_string(line), st), {0, y}, color)
		y += st.line_height
	}
	size := ui.constrain(gtx.constraints, {width, max(y, st.line_height)})
	return ui.widget_end(gtx, &p, {size, 0})
}

// content_width is the room a page has beside the rail, inside its inset.
content_width :: proc(m: ^Model) -> f32 {
	return max(m.window.x - RAIL_W - 2 * INSET, 320)
}

RAIL_W :: 96

// stat_card is a filled card with a small label, a large number and a note.
stat_card :: proc(gtx: ^ui.Ctx, label, value, note: string, w: f32, key: u64) {
	s := m3.scheme()
	c := m3.card(gtx, .Filled, key = key)
	defer ui.end(&c)
	col := ui.column(gtx, gap = 2)
	defer ui.end(&col)
	role_label(gtx, label, .Label_Medium, s[.On_Surface_Variant])
	role_label(gtx, value, .Headline_Medium, s[.On_Surface])
	role_label(gtx, note, .Body_Small, s[.On_Surface_Variant])
	r := ui.row(gtx)
	defer ui.end(&r)
	ui.spacer(gtx, w - 32)
}

// section is a titled block with an optional count chip.
section :: proc(gtx: ^ui.Ctx, title: string, count: int, note := "") {
	s := m3.scheme()
	ui.spacer(gtx, 8)
	r := ui.row(gtx, gap = 12, align = .Center)
	defer ui.end(&r)
	role_label(gtx, title, .Title_Medium, s[.On_Surface])
	if count > 0 {
		m3.chip(gtx, fmt.tprintf("%d", count), kind = .Suggestion, state = .Enabled)
	}
	if note != "" {
		role_label(gtx, note, .Body_Small, s[.On_Surface_Variant])
	}
}

page_header :: proc(gtx: ^ui.Ctx, m: ^Model, page: Page) {
	s := m3.scheme()
	col := ui.column(gtx, gap = 4)
	defer ui.end(&col)
	role_label(gtx, PAGE_TITLES[page], .Headline_Small, s[.On_Surface])
	role_label(gtx, PAGE_NOTES[page], .Body_Medium, s[.On_Surface_Variant])
	if m.status != "" {
		role_label(gtx, m.status, .Label_Large, s[.Primary])
	}
}

// ---------------------------------------------------------------- pages

page_activity :: proc(gtx: ^ui.Ctx, m: ^Model) {
	s := m3.scheme()
	w := content_width(m)
	col := ui.column(gtx, gap = 16)
	defer ui.end(&col)
	page_header(gtx, m, .Activity)
	{
		cw := (w - 2 * 16) / 3
		r := ui.row(gtx, gap = 16)
		defer ui.end(&r)
		stat_card(gtx, "lookups today", "42", "31 find · 11 recall", cw, 1)
		stat_card(gtx, "bytes served", "61 KB", "about 15k tokens · 1.5 KB a lookup", cw, 2)
		stat_card(gtx, "misses", "7", "3 new this week", cw, 3)
	}
	section(gtx, "Recent lookups", 0, "newest first")
	c := m3.card(gtx, .Outlined, padding = 0)
	defer ui.end(&c)
	rows := ui.column(gtx)
	defer ui.end(&rows)
	for l, i in LOOKUPS {
		hits := l.hits == 0 ? "no hits" : fmt.tprintf("%d hits", l.hits)
		bytes := l.bytes == 0 ? "" : fmt.tprintf("%.1f KB", f32(l.bytes) / 1024)
		m3.list_item(
			gtx,
			{
				overline = fmt.tprintf("%s · %s · %s", l.at, l.agent, l.kind),
				headline = l.query,
				supporting = hits,
				leading_icon = l.kind == "recall" ? .Chat_Bubble : .Search,
				trailing_icon = l.hits == 0 ? .Error : .None,
				trailing_text = bytes,
				divider = i + 1 < len(LOOKUPS),
				selection = .None,
			},
			width = w,
			key = u64(i + 1),
		)
	}
	_ = s
}

page_misses :: proc(gtx: ^ui.Ctx, m: ^Model) {
	s := m3.scheme()
	w := content_width(m)
	col := ui.column(gtx, gap = 12)
	defer ui.end(&col)
	page_header(gtx, m, .Misses)
	ui.spacer(gtx, 4)
	for x, i in MISSES {
		c := m3.card(gtx, .Filled, key = u64(i + 1))
		defer ui.end(&c)
		r := ui.row(gtx, gap = 16, align = .Center)
		defer ui.end(&r)
		{
			t := ui.column(gtx, gap = 2)
			defer ui.end(&t)
			role_label(gtx, x.query, .Title_Medium, s[.On_Surface])
			role_label(gtx, x.hint, .Body_Medium, s[.On_Surface_Variant])
			role_label(gtx, fmt.tprintf("missed %d× · last %s", x.misses, x.last), .Label_Small, s[.On_Surface_Variant])
			wide := ui.row(gtx)
			defer ui.end(&wide)
			ui.spacer(gtx, w - 32 - 16 - 300)
		}
		if m3.button(gtx, "Add synonym", kind = .Tonal, leading = .Add, size = .X_Small, key = 1) {
			m.status = "Synonym added to AI/synonyms.tsv"
		}
		if m3.button(gtx, "Write bullet", kind = .Outlined, leading = .Edit, size = .X_Small, key = 2) {
			m.status = "Opened AI/LEARNINGS.md at a new bullet"
		}
	}
}

finding_list :: proc(gtx: ^ui.Ctx, items: []Finding, w: f32, key: u64) {
	c := m3.card(gtx, .Outlined, padding = 0, key = key)
	defer ui.end(&c)
	rows := ui.column(gtx)
	defer ui.end(&rows)
	for f, i in items {
		m3.list_item(
			gtx,
			{
				overline = f.file,
				headline = f.handle,
				supporting = f.note,
				leading_icon = .Label,
				trailing_icon = .Arrow_Forward,
				divider = i + 1 < len(items),
				selection = .Click,
			},
			width = w,
			key = u64(i + 1),
		)
	}
}

page_doctor :: proc(gtx: ^ui.Ctx, m: ^Model) {
	s := m3.scheme()
	w := content_width(m)
	col := ui.column(gtx, gap = 12)
	defer ui.end(&col)
	page_header(gtx, m, .Doctor)
	{
		r := ui.row(gtx, gap = 16, align = .Center)
		defer ui.end(&r)
		role_label(gtx, "vault health", .Label_Large, s[.On_Surface_Variant])
		m3.linear_progress(gtx, 0.92, width = min(w - 240, 480))
		role_label(gtx, "92 · 8 findings in 162 bullets", .Label_Large, s[.On_Surface])
	}
	section(gtx, "Stale", len(STALE), "not verified in 90 days")
	finding_list(gtx, STALE[:], w, 1)
	section(gtx, "Thin aliases", len(THIN), "fewer than two")
	finding_list(gtx, THIN[:], w, 2)
	section(gtx, "Promote", len(PROMOTE), "returned often enough that a gate should carry them")
	finding_list(gtx, PROMOTE[:], w, 3)
	section(gtx, "Duplicates, dead wikilinks, orphans", 0, "none")
}

page_recall :: proc(gtx: ^ui.Ctx, m: ^Model) {
	s := m3.scheme()
	w := content_width(m)
	col := ui.column(gtx, gap = 12)
	defer ui.end(&col)
	page_header(gtx, m, .Recall)
	m3.search_bar(gtx, &m.query, placeholder = "What was said about…", width = min(w, 720))
	{
		r := ui.row(gtx, gap = 8, align = .Center)
		defer ui.end(&r)
		role_label(gtx, "agents", .Label_Medium, s[.On_Surface_Variant])
		for a, i in AGENTS {
			m3.chip(gtx, a, kind = .Filter, selected = &m.filters[i], key = u64(i + 1))
		}
		ui.spacer(gtx, 8)
		role_label(gtx, "5 hits · 0.9 KB · this session excluded", .Body_Small, s[.On_Surface_Variant])
	}
	c := m3.card(gtx, .Outlined, padding = 0)
	defer ui.end(&c)
	rows := ui.column(gtx)
	defer ui.end(&rows)
	for t, i in TURNS {
		m3.list_item(
			gtx,
			{
				overline = fmt.tprintf("%s · %s", t.date, t.agent),
				headline = t.title,
				supporting = t.snippet,
				three_line = true,
				leading_avatar = strings.to_upper(t.agent[:1], gtx.allocator),
				trailing_icon = .Content_Copy,
				divider = i + 1 < len(TURNS),
				selection = .Click,
			},
			width = w,
			key = u64(i + 1),
		)
	}
}

page_inbox :: proc(gtx: ^ui.Ctx, m: ^Model) {
	s := m3.scheme()
	w := content_width(m)
	col := ui.column(gtx, gap = 12)
	defer ui.end(&col)
	page_header(gtx, m, .Inbox)
	pending := 0
	for d in m.decided {
		if d == 0 {
			pending += 1
		}
	}
	section(gtx, "Proposed bullets", pending, "approve to append; edit opens the file")
	for p, i in PROPOSALS {
		c := m3.card(gtx, m.decided[i] == 0 ? .Filled : .Outlined, key = u64(i + 1))
		defer ui.end(&c)
		body := ui.column(gtx, gap = 8)
		defer ui.end(&body)
		{
			r := ui.row(gtx, gap = 8, align = .Center)
			defer ui.end(&r)
			m3.chip(gtx, p.agent, kind = .Assist, leading = .Account_Circle, state = .Enabled)
			m3.chip(gtx, p.source, kind = .Assist, leading = .Label, state = .Enabled)
			role_label(gtx, p.session, .Body_Small, s[.On_Surface_Variant])
		}
		wrapped_label(gtx, p.bullet, .Body_Medium, m.decided[i] == 2 ? s[.On_Surface_Variant] : s[.On_Surface], w - 32)
		{
			r := ui.row(gtx, gap = 8, align = .Center)
			defer ui.end(&r)
			switch m.decided[i] {
			case 0:
				if m3.button(gtx, "Approve", leading = .Check, size = .X_Small, key = 1) {
					m.decided[i] = 1
					m.status = "Appended to the vault and committed"
				}
				if m3.button(gtx, "Edit", kind = .Outlined, leading = .Edit, size = .X_Small, key = 2) {
					m.status = "Opened the proposal in your editor"
				}
				if m3.button(gtx, "Reject", kind = .Text, leading = .Close, size = .X_Small, key = 3) {
					m.decided[i] = 2
					m.status = "Rejected; the agent is told on its next find"
				}
			case 1:
				role_label(gtx, "approved", .Label_Large, s[.Primary])
			case 2:
				role_label(gtx, "rejected", .Label_Large, s[.On_Surface_Variant])
			}
			ui.spacer(gtx, w - 32 - 400)
		}
	}
}

page_vault :: proc(gtx: ^ui.Ctx, m: ^Model) {
	s := m3.scheme()
	w := content_width(m)
	col := ui.column(gtx, gap = 12)
	defer ui.end(&col)
	page_header(gtx, m, .Vault)
	{
		cw := (w - 2 * 16) / 3
		r := ui.row(gtx, gap = 16)
		defer ui.end(&r)
		stat_card(gtx, "vault", "~/Source/Personal/brain", "88 files · 504 KB · branch main", cw, 1)
		stat_card(gtx, "index", "rebuilt 14:20", "162 bullets · 2,140 lines · disposable", cw, 2)
		stat_card(gtx, "transcripts", "103", "claude on · pi on · codex off", cw, 3)
	}
	section(gtx, "Remotes", len(REMOTES), "push goes to all; pull takes the first that answers")
	{
		c := m3.card(gtx, .Outlined, padding = 0)
		defer ui.end(&c)
		rows := ui.column(gtx)
		defer ui.end(&rows)
		for r, i in REMOTES {
			state := r.ahead == 0 && r.behind == 0 ? "in sync" : fmt.tprintf("%d ahead · %d behind", r.ahead, r.behind)
			m3.list_item(
				gtx,
				{
					overline = r.url,
					headline = r.name,
					supporting = fmt.tprintf("%s · last push %s", state, r.last),
					leading_icon = .Lock,
					trailing_icon = r.ahead > 0 ? .Arrow_Upward : .Check,
					divider = i + 1 < len(REMOTES),
					selection = .None,
				},
				width = w,
				key = u64(i + 1),
			)
		}
	}
	{
		r := ui.row(gtx, gap = 8, align = .Center)
		defer ui.end(&r)
		if m3.button(gtx, "Push", leading = .Arrow_Upward, size = .Small, key = 1) {
			m.status = "Pushed 2 commits to origin, github and sourcehut"
		}
		if m3.button(gtx, "Pull", kind = .Tonal, leading = .Arrow_Downward, size = .Small, key = 2) {
			m.status = "Already up to date"
		}
		if m3.button(gtx, "Add remote", kind = .Outlined, leading = .Add, size = .Small, key = 3) {
			m.status = "brain remote add <url>"
		}
	}
	section(gtx, "Hosting", 0, "later, only end-to-end encrypted")
	{
		c := m3.card(gtx, .Filled)
		defer ui.end(&c)
		body := ui.column(gtx, gap = 8)
		defer ui.end(&body)
		m3.switch_(gtx, &m.hosted, label = "Encrypted brainfold remote", icons = true)
		wrapped_label(gtx, "For people without a git host. The server stores ciphertext; the key never leaves this machine.", .Body_Small, s[.On_Surface_Variant], min(w, 640) - 32)
		wide := ui.row(gtx)
		defer ui.end(&wide)
		ui.spacer(gtx, min(w, 640) - 32)
	}
}

// ---------------------------------------------------------------- frame

NAV := [?]m3.Nav_Item {
	{label = "Activity", icon = .Bolt, active_icon = .Bolt_Fill1},
	{label = "Misses", icon = .Help, active_icon = .Help_Fill1, badge = "7"},
	{label = "Doctor", icon = .Check_Circle, active_icon = .Check_Circle_Fill1},
	{label = "Recall", icon = .Chat_Bubble, active_icon = .Chat_Bubble_Fill1},
	{label = "Inbox", icon = .Inbox, active_icon = .Inbox_Fill1, badge = "3"},
	{label = "Vault", icon = .Lock, active_icon = .Lock_Fill1},
}

draw_desk :: proc(gtx: ^ui.Ctx, user: rawptr) {
	m := (^Model)(user)
	m.scheme = m.dark ? m3.dark_scheme() : m3.light_scheme()
	m3.use(&m.scheme)
	m3.use_fonts({0, 1, 2})
	m3.use_motion(.Standard)
	gtx.theme^ = m3.theme_for(&m.scheme, gtx.theme.font)
	s := &m.scheme
	m.window = gtx.constraints.max
	ui.fill(gtx.ops, ui.Rect{0, 0, m.window.x, m.window.y}, s[.Surface])

	r := ui.row(gtx, align = .Fill)
	defer ui.end(&r)
	m3.navigation_rail(gtx, NAV[:], &m.page)
	ui.flexible(gtx, 1)
	body := ui.column(gtx)
	defer ui.end(&body)
	{
		bar := ui.inset(gtx, {INSET, 12, 16, 4})
		defer ui.end(&bar)
		row := ui.row(gtx, align = .Center)
		defer ui.end(&row)
		role_label(gtx, "brainfold desk", .Title_Large, s[.On_Surface])
		ui.fill_space(gtx)
		if m3.icon_button(gtx, .Refresh, tooltip = "Rescan the vault") {
			m.status = "Index rebuilt from the markdown"
		}
		if m3.icon_button(gtx, m.dark ? .Light_Mode : .Dark_Mode, tooltip = m.dark ? "Light" : "Dark") {
			m.dark = !m.dark
		}
	}
	ui.flexible(gtx, 1)
	page := Page(clamp(m.page, 0, len(Page) - 1))
	sb := ui.scroll_box(gtx, key = u64(m.page + 1))
	defer ui.end(&sb)
	in_ := ui.inset(gtx, {INSET, 8, INSET, 48})
	defer ui.end(&in_)
	switch page {
	case .Activity:
		page_activity(gtx, m)
	case .Misses:
		page_misses(gtx, m)
	case .Doctor:
		page_doctor(gtx, m)
	case .Recall:
		page_recall(gtx, m)
	case .Inbox:
		page_inbox(gtx, m)
	case .Vault:
		page_vault(gtx, m)
	}
}

// desk_fonts is Noto Sans at 400, 500 and 700 for M3's type scale, or
// the platform default where Noto is not installed.
desk_fonts :: proc() -> []ui.Font_Ref {
	NOTO :: "/usr/share/fonts/noto/NotoSans-"
	paths := [3]string{NOTO + "Regular.ttf", NOTO + "Medium.ttf", NOTO + "Bold.ttf"}
	fonts := make([]ui.Font_Ref, 3)
	for p, i in paths {
		fonts[i] = {ui.Font_Id(i), os.exists(p) ? p : ui.default_font()}
	}
	return fonts
}

main :: proc() {
	m: Model
	m.filters = {true, true, true}
	m.scheme = m3.light_scheme()
	m.theme = m3.theme_for(&m.scheme, 0)
	fonts := desk_fonts()

	if len(os.args) == 1 {
		child.run({ui = draw_desk, user = &m, theme = &m.theme, fonts = fonts})
		return
	}

	size := ui.Size{WIDTH, HEIGHT}
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-dark":
			m.dark = true
		case "-page":
			if i + 1 >= len(args) {
				fmt.eprintln("-page needs a name")
				os.exit(2)
			}
			i += 1
			found := false
			for name, p in PAGE_TITLES {
				if strings.equal_fold(name, args[i]) {
					m.page = int(p)
					found = true
				}
			}
			if !found {
				fmt.eprintfln("no page %s", args[i])
				os.exit(2)
			}
		case "-size":
			if i + 1 >= len(args) {
				fmt.eprintln("-size needs WxH")
				os.exit(2)
			}
			i += 1
			w, _, h := strings.partition(args[i], "x")
			wi, wok := strconv.parse_int(w)
			hi, hok := strconv.parse_int(h)
			if !wok || !hok || wi <= 0 || hi <= 0 {
				fmt.eprintfln("-size wants WxH, got %s", args[i])
				os.exit(2)
			}
			size = {f32(wi), f32(hi)}
		case "-dump":
			p: ui.Probe
			ui.probe_init(&p, draw_desk, &m, size)
			defer ui.probe_destroy(&p)
			fmt.print(ui.probe_dump(&p))
		case "-png":
			if i + 1 >= len(args) {
				fmt.eprintln("-png needs a path")
				os.exit(2)
			}
			i += 1
			if !render.snapshot(draw_desk, &m, size, fonts, args[i]) {
				fmt.eprintfln("could not write %s", args[i])
				os.exit(1)
			}
		case:
			fmt.eprintfln("unknown flag %s", args[i])
			os.exit(2)
		}
	}
}

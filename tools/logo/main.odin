// The logo lab: a grid of candidate marks for brain, drawn as vector
// paths in a 100x100 unit box so one mark reads at 16 px and at 400 px
// alike. Run as the child half of a jm:ui hot-reload split (see
// tools/logo/host and `just logo`): edit this file, the watcher rebuilds
// it, the window updates. Click a tile to inspect it at every size.
//
//	logo                       run as the subprocess
//	logo -dump                 the first frame's scene ops as text
//	logo -png build/logo.png   render the first frame headlessly
//	logo -size 922x1030 -png … at that window size (default 1440x960)
//	logo -svg branding         write the mark and hero SVGs, light and dark
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "jm:ui"
import "jm:ui/child"
import "jm:ui/render"

WIDTH :: 1440
HEIGHT :: 960

SANS :: "/usr/share/fonts/liberation/LiberationSans-Regular.ttf"
MONO :: "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf"
FONT_SANS :: ui.Font_Id(0)
FONT_MONO :: ui.Font_Id(1)

COLS :: 3

Model :: struct {
	theme:       ui.Theme, // what gtx.theme points at; rewritten each frame
	light, dark: ui.Theme,
	is_dark:     bool,
	size:        f32, // mark size inside a tile, px
	selected:    int,
	accent:      int, // index into ACCENTS
}

// Ink is the logo's own palette, separate from the lab's UI theme.
Ink :: struct {
	ink, accent, paper, soft: ui.Color,
}

ACCENT_NAMES := [?]string{"coral", "indigo", "teal", "amber"}
ACCENTS := [?]ui.Color {
	{232, 93, 58, 255},
	{91, 91, 214, 255},
	{20, 150, 140, 255},
	{235, 160, 30, 255},
}

palette :: proc(m: ^Model) -> Ink {
	if m.is_dark {
		return {
			ink = {240, 238, 232, 255},
			accent = ACCENTS[m.accent],
			paper = {22, 22, 24, 255},
			soft = {70, 70, 74, 255},
		}
	}
	return {
		ink = {28, 27, 26, 255},
		accent = ACCENTS[m.accent],
		paper = {250, 250, 247, 255},
		soft = {200, 198, 192, 255},
	}
}

// invert swaps ink and paper: the mark on a dark tile.
invert :: proc(k: Ink) -> Ink {
	return {ink = k.paper, accent = k.accent, paper = k.ink, soft = k.soft}
}

// ---------------------------------------------------------------- paths

Path_B :: struct {
	verbs: [dynamic]ui.Path_Verb,
	pts:   [dynamic]ui.Point,
}

pb :: proc(gtx: ^ui.Ctx) -> Path_B {
	return {make([dynamic]ui.Path_Verb, gtx.allocator), make([dynamic]ui.Point, gtx.allocator)}
}

pb_move :: proc(b: ^Path_B, p: ui.Point) {
	append(&b.verbs, ui.Path_Verb.Move)
	append(&b.pts, p)
}

pb_cubic :: proc(b: ^Path_B, c1, c2, p: ui.Point) {
	append(&b.verbs, ui.Path_Verb.Cubic)
	append(&b.pts, c1, c2, p)
}

pb_done :: proc(gtx: ^ui.Ctx, b: ^Path_B) -> ui.Path_Ref {
	return {ui.add_path(gtx.ops, {b.verbs[:], b.pts[:]})}
}

on_circle :: proc(c: ui.Point, r, a: f32) -> ui.Point {
	return {c.x + r * math.cos(a), c.y + r * math.sin(a)}
}

// ---------------------------------------------------------------- marks

Mark_Proc :: proc(gtx: ^ui.Ctx, k: Ink)

Mark :: struct {
	name: string,
	draw: Mark_Proc,
}

MARKS := [?]Mark {
	{"caret + dot", mark_caret_dot},
	{"fissure", mark_fissure},
	{"fold", mark_fold},
	{"two lobes", mark_two_lobes},
	{"vault", mark_vault},
	{"graph b", mark_graph_b},
	{"note stack", mark_note_stack},
	{"search fold", mark_search_fold},
	{"monogram", mark_monogram},
}

stroke_w :: proc(w: f32) -> ui.Stroke_Style {
	return {width = w, cap = .Round, join = .Round}
}

// draw_mark draws m with its 100x100 box scaled to size at `at`.
draw_mark :: proc(gtx: ^ui.Ctx, m: Mark, at: ui.Point, size: f32, k: Ink) {
	ui.push_transform(gtx.ops, ui.translate(at.x, at.y))
	ui.push_transform(gtx.ops, ui.scale(size / 100, size / 100))
	m.draw(gtx, k)
	ui.pop_transform(gtx.ops)
	ui.pop_transform(gtx.ops)
}

// 1. A terminal caret and a dot make a lowercase b.
mark_caret_dot :: proc(gtx: ^ui.Ctx, k: Ink) {
	ui.fill(gtx.ops, ui.Round_Rect{{26, 12, 16, 76}, 8}, k.ink)
	ui.fill(gtx.ops, ui.circle({64, 66}, 22), k.accent)
}

// 2. Bullet lines fill a disc; a wandering gap splits it into two
// hemispheres. Notes make a brain. The chosen mark: fissure_bars is the
// geometry, shared with the SVG writer so the pack and the lab agree.
mark_fissure :: proc(gtx: ^ui.Ctx, k: Ink) {
	bars, n := fissure_bars()
	for b in bars[:n] {
		ui.fill(gtx.ops, b, k.ink)
	}
}

FISSURE_R :: 38 // the disc's radius
FISSURE_H :: 8 // a bar's height; its ends are semicircles
FISSURE_GAP :: 8 // the fissure's width

// fissure_bars is the mark's bars in its 100x100 box: one row per line,
// split where the fissure crosses it, pieces under 10 wide dropped.
fissure_bars :: proc() -> (bars: [12]ui.Round_Rect, n: int) {
	c := ui.Point{50, 50}
	ys := [?]f32{20, 32, 44, 56, 68, 80}
	xf := [?]f32{56, 46, 54, 44, 55, 47} // where the fissure crosses each row
	for y, i in ys {
		dy := y - c.y
		w := math.sqrt(FISSURE_R * FISSURE_R - dy * dy)
		l, r := c.x - w, c.x + w
		gl, gr := xf[i] - FISSURE_GAP / 2, xf[i] + FISSURE_GAP / 2
		if gl - l >= 10 {
			bars[n] = {{l, y - FISSURE_H / 2, gl - l, FISSURE_H}, FISSURE_H / 2}
			n += 1
		}
		if r - gr >= 10 {
			bars[n] = {{gr, y - FISSURE_H / 2, r - gr, FISSURE_H}, FISSURE_H / 2}
			n += 1
		}
	}
	return
}

// 3. One gyrus inside a ring: the brain reduced to a single fold.
mark_fold :: proc(gtx: ^ui.Ctx, k: Ink) {
	ui.stroke(gtx.ops, ui.circle({50, 50}, 36), k.ink, stroke_w(9))
	b := pb(gtx)
	pb_move(&b, {29, 62})
	pb_cubic(&b, {29, 30}, {50, 30}, {50, 52})
	pb_cubic(&b, {50, 72}, {71, 72}, {71, 40})
	ui.stroke(gtx.ops, pb_done(gtx, &b), k.accent, stroke_w(9))
}

// 4. Two lobes: what is known (solid) and what is being searched (open).
mark_two_lobes :: proc(gtx: ^ui.Ctx, k: Ink) {
	ui.fill(gtx.ops, ui.Round_Rect{{18, 22, 30, 56}, 15}, k.ink)
	ui.stroke(gtx.ops, ui.Round_Rect{{55.5, 25.5, 23, 49}, 11.5}, k.accent, stroke_w(7))
}

// 5. A vault door: rounded square, dial, four ticks.
mark_vault :: proc(gtx: ^ui.Ctx, k: Ink) {
	ui.stroke(gtx.ops, ui.Round_Rect{{16, 16, 68, 68}, 16}, k.ink, stroke_w(8))
	ui.stroke(gtx.ops, ui.circle({50, 50}, 12), k.accent, stroke_w(8))
	for i in 0 ..< 4 {
		a := f32(i) * math.PI / 2 + math.PI / 4
		ui.stroke(gtx.ops, ui.line(gtx, on_circle({50, 50}, 21, a), on_circle({50, 50}, 27, a)), k.ink, stroke_w(6))
	}
}

// 6. A lowercase b as a graph: nodes and edges, one node lit.
mark_graph_b :: proc(gtx: ^ui.Ctx, k: Ink) {
	a, d, bb, c := ui.Point{30, 16}, ui.Point{30, 50}, ui.Point{30, 84}, ui.Point{72, 66}
	ui.stroke(gtx.ops, ui.polyline(gtx, []ui.Point{a, bb, c, d}), k.ink, stroke_w(6))
	for p in ([]ui.Point{a, d, bb}) {
		ui.fill(gtx.ops, ui.circle(p, 8), k.ink)
	}
	ui.fill(gtx.ops, ui.circle(c, 9), k.accent)
}

// 7. Two notes, one behind the other; the front one has a bullet.
mark_note_stack :: proc(gtx: ^ui.Ctx, k: Ink) {
	ui.stroke(gtx.ops, ui.Round_Rect{{32.5, 12.5, 49, 59}, 10}, k.ink, stroke_w(5))
	ui.fill(gtx.ops, ui.Round_Rect{{18, 26, 54, 62}, 10}, k.ink)
	ui.fill(gtx.ops, ui.circle({31, 45}, 4), k.accent)
	ui.fill(gtx.ops, ui.Round_Rect{{40, 41.5, 22, 7}, 3.5}, k.paper)
	ui.fill(gtx.ops, ui.Round_Rect{{27, 56, 32, 7}, 3.5}, k.paper)
	ui.fill(gtx.ops, ui.Round_Rect{{27, 69, 24, 7}, 3.5}, k.paper)
}

// 8. A magnifier whose lens holds the fold: search a brain.
mark_search_fold :: proc(gtx: ^ui.Ctx, k: Ink) {
	ui.stroke(gtx.ops, ui.circle({44, 44}, 26), k.ink, stroke_w(8))
	ui.stroke(gtx.ops, ui.line(gtx, {64, 64}, {84, 84}), k.ink, stroke_w(10))
	b := pb(gtx)
	pb_move(&b, {31, 52})
	pb_cubic(&b, {31, 33}, {44, 33}, {44, 44})
	pb_cubic(&b, {44, 55}, {57, 55}, {57, 36})
	ui.stroke(gtx.ops, pb_done(gtx, &b), k.accent, stroke_w(7))
}

// 9. The app-icon baseline: a bold mono b knocked out of a rounded square.
mark_monogram :: proc(gtx: ^ui.Ctx, k: Ink) {
	ui.fill(gtx.ops, ui.Round_Rect{{8, 8, 84, 84}, 22}, k.ink)
	draw_mono_text(gtx, "b", {50, 50}, 70, k.paper, centered = true)
}

// draw_mono_text draws s in the mono face: top-left at pos, or centred on pos.
draw_mono_text :: proc(gtx: ^ui.Ctx, s: string, pos: ui.Point, size: f32, color: ui.Color, centered := false) {
	run := ui.shape(gtx.shaper, FONT_MONO, size, s, gtx.allocator)
	m := ui.metrics(gtx.shaper, FONT_MONO, size)
	p := pos
	if centered {
		p = {pos.x - run.advance / 2, pos.y - (m.ascent - m.descent) / 2 - size * 0.12}
	}
	ui.glyphs(gtx.ops, ui.add_run(gtx.ops, run), {p.x, p.y + m.ascent}, color)
}

// ---------------------------------------------------------------- the pack

// write_pack writes the fissure mark and the hero lockup as SVG, one of
// each per scheme, into dir: mark-{light,dark}.svg on a transparent
// ground, and hero-{light,dark}.svg with the wordmark beside the mark.
// `just branding` rasterises them. Colours are the lab's own Ink.
write_pack :: proc(dir: string) -> bool {
	light := Ink{ink = {28, 27, 26, 255}, paper = {250, 250, 247, 255}}
	dark := Ink{ink = {240, 238, 232, 255}, paper = {22, 22, 24, 255}}
	ok := true
	ok &&= write_svg(fmt.tprintf("%s/mark-light.svg", dir), mark_svg(light))
	ok &&= write_svg(fmt.tprintf("%s/mark-dark.svg", dir), mark_svg(dark))
	ok &&= write_svg(fmt.tprintf("%s/hero-light.svg", dir), hero_svg(light))
	ok &&= write_svg(fmt.tprintf("%s/hero-dark.svg", dir), hero_svg(dark))
	return ok
}

write_svg :: proc(path, body: string) -> bool {
	if err := os.write_entire_file(path, transmute([]byte)body); err != nil {
		fmt.eprintfln("%s: %v", path, err)
		return false
	}
	return true
}

hex :: proc(c: ui.Color) -> string {
	return fmt.tprintf("#%02x%02x%02x", c.r, c.g, c.b)
}

// write_fissure_rects is the mark's bars as <rect> elements, one per line.
write_fissure_rects :: proc(b: ^strings.Builder, ink: ui.Color) {
	bars, n := fissure_bars()
	for r in bars[:n] {
		fmt.sbprintfln(b, `  <rect x="%.3f" y="%.3f" width="%.3f" height="%.3f" rx="%.1f" fill="%s"/>`, r.rect.x, r.rect.y, r.rect.w, r.rect.h, r.radius, hex(ink))
	}
}

mark_svg :: proc(k: Ink) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="512" height="512" role="img" aria-label="brainfold">`)
	write_fissure_rects(&b, k.ink)
	fmt.sbprint(&b, "</svg>\n")
	return strings.to_string(b)
}

// hero_svg is the lockup: the mark at 140 px and the brainfold wordmark in a mono
// face. The font-family names JetBrains Mono first and ends in the generic
// monospace; nothing is embedded, so the mark is the constant part.
hero_svg :: proc(k: Ink) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 700 200" width="700" height="200" role="img" aria-label="brainfold">`)
	fmt.sbprintln(&b, `  <g transform="translate(40 30) scale(1.4)">`)
	write_fissure_rects(&b, k.ink)
	fmt.sbprintln(&b, `  </g>`)
	fmt.sbprintfln(&b, `  <text x="210" y="130" font-family="JetBrains Mono, JetBrainsMono Nerd Font, SFMono-Regular, Menlo, Consolas, monospace" font-weight="700" font-size="84" fill="%s">brainfold</text>`, hex(k.ink))
	fmt.sbprint(&b, "</svg>\n")
	return strings.to_string(b)
}

// ---------------------------------------------------------------- the lab

draw_tile :: proc(gtx: ^ui.Ctx, m: ^Model, i: int, k: Ink, tile: f32) {
	p := ui.widget_begin(gtx, u64(i + 1))
	th := gtx.theme
	size := ui.Size{tile, tile + 30}
	rr := ui.Round_Rect{{0, 0, size.x, size.y}, 14}
	ui.fill(gtx.ops, rr, th.surface)
	if m.selected == i {
		ui.stroke(gtx.ops, ui.Round_Rect{{1, 1, size.x - 2, size.y - 2}, 13}, k.accent, {width = 2})
	}
	s := min(m.size, tile - 20)
	draw_mark(gtx, MARKS[i], {(tile - s) / 2, (tile - s) / 2}, s, k)
	ui.text(gtx, fmt.tprintf("%d  %s", i + 1, MARKS[i].name), {16, tile - 2}, {color = th.muted, size = th.small_size})
	ui.input_area(gtx.ops, p.id, rr, {.Press})
	for e in ui.events(gtx, p.id) {
		if e.kind == .Press {
			m.selected = i
		}
	}
	ui.widget_end(gtx, &p, {size, 0})
}

// draw_detail shows the selected mark at every size it must survive, the
// wordmark lockup, and the mark on inverted paper, in a w by h panel:
// the size row and the inverted card give up their largest pieces first
// as w shrinks.
draw_detail :: proc(gtx: ^ui.Ctx, m: ^Model, k: Ink, w, h: f32) {
	p := ui.widget_begin(gtx)
	th := gtx.theme
	mk := MARKS[m.selected]
	PAD :: 24
	inner := w - 2 * PAD
	ui.fill(gtx.ops, ui.Round_Rect{{0, 0, w, h}, 14}, th.surface)

	x, y: f32 = PAD, 22
	ui.text(gtx, fmt.tprintf("%d  %s", m.selected + 1, mk.name), {x, y}, {size = th.heading_size})
	y += 48

	// sizes, bottom-aligned on one row; as many as fit
	sizes := [?]f32{16, 24, 32, 48, 96, 144}
	n, used, biggest := 0, f32(0), f32(0)
	for s in sizes {
		if used + s > inner {
			break
		}
		used += s + 14
		biggest = s
		n += 1
	}
	base := y + biggest
	for s in sizes[:n] {
		draw_mark(gtx, mk, {x, base - s}, s, k)
		ui.text(gtx, fmt.tprintf("%.0f", s), {x, base + 8}, {color = th.muted, size = th.small_size})
		x += s + 14
	}
	y = base + 40

	// lockup: mark + wordmark
	x = PAD
	draw_mark(gtx, mk, {x, y}, 56, k)
	draw_mono_text(gtx, "brainfold", {x + 70, y + 4}, min(48, (inner - 70) / 5.6), k.ink)
	y += 84

	// inverted paper: the big mark, the wordmark beside it, and when there
	// is room the two smallest sizes in the corner
	inv := invert(k)
	big := clamp(inner - 48 - 130, 64, 144)
	ih := big + 56
	ui.fill(gtx.ops, ui.Round_Rect{{PAD, y, inner, ih}, 16}, inv.paper)
	draw_mark(gtx, mk, {PAD + 24, y + 28}, big, inv)
	draw_mono_text(gtx, "brainfold", {PAD + 24 + big + 14, y + ih - 28 - 40}, min(32, (inner - 48 - big - 14) / 5.6), inv.ink)
	if inner >= 400 {
		draw_mark(gtx, mk, {PAD + inner - 24 - 16, y + 24}, 16, inv)
		draw_mark(gtx, mk, {PAD + inner - 24 - 32, y + 56}, 32, inv)
	}

	ui.widget_end(gtx, &p, {{w, h}, 0})
}

draw_toolbar_main :: proc(gtx: ^ui.Ctx, m: ^Model, slider_w: f32) {
	th := gtx.theme
	ui.label(gtx, "brainfold · logo lab", {size = th.heading_size})
	ui.spacer(gtx, 12)
	ui.checkbox(gtx, "dark", &m.is_dark)
	ui.label(gtx, fmt.tprintf("size %.0f", m.size), {color = th.muted})
	ui.slider(gtx, &m.size, 40, 230, "size", {width = slider_w})
}

draw_toolbar_accent :: proc(gtx: ^ui.Ctx, m: ^Model) {
	sel: [len(ACCENTS)]bool
	sel[m.accent] = true
	if i := ui.segmented_button(gtx, ACCENT_NAMES[:], sel[:]); i >= 0 {
		m.accent = i
	}
}

// The lab fits whatever window it is given: the detail panel takes about
// a third of the width, the grid the rest, and the tiles shrink until the
// three rows fit the height. Below 1100 px the toolbar wraps to two rows.
draw_lab :: proc(gtx: ^ui.Ctx, user: rawptr) {
	m := (^Model)(user)
	m.theme = m.dark if m.is_dark else m.light
	th := gtx.theme
	k := palette(m)
	ui.fill(gtx.ops, ui.Rect{0, 0, gtx.constraints.max.x, gtx.constraints.max.y}, th.bg)

	MARGIN :: 20
	GAP :: 12
	avail := ui.Size{gtx.constraints.max.x - 2 * MARGIN, gtx.constraints.max.y - 2 * MARGIN}
	narrow := avail.x < 1100
	toolbar_h: f32 = 96 if narrow else 44
	body_h := avail.y - toolbar_h - 16
	detail_w := clamp(avail.x * 0.36, 320, 560)
	grid_w := avail.x - 24 - detail_w
	rows := (len(MARKS) + COLS - 1) / COLS
	tile := min((grid_w - f32(COLS - 1) * GAP) / COLS, (body_h - f32(rows - 1) * GAP) / f32(rows) - 30)
	tile = max(tile, 100)
	grid_h := f32(rows) * (tile + 30) + f32(rows - 1) * GAP

	pad := ui.inset(gtx, ui.pad_all(MARGIN))
	defer ui.end(&pad)
	col := ui.column(gtx, gap = 16)
	defer ui.end(&col)

	if narrow {
		tb := ui.column(gtx, gap = 8)
		defer ui.end(&tb)
		{
			bar := ui.row(gtx, gap = 16, align = .Center)
			defer ui.end(&bar)
			draw_toolbar_main(gtx, m, 140)
		}
		{
			bar := ui.row(gtx, gap = 16, align = .Center)
			defer ui.end(&bar)
			draw_toolbar_accent(gtx, m)
		}
	} else {
		bar := ui.row(gtx, gap = 20, align = .Center)
		defer ui.end(&bar)
		draw_toolbar_main(gtx, m, 180)
		draw_toolbar_accent(gtx, m)
	}
	{
		body := ui.row(gtx, gap = 24)
		defer ui.end(&body)
		{
			grid := ui.column(gtx, gap = GAP)
			defer ui.end(&grid)
			for r in 0 ..< rows {
				rw := ui.row(gtx, gap = GAP, key = u64(r + 1))
				defer ui.end(&rw)
				for c in 0 ..< COLS {
					i := r * COLS + c
					if i < len(MARKS) {
						draw_tile(gtx, m, i, k, tile)
					}
				}
			}
		}
		draw_detail(gtx, m, k, detail_w, grid_h)
	}
}

main :: proc() {
	m := Model {
		light = ui.light_theme(FONT_SANS),
		dark  = ui.dark_theme(FONT_SANS),
		size  = 140,
	}
	m.theme = m.light
	fonts := []ui.Font_Ref{{FONT_SANS, SANS}, {FONT_MONO, MONO}}

	if len(os.args) == 1 {
		child.run({ui = draw_lab, user = &m, theme = &m.theme, fonts = fonts})
		return
	}

	size := ui.Size{WIDTH, HEIGHT}
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
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
			ui.probe_init(&p, draw_lab, &m, size)
			defer ui.probe_destroy(&p)
			fmt.print(ui.probe_dump(&p))
		case "-svg":
			if i + 1 >= len(args) {
				fmt.eprintln("-svg needs a directory")
				os.exit(2)
			}
			i += 1
			if !write_pack(args[i]) {
				os.exit(1)
			}
		case "-png":
			if i + 1 >= len(args) {
				fmt.eprintln("-png needs a path")
				os.exit(2)
			}
			i += 1
			if !render.snapshot(draw_lab, &m, size, fonts, args[i]) {
				fmt.eprintfln("could not write %s", args[i])
				os.exit(1)
			}
		case:
			fmt.eprintfln("unknown flag %s", args[i])
			os.exit(2)
		}
	}
}

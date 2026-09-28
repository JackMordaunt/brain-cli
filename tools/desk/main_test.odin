package main

import "core:testing"
import "jm:ui"

// Every page draws under the probe (no window, a stub shaper) without
// tripping a layout assertion, and records something: a page that
// panics or paints nothing after a hot reload is the failure this
// catches.
@(test)
every_page_draws :: proc(t: ^testing.T) {
	for _, page in PAGE_TITLES {
		m: Model
		m.page = int(page)
		p: ui.Probe
		ui.probe_init(&p, draw_desk, &m, {WIDTH, HEIGHT})
		defer ui.probe_destroy(&p)
		dump := ui.probe_dump(&p)
		testing.expect(t, len(dump) > 0, PAGE_TITLES[page])
	}
}

// The rail's items and the pages are one list, in the same order.
@(test)
rail_matches_pages :: proc(t: ^testing.T) {
	testing.expect_value(t, len(NAV), len(Page))
	for item, i in NAV {
		testing.expect_value(t, item.label, PAGE_TITLES[Page(i)])
	}
}

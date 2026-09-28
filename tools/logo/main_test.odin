package main

import "core:fmt"
import "core:strings"
import "core:testing"

// The mark is twelve bars, every one inside the 100x100 box, six rows of
// two: a bar dropped or spilling out is a change to the logo, not a tweak.
@(test)
fissure_is_twelve_bars_in_the_box :: proc(t: ^testing.T) {
	bars, n := fissure_bars()
	testing.expect_value(t, n, 12)
	for b in bars[:n] {
		r := b.rect
		testing.expect(t, r.x >= 0 && r.y >= 0 && r.x + r.w <= 100 && r.y + r.h <= 100, "bar outside the box")
		testing.expect(t, r.w >= 10, "bar narrower than the 10 unit floor")
		testing.expect_value(t, b.radius, f32(FISSURE_H) / 2)
	}
}

// The SVG carries every bar as one <rect> with the bar's own geometry and
// the scheme's ink, and the hero carries the wordmark.
@(test)
svg_carries_each_bar :: proc(t: ^testing.T) {
	k := Ink{ink = {28, 27, 26, 255}}
	svg := mark_svg(k)
	bars, n := fissure_bars()
	testing.expect_value(t, strings.count(svg, "<rect "), n)
	for b in bars[:n] {
		want := fmt.tprintf(`<rect x="%.3f" y="%.3f" width="%.3f" height="%.3f" rx="%.1f" fill="#1c1b1a"/>`, b.rect.x, b.rect.y, b.rect.w, b.rect.h, b.radius)
		testing.expect(t, strings.contains(svg, want), want)
	}
	testing.expect(t, strings.contains(hero_svg(k), ">brain</text>"), "wordmark missing")
}

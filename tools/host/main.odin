// The window half of every hot-reloaded tool in this repository: it owns
// the SDL window and respawns the child whenever the pointer file names a
// new build. It never links the child's code, so a rebuild of the child
// is all a change takes. See `just hot`, `just logo` and `just desk`.
//
//	host build/logo.watch "brainfold · logo lab" 1440x960
//	host build/debug/logo                            a fixed child, default title and size
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "jm:ui/sdl"

main :: proc() {
	if len(os.args) < 2 || len(os.args) > 4 {
		fmt.eprintln("usage: host <pointer-file | child exe> [title] [WxH]")
		os.exit(2)
	}
	app := sdl.Host_App {
		title  = "brainfold",
		width  = 1440,
		height = 960,
		clear  = {250, 250, 247, 255},
	}
	if len(os.args) >= 3 {
		app.title = os.args[2]
	}
	if len(os.args) == 4 {
		w, _, h := strings.partition(os.args[3], "x")
		wi, wok := strconv.parse_int(w)
		hi, hok := strconv.parse_int(h)
		if !wok || !hok || wi <= 0 || hi <= 0 {
			fmt.eprintfln("host: size wants WxH, got %s", os.args[3])
			os.exit(2)
		}
		app.width, app.height = wi, hi
	}
	if strings.has_suffix(os.args[1], ".watch") {
		app.watch = os.args[1]
	} else {
		app.child = {os.args[1]}
	}
	sdl.run_host(app)
}

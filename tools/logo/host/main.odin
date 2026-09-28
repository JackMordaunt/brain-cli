// The window half of the logo lab: owns the SDL window and respawns the
// tools/logo child whenever the pointer file names a new build. It never
// links the marks' own code, so a rebuild of tools/logo is all a change
// takes. See `just logo`.
//
//	logo-host build/logo.watch          follow the watcher's builds
//	logo-host build/debug/logo          a fixed child, no reload
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "jm:ui/sdl"

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: logo-host <pointer-file | child exe>")
		os.exit(2)
	}
	app := sdl.Host_App {
		title  = "brain · logo lab",
		width  = 1440,
		height = 960,
		clear  = {250, 250, 247, 255},
	}
	if strings.has_suffix(os.args[1], ".watch") {
		app.watch = os.args[1]
	} else {
		app.child = {os.args[1]}
	}
	sdl.run_host(app)
}

#+feature dynamic-literals
package term

import "core:strings"
import "core:terminal"
import "core:testing"

// Env is a fake environment: only the keys it holds are set.
Env :: map[string]string

env_lookup :: proc(key: string, data: rawptr) -> string {
	return (^Env)(data)[key]
}

style_of :: proc(tty: bool, env: Env, mode := Mode.Auto) -> Style {
	env := env
	defer delete(env)
	return detect(tty, mode, env_lookup, &env)
}

@(test)
a_terminal_is_styled :: proc(t: ^testing.T) {
	testing.expect_value(t, style_of(true, {"TERM" = "xterm-256color"}).depth, terminal.Color_Depth.Eight_Bit)
	testing.expect_value(t, style_of(true, {"TERM" = "xterm", "COLORTERM" = "truecolor"}).depth, terminal.Color_Depth.True_Color)
}

@(test)
a_pipe_is_plain :: proc(t: ^testing.T) {
	testing.expect_value(t, style_of(false, {"TERM" = "xterm-256color"}), Style{})
}

@(test)
an_agent_in_a_terminal_is_plain :: proc(t: ^testing.T) {
	for k in AGENT_VARS {
		testing.expect_value(t, style_of(true, {"TERM" = "xterm-256color", k = "1"}), Style{})
	}
}

@(test)
no_color_and_dumb_are_plain :: proc(t: ^testing.T) {
	testing.expect_value(t, style_of(true, {"TERM" = "xterm", "NO_COLOR" = "1"}), Style{})
	testing.expect_value(t, style_of(true, {"TERM" = "dumb"}), Style{})
	// With nothing in the environment, Unix has no terminal to speak of;
	// Windows asks the console itself, so the answer is whatever this
	// console took (release run 36921260165 saw Eight_Bit on the runner).
	when ODIN_OS == .Windows {
		testing.expect_value(t, style_of(true, {}), Style{depth = terminal.color_depth})
	} else {
		testing.expect_value(t, style_of(true, {}), Style{})
	}
}

@(test)
an_explicit_mode_wins :: proc(t: ^testing.T) {
	testing.expect(t, styled(style_of(false, {"AI_AGENT" = "x", "NO_COLOR" = "1"}, .Always)))
	testing.expect_value(t, style_of(true, {"TERM" = "xterm"}, .Never), Style{})
	testing.expect(t, styled(style_of(false, {"CLICOLOR_FORCE" = "1"})))
	testing.expect_value(t, style_of(false, {"CLICOLOR_FORCE" = "0"}), Style{})
}

@(test)
paint_writes_codes_only_when_styled :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	paint(&b, {}, {.Bold}, "Ask")
	testing.expect_value(t, strings.to_string(b), "Ask")
	strings.builder_reset(&b)
	paint(&b, {depth = .Three_Bit}, {.Bold, .Dim}, "Ask")
	testing.expect_value(t, strings.to_string(b), "\x1b[1;2mAsk\x1b[0m")
}

@(test)
parse_mode_reads_the_three_words :: proc(t: ^testing.T) {
	for word, want in ([Mode]string{.Auto = "auto", .Always = "always", .Never = "never"}) {
		m, ok := parse_mode(word)
		testing.expect(t, ok && m == want, word)
	}
	_, ok := parse_mode("sometimes")
	testing.expect(t, !ok)
}

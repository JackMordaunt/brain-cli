package brain

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:text/regex"
import "core:unicode"
import "core:unicode/utf8"

import "jm:path"
import "jm:sh"

// Every bullet ends up in an agent's context, so a bullet is a way to steer
// an agent. The guard refuses the text that does it without a model's help.
//
// Two tiers. The always rules catch what no honest fact needs: characters a
// reviewer cannot see, control characters, words that mix lookalike scripts,
// and Markdown images, which a Markdown viewer fetches from their URL. The strict rules
// narrow a fact to plain prose about the world: no URLs, addresses, paths,
// markup, encoded runs, words addressing the reader, or wording that reads
// as an instruction. They would fail most of a developer's own notes, so a
// vault opts in: `lint strict` in POLICY_FILE, or `brain lint --strict`.
//
// Strict rules read the handle, aliases and fact, not the source, which
// propose fills with the caller's name.

POLICY_FILE :: ".brain/policy"

// Guard holds the strict rules' patterns, compiled once per command, and
// the arena and capture their matches reuse, so a vault's worth of lines
// costs one buffer rather than a temp allocation per match.
Guard :: struct {
	strict:  bool,
	rules:   [dynamic]Guard_Rule,
	arena:   virtual.Arena,
	capture: regex.Capture,
}

Guard_Rule :: struct {
	name, message: string,
	re:            regex.Regular_Expression,
}

// Inputs to the strict patterns: the reader's names, the words that make a
// line an instruction, and verbs that make a fact open as a command.
READER_WORDS :: `you|your|yours|yourself|yourselves|assistant|assistants|chatbot|llm|llms|claude|chatgpt|gpt|gemini|copilot|prompt|prompts|instruction|instructions`
COMMAND_WORDS :: `ignore|disregard|forget|override|obey|pretend|must|always|never|should|do not|don't`
COMMAND_VERBS :: `use|run|send|email|call|open|read|write|delete|remove|share|click|tell|reply|respond|include|add|copy|forward|upload|download|visit|fetch|execute|print|say|output|install|paste|post|reveal|show|list|return|answer`
TLDS :: `com|net|org|io|dev|ai|app|co|me|info|biz|xyz|gov|edu|us|uk|au|de|fr|nl|ca|cloud|site|online|tech`

// worktree_strict is whether the vault's working tree asks for the strict
// rules; committed_strict, whether its last commit does.
worktree_strict :: proc(vault: string) -> bool {
	text, err := path.read(path.join(vault, POLICY_FILE))
	return err == nil && policy_strict(text)
}

committed_strict :: proc(vault: string) -> bool {
	r := sh.exec({"git", "show", strings.concatenate({"HEAD:", POLICY_FILE})}, {dir = vault})
	return r.ok && policy_strict(r.stdout)
}

policy_strict :: proc(text: string) -> bool {
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		if strings.join(strings.fields(raw), " ") == "lint strict" {
			return true
		}
	}
	return false
}

guard_init :: proc(g: ^Guard, strict: bool) {
	g.strict = strict
	if !strict {
		return
	}
	_ = virtual.arena_init_growing(&g.arena)
	g.capture = regex.preallocate_capture()
	add :: proc(g: ^Guard, name, message, pattern: string) {
		re, err := regex.create(pattern, {.Case_Insensitive})
		assert(err == nil, pattern)
		append(&g.rules, Guard_Rule{name, message, re})
	}
	add(g, "url", "carries a URL (%s); name the source instead", `\b[a-z][a-z0-9+.-]*://\S*|\bwww\.\S+|\b(?:mailto|data|javascript):\S+`)
	add(g, "address", "names an address (%s)", `[a-z0-9._%+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}|\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b|\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:` + TLDS + `)\b`)
	add(g, "path", "names a file path (%s)", `(?:^|[\s("'])(?:~|\.\.?)?/[\w.-]+|\b[a-z]:\\\S*`)
	add(g, "markup", "carries code, HTML, a link or a template token (%s)", "`" + `|<[a-z/!?]|\]\(|\{\{|\}\}|<\||\|>|\[/?inst\]|<<sys>>|\b(?:human|assistant|system|user):`)
	add(g, "encoded", "carries an encoded run (%s)", `[a-z0-9+/_-]{32,}|\b[0-9a-f]{24,}\b`)
	add(g, "reader", "addresses its reader (%s); a fact describes the world, not whoever reads it", `\b(?:` + READER_WORDS + `)\b`)
	add(g, "command", "reads as an instruction (%s); say what is true, not what to do", `\b(?:` + COMMAND_WORDS + `)\b|(?:^|[.;!?]\s+)(?:` + COMMAND_VERBS + `)\b`)
}

guard_destroy :: proc(g: ^Guard) {
	for r in g.rules {
		regex.destroy(r.re)
	}
	delete(g.rules)
	if g.strict {
		regex.destroy_capture(g.capture)
		virtual.arena_destroy(&g.arena)
	}
}

// flag appends a failure at the place at names.
flag :: proc(findings: ^[dynamic]Finding, at: Finding, rule, message: string) {
	f := at
	f.fail, f.rule, f.message = true, rule, message
	append(findings, f)
}

// guard_text applies the always rules to any line the index reads.
guard_text :: proc(at: Finding, line: string, findings: ^[dynamic]Finding) {
	for r, i in line {
		rule, msg := "hidden", ""
		switch {
		case r == utf8.RUNE_ERROR:
			msg = "is not valid UTF-8"
		case is_hidden(r, i > 0 ? prev_rune(line, i) : 0):
			msg = fmt.aprintf("carries an invisible character (U+%04X) that hides text from a reviewer", r)
		case r < 0x20 && r != '\t', r >= 0x7f && r <= 0x9f:
			msg = fmt.aprintf("carries a control character (U+%04X)", r)
		case r >= 0xff01 && r <= 0xff5e, r >= 0x1d400 && r <= 0x1d7ff:
			// Fullwidth and mathematical letters read as words but match no word rule.
			rule, msg = "script", fmt.aprintf("writes letters in a lookalike form (U+%04X)", r)
		}
		if msg != "" {
			flag(findings, at, rule, msg)
			break
		}
	}
	if w := mixed_script_word(line); w != "" {
		flag(findings, at, "script", fmt.aprintf("mixes alphabets in %q; lookalike letters disguise text", w))
	}
	if strings.contains(line, "![") {
		flag(findings, at, "image", "embeds an image, which fetches a URL when rendered")
	}
}

// guard_check appends a failure for each rule a bullet line breaks. A line
// that does not parse passes unless the guard is strict: strict text has to
// be readable to be checked.
guard_check :: proc(g: ^Guard, at: Finding, line: string, findings: ^[dynamic]Finding) {
	guard_text(at, line, findings)
	if !g.strict {
		return
	}
	b, ok := parse_bullet(line, "")
	if !ok {
		flag(findings, at, "form", "does not parse as a bullet, so it cannot be checked")
		return
	}
	if n := utf8.rune_count_in_string(b.fact); n > MAXLEN {
		flag(findings, at, "length", fmt.aprintf("fact is %d chars (cap %d)", n, MAXLEN))
	}
	guard_rules(g, at, strings.concatenate({b.handle, " (", b.aliases, ")", SEP, b.fact}), b.fact, findings)
}

// guard_rules runs the strict patterns over text; lead is where a sentence
// starts, for the verbs anchored there.
guard_rules :: proc(g: ^Guard, at: Finding, text, lead: string, findings: ^[dynamic]Finding) {
	scratch := virtual.arena_allocator(&g.arena)
	for r in g.rules {
		_, hit := regex.match_with_preallocated_capture(r.re, text, &g.capture, scratch)
		if !hit && r.name == "command" {
			_, hit = regex.match_with_preallocated_capture(r.re, lead, &g.capture, scratch)
		}
		if hit {
			flag(findings, at, r.name, fmt.aprintf(r.message, strings.trim(g.capture.groups[0], " \t(\"';.!?")))
		}
		free_all(scratch)
	}
}

// guard_line is the first failure for one line, or "" when it passes.
guard_line :: proc(g: ^Guard, line: string) -> string {
	findings := make([dynamic]Finding, context.temp_allocator)
	guard_check(g, {}, line, &findings)
	if len(findings) == 0 {
		return ""
	}
	return findings[0].message
}

// guard_synonym checks one row of the vocabulary, which widens every query
// that names its term: a poisoned row steers every search. Strict, a row is
// a term and an expansion of at most four plain words.
guard_synonym :: proc(g: ^Guard, at: Finding, row: string, findings: ^[dynamic]Finding) {
	guard_text(at, row, findings)
	if !g.strict || row == "" || row == "term\texpansion" || strings.has_prefix(row, "#") {
		return
	}
	cols := strings.split(row, "\t")
	for c in cols {
		if len(cols) != 2 || !is_plain_words(c, 4) {
			flag(findings, at, "synonym", fmt.aprintf("row %q is not a term and an expansion of at most four plain words", row))
			return
		}
	}
	guard_rules(g, at, row, cols[1], findings)
}

// is_plain_words is whether s is 1 to max words of letters, digits and . ' + -.
is_plain_words :: proc(s: string, max: int) -> bool {
	words := strings.fields(s)
	if len(words) == 0 || len(words) > max {
		return false
	}
	for r in s {
		if !(unicode.is_letter(r) || unicode.is_digit(r) || strings.contains_rune(" .'+-", r)) {
			return false
		}
	}
	return true
}

// is_hidden is a format or invisible character: zero widths, direction
// overrides, tag characters and variation selectors, which carry text a
// reader never sees. A single emoji variation selector after a visible
// character is allowed; a run of them fails.
is_hidden :: proc(r, prev: rune) -> bool {
	switch r {
	case 0x00ad, 0x034f, 0x061c, 0x115f, 0x1160, 0x17b4, 0x17b5, 0x3164, 0xfeff, 0xffa0:
		return true
	case 0x180b ..= 0x180f, 0x200b ..= 0x200f, 0x202a ..= 0x202e, 0x2060 ..= 0x206f, 0xfff9 ..= 0xfffb:
		return true
	case 0x1d173 ..= 0x1d17a, 0xe0000 ..= 0xe007f, 0xe0100 ..= 0xe01ef, 0xfe00 ..= 0xfe0d:
		return true
	case 0xfe0e, 0xfe0f:
		return prev == 0 || (prev >= 0xfe00 && prev <= 0xfe0f)
	}
	return false
}

prev_rune :: proc(s: string, i: int) -> rune {
	r, _ := utf8.decode_last_rune_in_string(s[:i])
	return r
}

// mixed_script_word is the first word that mixes Latin, Greek and Cyrillic
// letters, the alphabets whose lookalikes spoof one another, or "".
mixed_script_word :: proc(s: string) -> string {
	start, seen := -1, 0
	for r, i in s {
		if unicode.is_letter(r) {
			if start < 0 {
				start, seen = i, 0
			}
			seen |= script_bit(r)
			continue
		}
		if start >= 0 && seen & (seen - 1) != 0 {
			return s[start:i]
		}
		start = -1
	}
	if start >= 0 && seen & (seen - 1) != 0 {
		return s[start:]
	}
	return ""
}

script_bit :: proc(r: rune) -> int {
	switch r {
	case 'A' ..= 'Z', 'a' ..= 'z', 0xc0 ..= 0x24f, 0x1e00 ..= 0x1eff:
		return 1
	case 0x370 ..= 0x3ff, 0x1f00 ..= 0x1fff:
		return 2
	case 0x400 ..= 0x52f:
		return 4
	}
	return 0
}

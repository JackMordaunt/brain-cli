package brain

import "core:os"
import "core:strings"
import "core:text/regex"

import "jm:path"
import "jm:sh"

// ~/go/bin is not on a non-interactive PATH on every machine, and the hook
// runs non-interactively, so the scanner is resolved explicitly. A gate that
// silently fails to run is worse than no gate.
find_gitleaks :: proc(cli: ^Cli) -> (string, bool) {
	exe := "gitleaks.exe" when ODIN_OS == .Windows else "gitleaks"
	for c in ([4]string {
			path.join(cli.home, "go", "bin", exe),
			"/usr/bin/gitleaks",
			"/usr/local/bin/gitleaks",
			"/opt/homebrew/bin/gitleaks",
		}) {
		if os.is_file(c) {
			return c, true
		}
	}
	return sh.which("gitleaks")
}

// A vault may carry its own allowlist; otherwise the tool's default ruleset
// applies, so a fresh clone is still scanned.
gitleaks_config :: proc(cli: ^Cli) -> string {
	own := path.join(cli.vault, ".gitleaks.toml")
	if os.is_file(own) {
		return own
	}
	return path.join(cli.tool, ".gitleaks.toml")
}

// A floor for machines without gitleaks: only patterns that cannot plausibly
// be anything else. No 40-hex rule — that is a git SHA, and a vault is full
// of them.
FALLBACK_PATTERNS :: [6]string {
	`BEGIN [A-Z ]*PRIVATE KEY`,
	`AKIA[0-9A-Z]{16}`,
	`gh[pousr]_[A-Za-z0-9]{36,}`,
	`xox[baprs]-[A-Za-z0-9-]{10,}`,
	`eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}`,
	`[0-9a-f]{64,}`,
}

cmd_secrets :: proc(cli: ^Cli, args: []string) -> int {
	if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	mode := len(args) > 0 ? args[0] : "--staged"
	cfg := gitleaks_config(cli)

	if gl, found := find_gitleaks(cli); found {
		argv := make([dynamic]string)
		append(&argv, gl, "git", cli.vault)
		if mode != "--history" {
			append(&argv, "--staged")
		}
		append(&argv, "--no-banner", "--redact", "--config", cfg)
		r := sh.exec(argv[:])
		out(cli, r.stdout)
		errf(cli, "%s", r.stderr)
		if r.err != nil {
			return fail(cli, sh.error(r))
		}
		if r.code == 0 {
			outf(cli, "brain secrets: clean (gitleaks, %s)\n", mode)
		}
		return r.code
	}

	errf(cli, "brain secrets: gitleaks not found — falling back to six built-in patterns.\n")
	errf(cli, "  install it for the full ruleset: pacman -S gitleaks / brew install gitleaks / scoop install gitleaks\n")
	r: sh.Result
	if mode == "--history" {
		r = sh.exec({"git", "log", "-p", "--no-color"}, {dir = cli.vault})
	} else {
		r = sh.exec({"git", "diff", "--cached", "-U0", "--no-color"}, {dir = cli.vault})
	}
	hits := fallback_hits(r.stdout)
	if len(hits) > 0 {
		errf(cli, "brain secrets: possible secret in the change:\n")
		for h, i in hits {
			if i == 20 {
				break
			}
			errf(cli, "%s\n", h)
		}
		return 1
	}
	outf(cli, "brain secrets: clean (built-in patterns, %s)\n", mode)
	return 0
}

// fallback_hits returns every line matching a built-in pattern, numbered the
// way `grep -n` numbers them.
fallback_hits :: proc(text: string) -> []string {
	res := make([]regex.Regular_Expression, len(FALLBACK_PATTERNS))
	for p, i in FALLBACK_PATTERNS {
		res[i], _ = regex.create(p)
	}
	hits := make([dynamic]string)
	rest := text
	n := 0
	for raw in strings.split_lines_iterator(&rest) {
		n += 1
		line := strings.trim_suffix(raw, "\r")
		for re in res {
			if matches(re, line) {
				append(&hits, strings.concatenate({int_str(i64(n)), ":", line}))
				break
			}
		}
	}
	return hits[:]
}

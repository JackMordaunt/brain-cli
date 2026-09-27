/*
Package brain is the CLI behind the `brain` command: it resolves where the
tool and the vault live, dispatches a subcommand, and collects its output.

Two roots, and they are not the same thing:

	TOOL   the checkout of this repository: the CLI, its hooks, shims and
	       synonyms. Public, distributable, carries no notes.
	VAULT  the markdown someone keeps. Private, theirs, committed separately.

Every subcommand writes to Cli.out and Cli.err rather than the process's
streams, so a test runs one in-process and reads what it printed.
*/
package brain

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "jm:path"

// The checkout `just build` was run from, baked in so a development binary
// under build/ knows its tool root without an install. BRAIN_TOOL in the
// environment and the recorded tool path both outrank it.
BRAIN_TOOL :: #config(BRAIN_TOOL, "")

SCHEMA          :: 2 // bump when a table changes shape; ensure_db then rebuilds
MAXLEN          :: 400 // soft cap on a bullet's fact text
STALE_DAYS      :: 90 // a fact older than this wants re-verification
FIND_LIMIT      :: 8
FIND_BYTES      :: 4000
PROMOTE_QUERIES :: 3 // a bullet returned this often is a candidate for a gate
RECALL_LIMIT    :: 10

// The files whose bullets lint checks and doctor measures.
CORE :: [3]string{"AI/MEMORY.md", "AI/LEARNINGS.md", "AI/TUNINGS.md"}

// Cli is one invocation: resolved paths, environment overrides, and the two
// output streams a subcommand writes into.
Cli :: struct {
	out, err:     strings.Builder,
	// Overrides consulted before the process environment; a test sets them.
	env:          map[string]string,
	home:         string,
	tool:         string,
	vault:        string, // "" when unresolved; need_vault says so
	state:        string,
	conf_dir:     string,
	conf_vault:   string,
	conf_sources: string,
	db:           string,
	recall_db:    string,
	dry:          bool,
}

// new_cli resolves every path the subcommands share. env overrides the
// process environment for the keys it holds.
new_cli :: proc(env: map[string]string = nil) -> ^Cli {
	cli := new(Cli)
	cli.env = env
	cli.out = strings.builder_make()
	cli.err = strings.builder_make()

	cli.home = getenv(cli, "HOME")
	if cli.home == "" {
		cli.home = path.home()
	}
	conf_base := getenv(cli, "XDG_CONFIG_HOME", path.join(cli.home, ".config"))
	cli.conf_dir = path.join(conf_base, "brain")
	cli.conf_vault = path.join(cli.conf_dir, "vault")
	cli.conf_sources = path.join(cli.conf_dir, "sources")
	state_base := getenv(cli, "XDG_STATE_HOME", path.join(cli.home, ".local", "state"))
	cli.state = getenv(cli, "BRAIN_STATE", path.join(state_base, "brain"))
	cli.db = path.join(cli.state, "brain.db")
	cli.recall_db = path.join(cli.state, "transcripts.db")

	cli.tool = find_tool(cli)
	cli.vault = find_vault(cli)
	return cli
}

// getenv reads an override, then the environment, and falls back to def when
// the value is unset or empty.
getenv :: proc(cli: ^Cli, key: string, def := "") -> string {
	if v, ok := cli.env[key]; ok {
		return v == "" ? def : v
	}
	v, found := os.lookup_env(key, context.allocator)
	if !found || v == "" {
		return def
	}
	return v
}

// Where the tool is, in order of authority: BRAIN_TOOL in the environment,
// the path `brain install` recorded, the checkout baked in at build time, and
// finally the binary's own directory, walking up until one holds
// bin/synonyms.tsv, which a checkout has and nothing else does.
find_tool :: proc(cli: ^Cli) -> string {
	if t := getenv(cli, "BRAIN_TOOL"); t != "" {
		return clean(t)
	}
	if t := recorded_path(path.join(cli.conf_dir, "tool")); t != "" && os.is_dir(t) {
		return clean(t)
	}
	if BRAIN_TOOL != "" && os.is_dir(BRAIN_TOOL) {
		return clean(BRAIN_TOOL)
	}
	exe, err := os.get_executable_directory(context.allocator)
	if err != nil {
		return ""
	}
	d := clean(exe)
	for {
		if os.is_file(path.join(d, "bin", "synonyms.tsv")) {
			return d
		}
		up := filepath.dir(d)
		if up == d {
			break
		}
		d = up
	}
	return clean(exe)
}

// Where the vault is, in order of authority: BRAIN_VAULT, the tool's own
// checkout when it holds notes too (the combined layout this repository once
// had), and the path `brain install` recorded.
find_vault :: proc(cli: ^Cli) -> string {
	if v := getenv(cli, "BRAIN_VAULT"); v != "" {
		if abs, err := path.abs(v); err == nil {
			return abs
		}
		return clean(v)
	}
	if cli.tool != "" && os.is_dir(path.join(cli.tool, "AI")) {
		return cli.tool
	}
	if v := recorded_path(cli.conf_vault); v != "" && os.is_dir(v) {
		return clean(v)
	}
	return ""
}

// need_vault fails when no vault is known or the recorded one is gone.
need_vault :: proc(cli: ^Cli) -> string {
	if cli.vault == "" {
		return "no vault yet: run 'brain install <path-to-vault>', or set BRAIN_VAULT"
	}
	if !os.is_dir(cli.vault) {
		return fmt.aprintf("vault recorded but missing: %s", cli.vault)
	}
	return ""
}

// run dispatches args and returns the exit code. A failure has been printed
// to Cli.err as `brain: <message>` by the command that hit it.
run :: proc(cli: ^Cli, args: []string) -> int {
	cmd := len(args) > 0 ? args[0] : ""
	rest := len(args) > 0 ? args[1:] : nil
	switch cmd {
	case "locate":
		return cmd_locate(cli, rest)
	case "find":
		return cmd_find(cli, rest)
	case "recall":
		return cmd_recall(cli, rest)
	case "sync":
		return cmd_sync(cli, rest)
	case "log":
		return cmd_log(cli, rest)
	case "doctor":
		return cmd_doctor(cli, rest)
	case "lint":
		return cmd_lint(cli, rest)
	case "secrets":
		return cmd_secrets(cli, rest)
	case "install":
		return cmd_install(cli, rest)
	case "update":
		return cmd_update(cli, rest)
	case "version", "--version":
		return cmd_version(cli, rest)
	case "uninstall":
		return cmd_uninstall(cli, rest)
	case "", "-h", "--help", "help":
		out(cli, USAGE)
		return 0
	case:
		return fail(cli, fmt.aprintf("unknown command: %s (try 'brain help')", cmd))
	}
}

// fail prints a message the shell version's `die` printed and returns the
// exit code the caller passes on.
fail :: proc(cli: ^Cli, msg: string) -> int {
	errf(cli, "brain: %s\n", msg)
	return 1
}

USAGE :: `brain — query and lint the vault. Markdown is canonical; the index is disposable.

  brain locate [--native] absolute path to the vault, for agents and scripts
  brain locate --tool     absolute path to this CLI's own checkout
  brain find <terms...>   search bullets, handle matches ranked first
  brain recall <terms...> search agent transcripts: what was said, not what is true
    --sync --sources --enable <a> --disable <a> --full <id> --limit N --json
    --sessions (one row per conversation)  --prefix (last term matches as a prefix)
  brain sync              rebuild the index from markdown
  brain doctor            what is stale, thin, oversized, duplicated or orphaned
  brain log               misses that still miss, and who is asking
  brain lint [--staged]   check bullet form; hard failures block a commit
  brain secrets [--staged|--history]  scan for credentials (gitleaks, with a fallback)
  brain install [<vault>] [--dry-run]  bind this machine to a vault
  brain uninstall [--dry-run]  undo those bindings; the vault is untouched
  brain update            replace this binary with the latest signed release
  brain version           this build and its release asset name

This CLI and the notes it searches are separate repositories. The vault is
named once, by 'brain install <path>', and recorded in ~/.config/brain/vault.

Zero-hit queries are recorded so the synonym table fills from real misses
rather than guesswork; edit bin/synonyms.tsv and run 'brain sync'.
`

// The bootstrap answer: an agent that has `brain` on PATH can always find the
// vault, without already knowing where it is. Paths print in the platform's
// own form, so --native is accepted for the callers that pass it and does
// nothing.
cmd_locate :: proc(cli: ^Cli, args: []string) -> int {
	p := cli.vault
	if len(args) > 0 && args[0] == "--tool" {
		p = cli.tool
	} else if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	outf(cli, "%s\n", p)
	return 0
}

// ---- output ---------------------------------------------------------------

out :: proc(cli: ^Cli, s: string) {
	strings.write_string(&cli.out, s)
}

outf :: proc(cli: ^Cli, format: string, args: ..any) {
	fmt.sbprintf(&cli.out, format, ..args)
}

errf :: proc(cli: ^Cli, format: string, args: ..any) {
	fmt.sbprintf(&cli.err, format, ..args)
}

// ---- files ----------------------------------------------------------------

// clean normalises a path for comparison and display.
clean :: proc(p: string) -> string {
	c, _ := filepath.clean(p)
	return c
}

// first_line returns a file's first line, or "" when it cannot be read.
first_line :: proc(p: string) -> string {
	data, err := os.read_entire_file_from_path(p, context.allocator)
	if err != nil {
		return ""
	}
	s := string(data)
	if i := strings.index_byte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return strings.trim_right(s, "\r")
}

// recorded_path reads a path the installer wrote to a one-line file. The
// shell version wrote Git Bash's /c/Users/... form on Windows; MSYS
// translates such a path in an argument or the environment for a native
// program, but not inside a file, so that is done here.
recorded_path :: proc(p: string) -> string {
	s := first_line(p)
	when ODIN_OS == .Windows {
		if len(s) >= 3 && s[0] == '/' && s[2] == '/' && is_drive_letter(s[1]) {
			return fmt.aprintf("%c:%s", s[1] - 'a' + 'A' if s[1] >= 'a' else s[1], s[2:])
		}
	}
	return s
}

is_drive_letter :: proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

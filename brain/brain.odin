/*
Package brain is the CLI behind the `brain` command: it resolves where the
tool and the vault live, dispatches a subcommand, and collects its output.

Two roots, and they are not the same thing:

	TOOL   the checkout of this repository: the CLI and its hooks. Public,
	       distributable, carries no notes.
	VAULT  the markdown someone keeps. Private, theirs, committed separately.

Every subcommand writes to Cli.out and Cli.err rather than the process's
streams, so a test runs one in-process and reads what it printed.
*/
package brain

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import "jm:path"

import "../term"

// The checkout `just build` was run from, baked in so a development binary
// under build/ knows its tool root without an install. BRAIN_TOOL in the
// environment and the recorded tool path both outrank it.
BRAIN_TOOL :: #config(BRAIN_TOOL, "")

SCHEMA          :: 7 // bump when a table changes shape; ensure_db then rebuilds (7: porter stemming)
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
	stdin:        string, // what a hook handed over; main reads it, a test sets it
	has_stdin:    bool,
	json:         bool, // --json: one object on stdout instead of text
	tty:          bool, // stdout is a terminal; only main can know
	style:        term.Style, // plain unless a person is watching; see term.detect
	indexed:      struct {
		bullets, links, files: int,
	}, // what the last reindex counted
}

// new_cli resolves every path the subcommands share. env overrides the
// process environment for the keys it holds; tty says stdout is a terminal.
new_cli :: proc(env: map[string]string = nil, tty := false) -> ^Cli {
	cli := new(Cli)
	cli.env = env
	cli.tty = tty
	mode, _ := term.parse_mode(getenv(cli, "BRAIN_COLOR"))
	cli.style = detect_style(cli, mode)
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

// detect_style decides decoration from Cli's own environment, so a test's
// overrides count; an agent always gets plain text.
detect_style :: proc(cli: ^Cli, mode: term.Mode) -> term.Style {
	return term.detect(cli.tty, mode, env_lookup, cli)
}

// env_lookup is getenv as a term.Lookup, with the Cli as its data.
env_lookup :: proc(key: string, data: rawptr) -> string {
	return getenv((^Cli)(data), key)
}

// Where the tool is, in order of authority: BRAIN_TOOL in the environment,
// the path `brain install` recorded, the checkout baked in at build time, and
// finally the binary's own directory, walking up until one holds
// bin/hooks/pre-commit, which a checkout has and nothing else does.
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
		if os.is_file(path.join(d, "bin", "hooks", "pre-commit")) {
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
		return "no vault yet: run 'brain install [<path-to-vault>]', or set BRAIN_VAULT"
	}
	if !os.is_dir(cli.vault) {
		return fmt.aprintf("vault recorded but missing: %s", cli.vault)
	}
	return ""
}

// run dispatches args and returns the exit code. A failure has been printed
// to Cli.err as `brain: <message>` by the command that hit it.
run :: proc(cli: ^Cli, raw_args: []string) -> int {
	// --json is accepted anywhere; the commands that speak it answer with
	// one object on stdout, the others ignore it.
	args := make([dynamic]string)
	cli.json = false
	for a in raw_args {
		if a == "--json" {
			cli.json = true
		} else if strings.has_prefix(a, "--color=") {
			mode, ok := term.parse_mode(a[len("--color="):])
			if !ok {
				return fail(cli, fmt.aprintf("--color takes auto, always or never, not %q", a[len("--color="):]))
			}
			cli.style = detect_style(cli, mode)
		} else {
			append(&args, a)
		}
	}
	cmd := len(args) > 0 ? args[0] : ""
	rest := len(args) > 0 ? args[1:] : nil
	switch cmd {
	case "locate":
		return cmd_locate(cli, rest)
	case "find":
		return cmd_find(cli, rest)
	case "pack":
		return cmd_pack(cli, rest)
	case "propose":
		return cmd_propose(cli, rest)
	case "inbox":
		return cmd_inbox(cli, rest)
	case "review":
		return cmd_review(cli, rest)
	case "mcp":
		return cmd_mcp(cli, rest)
	case "export":
		return cmd_export(cli, rest)
	case "import":
		return cmd_import(cli, rest)
	case "recall":
		return cmd_recall(cli, rest)
	case "prime":
		return cmd_prime(cli, rest)
	case "settle":
		return cmd_settle(cli, rest)
	case "hooks":
		return cmd_hooks(cli, rest)
	case "howto":
		return cmd_howto(cli, rest)
	case "lessons":
		return cmd_lessons(cli, rest)
	case "day":
		return cmd_day(cli, rest)
	case "week":
		return cmd_week(cli, rest)
	case "reindex":
		return cmd_reindex(cli, rest)
	case "sync":
		return cmd_sync(cli, rest)
	case "ledger":
		return cmd_ledger(cli, rest)
	case "log":
		return cmd_log(cli, rest)
	case "tend":
		return cmd_tend(cli, rest)
	case "doctor":
		return cmd_doctor(cli, rest)
	case "verify":
		return cmd_verify(cli, rest)
	case "learn":
		return cmd_learn(cli, rest)
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
		print_usage(cli)
		return 0
	case:
		return fail(cli, fmt.aprintf("unknown command: %s (try 'brain help')", cmd))
	}
}

// fail prints a message the shell version's `die` printed and returns the
// exit code the caller passes on.
fail :: proc(cli: ^Cli, msg: string) -> int {
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "error", msg)
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 1
	}
	errf(cli, "brain: %s\n", msg)
	return 1
}

// parse_positive reads a count argument.
parse_positive :: proc(s: string) -> (int, bool) {
	n, ok := strconv.parse_int(s)
	return n, ok && n > 0
}

USAGE :: `brain — memory for your coding agents, in files you own.

Ask
  brain find <terms...>      what the vault knows; handle matches first, then lines from
                             longer notes; --budget N tokens
  brain pack [<project>]     the briefing a session opens with; --budget N, --fresh
  brain prime [<prompt>]     what the vault knows about one prompt, once per session; the
                             hooks call it with --harness, --session, or JSON on stdin
  brain recall <terms...>    what past agent conversations said; --limit N, --full <id>,
                             --sessions, --prefix, --enable <agent>, --sources
  brain howto <terms...>     the shell commands that did it last time, from the transcripts;
                             --all lists the sessions, --propose keeps the chain in the vault
  brain day [YYYY-MM-DD]     what was worked on that day, by repository: sessions, goals, commits
  brain week [--since Nd]    the same for the last seven days; --project <name>, --no-git
Remember
  brain propose '<bullet>'   add a fact for a person to review
  brain settle               when the agent would stop: once per session that changed files and
                             proposed nothing, ask it what it settled; --harness, --transcript
  brain lessons              where a person corrected an agent, and commands that failed then
                             worked, from the transcripts; --since Nd, --propose queues each
  brain inbox                what is unreviewed; approve <n>|all [--to LEARNINGS], drop <n>
  brain review [<mode>]      after (default): a proposal answers finds at once, marked
                             unreviewed, until dropped; before: only once approved
  brain import claude        propose what Claude Code remembered on its own; or <file.md>
Share
  brain export <agent>...    give this repository's briefing to an agent: claude, agents (codex,
                             opencode, jules, junie, zed, warp), copilot, gemini, cursor, cline, kiro
  brain mcp                  the same tools over MCP on stdio, for agents without a shell
  brain sync                 send what changed here, receive what other machines wrote;
                             automatic at session start and stop; on|off for this machine,
                             status, connect <url>|github
Keep it healthy
  brain tend                 keep the vault true: date what verifies, add the aliases queries
                             use, and put the rest in the inbox as actions a person approves
                             (mark a note superseded, drop a bullet whose claims failed, merge
                             duplicates); runs once a day when an agent stops; --quick, --dry-run
  brain doctor               what is stale, thin, oversized, duplicated or orphaned, which
                             notes a newer bullet may have superseded, which claims failed
                             verify, which bullets were served just before a correction
  brain learn                which query words found a bullet they do not name, and which
                             aliases nobody asks for; --apply edits the bullets and vocabulary
  brain verify [<handle>..]  test the claims bullets make: paths, vault files, subcommands,
                             commits; --apply dates today every bullet whose claims passed
  brain log                  what keeps missing, and who asks
  brain ledger [--days N]    what lookups cost and saved, by caller, session and day
  brain lint [--staged]      check bullet form; failures block a commit; --strict,
                             or the vault's .brain/policy, refuses text that steers agents
  brain secrets [--staged]   scan for credentials; --history, every commit
  brain reindex              rebuild the index from the markdown (automatic; rarely needed)
Set up
  brain install [<vault>]    bind this machine to a vault; --dry-run shows the plan
  brain uninstall            undo those bindings; the vault is untouched
  brain locate [--tool]      the vault's path; --tool, this CLI's checkout
  brain hooks [on|off]       pack, prime and settle in every harness here: Claude Code, pi;
                             --harness <name> for one
  brain update               replace this binary with the latest signed release
  brain version              this build

--json on any command above the Set up line answers with one object instead.
The vault is markdown in a folder you own; the index is a cache. 'brain locate'
prints the folder, and any tool that reads markdown works on it.
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
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "vault", cli.vault)
		jw_field(&w, "tool", cli.tool)
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
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

package brain

import "core:fmt"
import "core:os"
import "core:strings"

import "jm:path"
import "jm:sh"

// Everything install writes to a file the user owns goes inside a tagged
// block, so it can be replaced on re-install and removed by `brain uninstall`
// without touching a line the user wrote.

EXE :: ".exe" when ODIN_OS == .Windows else ""

os_kind :: proc() -> string {
	when ODIN_OS == .Windows {
		return "windows"
	} else when ODIN_OS == .Darwin {
		return "macos"
	} else when ODIN_OS == .Linux {
		return "linux"
	} else {
		return "unknown"
	}
}

say :: proc(cli: ^Cli, format: string, args: ..any) {
	out(cli, cli.dry ? "  [dry] " : "  ")
	outf(cli, format, ..args)
	out(cli, "\n")
}

note :: proc(cli: ^Cli, format: string, args: ..any) {
	out(cli, "  ")
	outf(cli, format, ..args)
	out(cli, "\n")
}

block_begin :: proc(co, tag, cc: string) -> string {
	return fmt.aprintf("%s brain:%s >>> managed by `brain install`; edit the vault, not this block %s", co, tag, cc)
}

block_end :: proc(co, tag, cc: string) -> string {
	return fmt.aprintf("%s brain:%s <<< %s", co, tag, cc)
}

read_text :: proc(p: string) -> (string, bool) {
	data, err := os.read_entire_file_from_path(p, context.allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

backup :: proc(p: string) {
	os.copy_file(strings.concatenate({p, ".brain-backup"}), p)
}

// block_apply writes body between the tag's markers in file, adding the
// block at the top when it is absent and replacing it when it differs.
block_apply :: proc(cli: ^Cli, file, tag, co, cc, body: string) {
	b := block_begin(co, tag, cc)
	e := block_end(co, tag, cc)
	open_mark := strings.concatenate({"brain:", tag, " >>>"})
	close_mark := strings.concatenate({"brain:", tag, " <<<"})
	want := strings.concatenate({b, "\n", body, "\n", e})
	text, exists := read_text(file)
	if exists && strings.contains(text, open_mark) {
		cur := make([dynamic]string)
		in_block := false
		for l in strings.split_lines(text) {
			if strings.contains(l, open_mark) {
				in_block = true
			}
			if in_block {
				append(&cur, l)
			}
			if in_block && strings.contains(l, close_mark) {
				in_block = false
			}
		}
		if strings.join(cur[:], "\n") == want {
			say(cli, "%s: already current", file)
			return
		}
		say(cli, "%s: block refreshed", file)
		if cli.dry {
			return
		}
		backup(file)
		path.write(file, replace_block(text, open_mark, close_mark, want))
		return
	}
	say(cli, "%s: block added", file)
	if cli.dry {
		return
	}
	if exists && text != "" {
		backup(file)
	}
	path.mkdirs(path.dir(file))
	path.write(file, strings.concatenate({want, "\n\n", text}))
}

// replace_block swaps the lines from the open marker to the close marker for
// replacement; an empty replacement removes them.
replace_block :: proc(text, open_mark, close_mark, replacement: string) -> string {
	lines := make([dynamic]string)
	skip := false
	for l in strings.split_lines(text) {
		if strings.contains(l, open_mark) {
			if replacement != "" {
				append(&lines, replacement)
			}
			skip = true
			continue
		}
		if skip {
			if strings.contains(l, close_mark) {
				skip = false
			}
			continue
		}
		append(&lines, l)
	}
	return strings.join(lines[:], "\n")
}

block_remove :: proc(cli: ^Cli, file, tag: string) {
	text, exists := read_text(file)
	open_mark := strings.concatenate({"brain:", tag, " >>>"})
	if !exists || !strings.contains(text, open_mark) {
		return
	}
	say(cli, "%s: block removed", file)
	if cli.dry {
		return
	}
	path.write(file, replace_block(text, open_mark, strings.concatenate({"brain:", tag, " <<<"}), ""))
}

// In .bashrc the block must sit above the interactive early-return, or shells
// that source the file non-interactively never reach it.
rc_block :: proc(cli: ^Cli, rc, body, tag: string) {
	GUARD :: "[[ $- != *i* ]] && return"
	text, exists := read_text(rc)
	if exists && strings.contains(text, GUARD) && !strings.contains(text, strings.concatenate({"brain:", tag, " >>>"})) {
		say(cli, "%s: block added above the interactive guard", rc)
		if cli.dry {
			return
		}
		backup(rc)
		lines := make([dynamic]string)
		done := false
		for l in strings.split_lines(text) {
			if !done && strings.has_prefix(l, GUARD) {
				append(&lines, block_begin("#", tag, ""), body, block_end("#", tag, ""), "")
				done = true
			}
			append(&lines, l)
		}
		path.write(rc, strings.join(lines[:], "\n"))
		return
	}
	block_apply(cli, rc, tag, "#", "", body)
}

// posix_path is the form a PATH entry takes in a file Git Bash reads: on
// Windows C:\a\b becomes /c/a/b, since bash splits PATH on the colon.
posix_path :: proc(p: string) -> string {
	when ODIN_OS == .Windows {
		fwd, _ := strings.replace_all(p, "\\", "/")
		if len(fwd) >= 2 && fwd[1] == ':' && is_drive_letter(fwd[0]) {
			drive := fwd[0] + ('a' - 'A') if fwd[0] <= 'Z' else fwd[0]
			return fmt.aprintf("/%c%s", drive, fwd[2:])
		}
		return fwd
	} else {
		return p
	}
}

on_path :: proc(cli: ^Cli, dir: string) -> bool {
	sep := ";" when ODIN_OS == .Windows else ":"
	for d in strings.split(getenv(cli, "PATH"), sep) {
		if d != "" && path.same(d, dir) {
			return true
		}
	}
	return false
}

// The same preference order the justfile standard uses for `install`.
pick_bindir :: proc(cli: ^Cli) -> string {
	candidates := [5]string {
		path.join(cli.home, ".local", "bin"),
		path.join(cli.home, "bin"),
		getenv(cli, "GOBIN"),
		getenv(cli, "GOPATH") != "" ? path.join(getenv(cli, "GOPATH"), "bin") : "",
		"/usr/local/bin",
	}
	for d in candidates {
		if d != "" && os.is_dir(d) && writable_dir(d) {
			return d
		}
	}
	d := path.join(cli.home, ".local", "bin")
	if !cli.dry {
		path.mkdirs(d)
	}
	return d
}

writable_dir :: proc(d: string) -> bool {
	probe := path.join(d, ".brain-write-probe")
	if path.write(probe, "") != nil {
		return false
	}
	os.remove(probe)
	return true
}

// Which files a login shell reads differs per platform: zsh is the macOS
// default and reads .zshenv for every invocation, Git Bash reads .bashrc.
path_rc_files :: proc(cli: ^Cli) -> []string {
	files := make([dynamic]string)
	when ODIN_OS == .Darwin {
		append(&files, path.join(cli.home, ".zshenv"), path.join(cli.home, ".bash_profile"))
	} else {
		append(&files, path.join(cli.home, ".bashrc"))
	}
	return files[:]
}

// The tool's data files that hooks and scans read live beside the checkout,
// so install records where that is for the installed copy to find.
record :: proc(cli: ^Cli, file, value: string) {
	path.mkdirs(path.dir(file))
	path.write(file, strings.concatenate({value, "\n"}))
}

// canonical_vault is where a vault lives when nobody has said otherwise.
canonical_vault :: proc(cli: ^Cli) -> string {
	return path.join(cli.home, "Documents", "Brain")
}

// install_vault is the vault install binds, in order of authority: the path
// given, BRAIN_VAULT, the vault an earlier install recorded, and the
// canonical path. Nothing is searched for. created is true when the
// canonical path does not exist yet and install has to make it.
install_vault :: proc(cli: ^Cli, given: string) -> (vault: string, created: bool, err: string) {
	named := given
	if named == "" {
		named = getenv(cli, "BRAIN_VAULT")
	}
	if named != "" {
		if !os.is_dir(named) {
			return "", false, fmt.aprintf("install: no such directory: %s", named)
		}
		abs, aerr := path.abs(named)
		return aerr == nil ? abs : clean(named), false, ""
	}
	if v := recorded_path(cli.conf_vault); v != "" && os.is_dir(v) {
		return clean(v), false, ""
	}
	v := canonical_vault(cli)
	if os.exists(v) && !os.is_dir(v) {
		return "", false, fmt.aprintf("install: %s exists and is not a directory", v)
	}
	return v, !os.exists(v), ""
}

// create_vault writes the starter vault and makes it a git repository, since
// the hooks install binds are git hooks.
create_vault :: proc(cli: ^Cli, vault: string) -> string {
	for f in STARTER {
		file := path.join(vault, f.name)
		if err := path.mkdirs(path.dir(file)); err != nil {
			return fmt.aprintf("install: cannot create %s: %v", vault, err)
		}
		if err := path.write(file, f.body); err != nil {
			return fmt.aprintf("install: cannot write %s: %v", file, err)
		}
	}
	if _, found := sh.which("git"); found {
		if r := sh.exec({"git", "init", "-q"}, {dir = vault}); !r.ok {
			note(cli, "git init failed in %s: %s", vault, sh.error(r))
		}
	} else {
		note(cli, "git missing — run 'git init' in %s so its hooks can run", vault)
	}
	return ""
}

cmd_install :: proc(cli: ^Cli, args: []string) -> int {
	cli.dry = false
	given := ""
	for arg in args {
		switch {
		case arg == "--dry-run":
			cli.dry = true
		case strings.has_prefix(arg, "-"):
			return fail(cli, fmt.aprintf("install: unknown flag %s", arg))
		case arg == "":
		case:
			given = arg
		}
	}
	vault, created, verr := install_vault(cli, given)
	if verr != "" {
		return fail(cli, verr)
	}
	cli.vault = vault
	kind := os_kind()
	hooks := path.join(cli.conf_dir, "hooks")
	bindir := pick_bindir(cli)

	outf(cli, "tool:  %s\n", cli.tool)
	outf(cli, "vault: %s   (%s)\n", vault, kind)
	if created {
		if !cli.dry {
			if err := create_vault(cli, vault); err != "" {
				return fail(cli, err)
			}
		}
		say(cli, "created a new vault; 'brain install <path>' binds another one")
	} else if !os.is_dir(path.join(vault, "AI")) {
		note(cli, "warning: %s has no AI/ — is that the vault?", vault)
	}
	if !cli.dry {
		path.mkdirs(cli.state)
		record(cli, cli.conf_vault, vault)
		record(cli, path.join(cli.conf_dir, "tool"), cli.tool)
	}
	say(cli, "vault path recorded: %s", cli.conf_vault)

	out(cli, "cli:\n")
	installed := install_binary(cli, bindir)
	// The hooks are compiled into the binary and written out here, with the
	// binary's own path inside each: git runs hooks with whatever PATH it
	// has, which in a GUI or a service is not the user's shell PATH.
	if !cli.dry {
		hook_files := HOOKS
		if err := write_executables(hooks, hook_files[:], posix_path(installed)); err != nil {
			note(cli, "cannot write %s: %v", hooks, err)
		}
	}
	say(cli, "hooks written under %s", hooks)
	if on_path(cli, bindir) {
		note(cli, "%s is already on PATH", bindir)
	} else {
		for rc in path_rc_files(cli) {
			rc_block(cli, rc, fmt.aprintf("export PATH=\"%s:$PATH\"", posix_path(bindir)), "path")
		}
		note(cli, "open a new shell, or: export PATH=\"%s:$PATH\"", posix_path(bindir))
		if kind == "windows" {
			note(cli, "for PowerShell and cmd, add %s to the user PATH", bindir)
		}
	}

	out(cli, "git hooks:\n")
	// The hooks live outside the vault, so this path has to be absolute.
	if !cli.dry {
		sh.exec({"git", "config", "core.hooksPath", hooks}, {dir = vault})
	}
	say(cli, "core.hooksPath = %s", hooks)

	// Earlier versions installed PATH shims that refused commands the vault
	// recorded as traps. The guarded commands were vault knowledge hard-coded
	// into the tool, so the shims went; what they left behind is removed.
	remove_guards(cli)

	out(cli, "agent bindings:\n")
	// ~/.agents/AGENTS.md is the canonical binding: pi and Codex already
	// symlink to it, so pointing it at this vault is all a new machine needs.
	agents := path.join(cli.home, ".agents", "AGENTS.md")
	target := path.join(vault, "AI", "AGENTS.md")
	if cli.dry {
		say(cli, "agents link: %s -> %s", agents, target)
	} else {
		path.mkdirs(path.dir(agents))
		if link_or_copy(agents, target) {
			say(cli, "agents link: %s -> %s", agents, target)
		} else if os.copy_file(agents, target) == nil {
			say(cli, "copied %s (no symlink support; re-run install after editing AGENTS.md)", agents)
		} else {
			say(cli, "could not link %s (copy it by hand)", agents)
		}
	}
	// Tilde imports are supported, so this block is identical on every machine.
	claude_md := path.join(cli.home, ".claude", "CLAUDE.md")
	block_apply(cli, claude_md, "claude", "<!--", "-->", CLAUDE_BLOCK)
	// An absolute import of the same file would load it a second time.
	if text, ok := read_text(claude_md); ok {
		dup := strings.concatenate({vault, "/AI/AGENTS.md"})
		kept := make([dynamic]string)
		dropped := false
		for l in strings.split_lines(text) {
			if strings.has_prefix(l, "@") && strings.has_suffix(l, dup) {
				dropped = true
				continue
			}
			append(&kept, l)
		}
		if dropped {
			say(cli, "%s: dropping the now-duplicate absolute import", claude_md)
			if !cli.dry {
				path.write(claude_md, strings.join(kept[:], "\n"))
			}
		}
	}
	// pi and Codex are pointer-only by design; verify rather than edit them.
	for a in ([2]string{path.join(cli.home, ".pi", "agent", "AGENTS.md"), path.join(cli.home, ".codex", "AGENTS.md")}) {
		if os.exists(a) {
			if _, ok := read_text(a); ok {
				note(cli, "%s resolves (pointer-only by design; left alone)", a)
			} else {
				note(cli, "%s exists but is not readable", a)
			}
		} else {
			note(cli, "%s absent — link it to %s if that agent is used here", a, agents)
		}
	}

	out(cli, "scanner:\n")
	if gl, found := find_gitleaks(cli); found {
		note(cli, "gitleaks: %s", gl)
	} else {
		note(cli, "gitleaks missing — pacman -S gitleaks / brew install gitleaks / scoop install gitleaks")
	}

	if cli.dry {
		out(cli, "\n(dry run: nothing was written)\n")
		return 0
	}
	return cmd_sync(cli, nil)
}

CLAUDE_BLOCK :: "@~/.agents/AGENTS.md\n\nThe Brain is this machine's shared agent memory. `brain locate` prints its path,\n`brain find <handle>` searches it, and `brain recall <terms>` searches what was\nsaid in past agent conversations. Do not hard-code the path."

// install_binary puts this executable on PATH as `brain`. A symlink keeps an
// installed command current with its checkout; where links are refused
// (Windows without Developer Mode) the file is copied and the recorded tool
// path keeps it pointed at the checkout. The shell version's wrappers are
// removed, because Git Bash would run a `brain` script before `brain.exe`.
install_binary :: proc(cli: ^Cli, bindir: string) -> (dest: string) {
	dest = path.join(bindir, strings.concatenate({"brain", EXE}))
	// BRAIN_EXE names another build to install, for a script that installs
	// a release binary and for the tests, whose running executable is the
	// test runner.
	exe := getenv(cli, "BRAIN_EXE")
	if exe == "" {
		found, err := os.get_executable_path(context.allocator)
		if err != nil {
			note(cli, "cannot find this executable: %v", err)
			return
		}
		exe = found
	}
	if cli.dry {
		say(cli, "cli: %s -> %s", dest, exe)
		return
	}
	when ODIN_OS == .Windows {
		for stale in ([2]string{path.join(bindir, "brain"), path.join(bindir, "brain.cmd")}) {
			if os.is_file(stale) && os.remove(stale) == nil {
				say(cli, "removed the shell wrapper %s", stale)
			}
		}
	}
	if path.same(dest, exe) {
		say(cli, "cli: %s is this executable", dest)
		return
	}
	if link_or_copy(dest, exe) {
		say(cli, "cli link: %s -> %s", dest, exe)
	} else if os.copy_file(dest, exe) == nil {
		os.change_mode(dest, os.Permissions_All - os.Permissions_Write_All + {.Write_User})
		say(cli, "copied %s (re-run install after a rebuild)", dest)
	} else {
		say(cli, "could not install %s (copy it by hand)", dest)
	}
	return
}

// link_or_copy replaces link with a symlink to target and reports whether
// the result is a link. A refusal leaves nothing behind.
link_or_copy :: proc(link, target: string) -> bool {
	if os.exists(link) || is_link(link) {
		os.remove(link)
	}
	if !symlink(target, link) {
		return false
	}
	return is_link(link)
}

is_link :: proc(p: string) -> bool {
	_, err := os.read_link(p, context.temp_allocator)
	return err == nil
}

// remove_guards undoes what the shell-era guard shims installed: the rc
// block that put them on PATH, the environment.d entry, the written shims,
// and the still older shell-function guard line in .bashrc. Nothing is
// printed when there is nothing to remove.
remove_guards :: proc(cli: ^Cli) {
	for rc in path_rc_files(cli) {
		block_remove(cli, rc, "guards")
	}
	bashrc := path.join(cli.home, ".bashrc")
	if text, ok := read_text(bashrc); ok && strings.contains(text, "brain-guards.sh") {
		say(cli, "%s: removing the superseded shell-function guard", bashrc)
		if !cli.dry {
			kept := make([dynamic]string)
			for l in strings.split_lines(text) {
				if strings.contains(l, "brain-guards.sh") || strings.has_prefix(l, "# Brain guards: refuse") {
					continue
				}
				append(&kept, l)
			}
			path.write(bashrc, strings.join(kept[:], "\n"))
		}
	}
	envd := path.join(cli.home, ".config", "environment.d", "10-brain-shims.conf")
	if os.exists(envd) {
		say(cli, "remove %s", envd)
		if !cli.dry {
			os.remove(envd)
		}
	}
	shims := path.join(cli.conf_dir, "shims")
	if os.is_dir(shims) {
		say(cli, "remove %s", shims)
		if !cli.dry {
			os.remove_all(shims)
		}
	}
}

cmd_uninstall :: proc(cli: ^Cli, args: []string) -> int {
	cli.dry = len(args) > 0 && args[0] == "--dry-run"
	out(cli, "removing this machine's bindings; the vault itself is untouched\n")
	for rc in path_rc_files(cli) {
		block_remove(cli, rc, "path")
	}
	remove_guards(cli)
	block_remove(cli, path.join(cli.home, ".claude", "CLAUDE.md"), "claude")
	bindir := pick_bindir(cli)
	for f in ([5]string {
			cli.conf_vault,
			path.join(cli.conf_dir, "tool"),
			path.join(bindir, "brain"),
			path.join(bindir, "brain.exe"),
			path.join(bindir, "brain.cmd"),
		}) {
		if !os.exists(f) && !is_link(f) {
			continue
		}
		say(cli, "remove %s", f)
		if !cli.dry {
			os.remove(f)
		}
	}
	hooks := path.join(cli.conf_dir, "hooks")
	if os.is_dir(hooks) {
		say(cli, "remove %s", hooks)
		if !cli.dry {
			os.remove_all(hooks)
		}
	}
	note(cli, "left alone: ~/.agents/AGENTS.md, the index in %s, and the vault", cli.state)
	if cli.dry {
		out(cli, "(dry run: nothing was written)\n")
	}
	return 0
}

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

cmd_install :: proc(cli: ^Cli, args: []string) -> int {
	cli.dry = false
	vault := cli.vault
	for arg in args {
		switch {
		case arg == "--dry-run":
			cli.dry = true
		case strings.has_prefix(arg, "-"):
			return fail(cli, fmt.aprintf("install: unknown flag %s", arg))
		case arg == "":
		case:
			if !os.is_dir(arg) {
				return fail(cli, fmt.aprintf("install: no such directory: %s", arg))
			}
			abs, err := path.abs(arg)
			vault = err == nil ? abs : clean(arg)
		}
	}
	if vault == "" {
		return fail(cli, "install: name the vault — brain install <path-to-vault>")
	}
	cli.vault = vault
	if !os.is_dir(path.join(vault, "AI")) {
		note(cli, "warning: %s has no AI/ — is that the vault?", vault)
	}
	kind := os_kind()
	shims := path.join(cli.tool, "bin", "shims")
	bindir := pick_bindir(cli)

	outf(cli, "tool:  %s\n", cli.tool)
	outf(cli, "vault: %s   (%s)\n", vault, kind)
	if !cli.dry {
		path.mkdirs(cli.state)
		record(cli, cli.conf_vault, vault)
		record(cli, path.join(cli.conf_dir, "tool"), cli.tool)
		when ODIN_OS != .Windows {
			for d in ([2]string{path.join(cli.tool, "bin", "hooks"), shims}) {
				if names, err := path.list(d); err == nil {
					for n in names {
						os.change_mode(path.join(d, n), os.Permissions_All - os.Permissions_Write_All + {.Write_User})
					}
				}
			}
		}
	}
	say(cli, "vault path recorded: %s", cli.conf_vault)

	out(cli, "cli:\n")
	install_binary(cli, bindir)
	if on_path(cli, bindir) {
		note(cli, "%s is already on PATH", bindir)
	} else {
		for rc in path_rc_files(cli) {
			rc_block(cli, rc, fmt.aprintf("export PATH=\"%s:$PATH\"", bindir), "path")
		}
		note(cli, "open a new shell, or: export PATH=\"%s:$PATH\"", bindir)
		if kind == "windows" {
			note(cli, "for PowerShell and cmd, add %s to the user PATH", bindir)
		}
	}

	out(cli, "git hooks:\n")
	// The hooks ship with the tool, so this path leaves the vault: it has to
	// be absolute, and re-running install is what fixes it after either
	// repository moves.
	hooks := path.join(cli.tool, "bin", "hooks")
	if !cli.dry {
		sh.exec({"git", "config", "core.hooksPath", hooks}, {dir = vault})
	}
	say(cli, "core.hooksPath = %s", hooks)

	out(cli, "guards:\n")
	// The old shell-function guard, superseded by the shims.
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
	for rc in path_rc_files(cli) {
		rc_block(cli, rc, fmt.aprintf("export PATH=\"%s:$PATH\"", shims), "guards")
	}
	if kind == "linux" {
		envd := path.join(cli.home, ".config", "environment.d", "10-brain-shims.conf")
		say(cli, "%s — covers every shell in the session, from the next login", envd)
		if !cli.dry {
			path.mkdirs(path.dir(envd))
			path.write(envd, fmt.aprintf("# Brain guards: refuse commands recorded as traps.\nPATH=%s:${PATH}\n", shims))
		}
	} else {
		note(cli, "on %s only shells reading the files above are covered", kind)
	}

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
install_binary :: proc(cli: ^Cli, bindir: string) {
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
	dest := path.join(bindir, strings.concatenate({"brain", EXE}))
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
}

// link_or_copy replaces link with a symlink to target and reports whether
// the result is a link. A refusal leaves nothing behind.
link_or_copy :: proc(link, target: string) -> bool {
	if os.exists(link) || is_link(link) {
		os.remove(link)
	}
	if os.symlink(target, link) != nil {
		return false
	}
	return is_link(link)
}

is_link :: proc(p: string) -> bool {
	_, err := os.read_link(p, context.temp_allocator)
	return err == nil
}

cmd_uninstall :: proc(cli: ^Cli, args: []string) -> int {
	cli.dry = len(args) > 0 && args[0] == "--dry-run"
	out(cli, "removing this machine's bindings; the vault itself is untouched\n")
	for rc in path_rc_files(cli) {
		block_remove(cli, rc, "path")
		block_remove(cli, rc, "guards")
	}
	block_remove(cli, path.join(cli.home, ".claude", "CLAUDE.md"), "claude")
	bindir := pick_bindir(cli)
	for f in ([6]string {
			path.join(cli.home, ".config", "environment.d", "10-brain-shims.conf"),
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
	note(cli, "left alone: ~/.agents/AGENTS.md, the index in %s, and the vault", cli.state)
	if cli.dry {
		out(cli, "(dry run: nothing was written)\n")
	}
	return 0
}

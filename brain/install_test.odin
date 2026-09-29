package brain

import "core:os"
import "core:strings"
import "core:testing"

import "jm:path"
import "jm:sh"
import "jm:sqlite3"

@(test)
blocks_are_added_refreshed_and_removed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	rc := path.join(f.root, "rc")
	testing.expect_value(t, path.write(rc, "# mine\n[[ $- != *i* ]] && return\nexport X=1\n"), nil)

	rc_block(f.cli, rc, "export PATH=\"/a:$PATH\"", "path")
	text, _ := path.read(rc)
	testing.expect(t, strings.has_prefix(text, "# mine\n# brain:path >>>"), text)
	testing.expect(t, strings.index(text, "brain:path <<<") < strings.index(text, "[[ $- != *i* ]]"), "above the guard")

	strings.builder_reset(&f.cli.out)
	rc_block(f.cli, rc, "export PATH=\"/a:$PATH\"", "path")
	testing.expect(t, strings.contains(strings.to_string(f.cli.out), "already current"), strings.to_string(f.cli.out))

	rc_block(f.cli, rc, "export PATH=\"/b:$PATH\"", "path")
	text, _ = path.read(rc)
	testing.expect(t, strings.contains(text, "/b:$PATH") && !strings.contains(text, "/a:$PATH"), text)
	testing.expect_value(t, strings.count(text, "brain:path >>>"), 1)

	block_remove(f.cli, rc, "path")
	text, _ = path.read(rc)
	// The blank line the block was followed by stays, as it did under the
	// shell version's awk.
	testing.expect_value(t, text, "# mine\n\n[[ $- != *i* ]] && return\nexport X=1\n")

	md := path.join(f.root, "CLAUDE.md")
	block_apply(f.cli, md, "claude", "<!--", "-->", "@~/.agents/AGENTS.md")
	text, _ = path.read(md)
	testing.expect(t, strings.has_prefix(text, "<!-- brain:claude >>> managed by `brain install`; edit the vault, not this block -->\n@~/.agents/AGENTS.md\n<!-- brain:claude <<< -->\n"), text)
}

// Install into a throwaway home: the installed command must run as this
// checkout's tool, not resolve TOOL to $HOME the way the copied shell script
// once did. GOPATH and GOBIN are unset so install cannot pick a real bin
// directory.
@(test)
install_binds_a_home_and_the_installed_cli_names_the_checkout :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	if _, found := sh.which("git"); !found {
		return
	}
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.env["GOPATH"] = ""
	f.cli.env["GOBIN"] = ""
	f.cli.env["PATH"] = ""
	cwd, _ := os.get_working_directory(context.allocator)
	f.cli.env["BRAIN_EXE"] = path.join(cwd, "build", "debug", strings.concatenate({"brain", EXE}))
	git(t, f.vault, "init", "-q")

	o, e, code := exec(f.cli, "install", "--dry-run", f.vault)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "(dry run: nothing was written)"), o)
	testing.expect(t, !os.exists(f.cli.conf_vault), "a dry run writes nothing")

	o, e, code = exec(f.cli, "install", f.vault)
	testing.expect_value(t, code, 0)
	testing.expect_value(t, e, "")
	testing.expect(t, strings.contains(o, "indexed 5 bullets"), o)
	testing.expect_value(t, recorded_path(f.cli.conf_vault), f.vault)
	testing.expect_value(t, recorded_path(path.join(f.cli.conf_dir, "tool")), f.cli.tool)
	hooks, _ := sh.out("git config core.hooksPath", {dir = f.vault})
	testing.expect_value(t, hooks, path.join(f.cli.conf_dir, "hooks"))
	// The hooks are written from the binary, with its installed path baked
	// in, so the gate runs where PATH is not the user's.
	pre, perr := path.read(path.join(hooks, "pre-commit"))
	testing.expect_value(t, perr, nil)
	testing.expect(t, strings.contains(pre, "installed=\"/") || strings.contains(pre, "installed=\"C"), pre[:min(len(pre), 400)])
	testing.expect(t, !strings.contains(pre, "installed=\"\""), "the marker was replaced")
	testing.expect(t, !os.exists(path.join(f.cli.conf_dir, "shims")), "no shims: guards are not the tool's")
	agents := path.join(f.home, ".agents", "AGENTS.md")
	testing.expect(t, !os.exists(agents) || is_link(agents), "the agents file is a link when it is there at all")
	claude_md, _ := path.read(path.join(f.home, ".claude", "CLAUDE.md"))
	testing.expect(t, strings.contains(claude_md, "brain:claude >>> managed by `brain install`"), claude_md)
	testing.expect(t, strings.contains(claude_md, "`brain pack`") && strings.contains(claude_md, "`brain propose "), "the block tells the agent about pack and propose")
	bashrc, _ := path.read(path.join(f.home, ".bashrc"))
	testing.expect(t, strings.contains(bashrc, "brain:path >>>") && !strings.contains(bashrc, "brain:guards >>>"), bashrc)
	// Git Bash splits PATH on the colon, so a C:\ path in .bashrc is broken.
	testing.expect(t, !strings.contains(bashrc, ":\\"), bashrc)
	testing.expect(t, strings.contains(bashrc, "/.local/bin:$PATH"), bashrc)

	installed := path.join(f.home, ".local", "bin", strings.concatenate({"brain", EXE}))
	testing.expect(t, os.is_file(installed) || is_link(installed), installed)
	r := sh.exec({installed, "locate", "--tool"}, {env = child_env(f)})
	testing.expect(t, r.ok, sh.error(r))
	testing.expect_value(t, strings.trim_space(r.stdout), f.cli.tool)
	r = sh.exec({installed, "locate"}, {env = child_env(f)})
	testing.expect(t, r.ok, sh.error(r))
	testing.expect_value(t, strings.trim_space(r.stdout), f.vault)

	// The installed hooks gate a commit in the vault, with no checkout on PATH.
	git(t, f.vault, "add", "-A")
	r = sh.exec({"git", "-c", "user.email=t@example.com", "-c", "user.name=test", "commit", "-q", "-m", "clean"}, {dir = f.vault, env = child_env(f)})
	testing.expect(t, r.ok, sh.error(r))
	testing.expect_value(t, path.append_file(path.join(f.vault, "AI", "MEMORY.md"), "- **undated** (aliases: x) — no date — fixture\n"), nil)
	git(t, f.vault, "add", "-A")
	r = sh.exec({"git", "-c", "user.email=t@example.com", "-c", "user.name=test", "commit", "-q", "-m", "probe"}, {dir = f.vault, env = child_env(f)})
	testing.expect(t, !r.ok, "the installed pre-commit hook let an undated bullet through")
	testing.expect(t, strings.contains(strings.concatenate({r.stdout, r.stderr}), "has no trailing ISO date"), r.stderr)

	o, _, code = exec(f.cli, "uninstall")
	testing.expect_value(t, code, 0)
	testing.expect(t, !os.exists(f.cli.conf_vault), "the vault binding is gone")
	testing.expect(t, !os.exists(hooks), "the written hooks are gone")
	testing.expect(t, !os.exists(installed) && !is_link(installed), "the command is gone")
	bashrc, _ = path.read(path.join(f.home, ".bashrc"))
	testing.expect(t, !strings.contains(bashrc, "brain:"), bashrc)
}

// child_env is the process environment with the fixture's home in place of
// the real one and nothing that could point at the real tool or vault.
child_env :: proc(f: Fixture) -> []string {
	env := make([dynamic]string)
	drop := [?]string{"HOME=", "XDG_CONFIG_HOME=", "XDG_STATE_HOME=", "BRAIN_VAULT=", "BRAIN_STATE=", "BRAIN_TOOL=", "USERPROFILE="}
	all, _ := os.environ(context.allocator)
	outer: for kv in all {
		for d in drop {
			if strings.has_prefix(kv, d) {
				continue outer
			}
		}
		append(&env, kv)
	}
	append(&env, strings.concatenate({"HOME=", f.home}))
	append(&env, strings.concatenate({"USERPROFILE=", f.home}))
	append(&env, strings.concatenate({"XDG_CONFIG_HOME=", path.join(f.home, ".config")}))
	append(&env, strings.concatenate({"BRAIN_STATE=", f.state}))
	return env[:]
}

// With no vault named, install binds the recorded one, or creates the
// canonical vault; it never searches. The starter vault passes lint and is a
// git repository, and a second install keeps it rather than creating again.
@(test)
install_creates_the_canonical_vault_when_none_is_named :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	if _, found := sh.which("git"); !found {
		return
	}
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.env["BRAIN_VAULT"] = ""
	f.cli.env["GOPATH"] = ""
	f.cli.env["GOBIN"] = ""
	f.cli.env["PATH"] = ""
	cwd, _ := os.get_working_directory(context.allocator)
	f.cli.env["BRAIN_EXE"] = path.join(cwd, "build", "debug", strings.concatenate({"brain", EXE}))
	canonical := path.join(f.home, "Documents", "Brain")

	o, e, code := exec(f.cli, "install", "--dry-run")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, canonical) && strings.contains(o, "created a new vault"), o)
	testing.expect(t, !os.exists(canonical), "a dry run creates nothing")

	o, e, code = exec(f.cli, "install")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, e, "")
	testing.expect_value(t, recorded_path(f.cli.conf_vault), canonical)
	for file in STARTER {
		testing.expect(t, os.is_file(path.join(canonical, file.name)), file.name)
	}
	testing.expect(t, os.is_dir(path.join(canonical, ".git")), "the new vault is a git repository")
	o, e, code = exec(f.cli, "lint")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "0 failure(s), 0 warning(s)"), o)

	testing.expect_value(t, path.write(path.join(canonical, "AI", "MEMORY.md"), "# Memory\n\nmine\n"), nil)
	o, _, code = exec(f.cli, "install")
	testing.expect_value(t, code, 0)
	testing.expect(t, !strings.contains(o, "created a new vault"), o)
	mem, _ := path.read(path.join(canonical, "AI", "MEMORY.md"))
	testing.expect_value(t, mem, "# Memory\n\nmine\n")

	// The recorded vault outranks the canonical one; a named one outranks both.
	testing.expect_value(t, recorded_path(f.cli.conf_vault), canonical)
	f.cli.env["BRAIN_VAULT"] = f.vault
	o, _, code = exec(f.cli, "install", "--dry-run")
	testing.expect(t, strings.contains(o, strings.concatenate({"vault: ", f.vault})), o)
	f.cli.env["BRAIN_VAULT"] = path.join(f.root, "missing")
	_, e, code = exec(f.cli, "install", "--dry-run")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "no such directory"), e)
}

// The installer registers `brain pack` as a Claude Code SessionStart hook in
// the user's settings, beside what is there, once; uninstall removes only it.
@(test)
install_registers_the_pack_hook_beside_existing_settings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	settings := path.join(f.home, ".claude", "settings.json")
	testing.expect_value(t, path.mkdirs(path.dir(settings)), nil)
	existing := `{"theme": "dark", "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo hi"}]}], "Stop": []}}`
	testing.expect_value(t, path.write(settings, existing), nil)
	cwd, _ := os.get_working_directory(context.allocator)
	f.cli.env["BRAIN_EXE"] = path.join(cwd, "build", "debug", strings.concatenate({"brain", EXE}))
	git(t, f.vault, "init", "-q")
	o, _, code := exec(f.cli, "install", f.vault)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "SessionStart hook added"), o)
	text, _ := path.read(settings)
	testing.expect(t, strings.contains(text, `"theme": "dark"`), "other settings survive")
	testing.expect(t, strings.contains(text, `"command": "echo hi"`), "other hooks survive")
	testing.expect(t, strings.contains(text, `pack 2>/dev/null || true"`), "the pack hook is there")
	testing.expect(t, strings.contains(text, `"matcher": "startup|clear|compact"`), "with its matcher")
	testing.expect_value(t, strings.count(text, "pack 2>/dev/null"), 1)
	o, _, code = exec(f.cli, "install", f.vault)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "SessionStart hook present"), o)
	text, _ = path.read(settings)
	testing.expect_value(t, strings.count(text, "pack 2>/dev/null"), 1)
	o, _, code = exec(f.cli, "uninstall")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "SessionStart hook removed"), o)
	text, _ = path.read(settings)
	testing.expect_value(t, strings.count(text, "pack 2>/dev/null"), 0)
	testing.expect(t, strings.contains(text, `"command": "echo hi"`), "the other hook is still there")
	testing.expect(t, strings.contains(text, `"Stop"`), "and the other event")
}

// A settings file that does not parse is left alone and named.
@(test)
install_leaves_a_broken_settings_file_alone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	settings := path.join(f.home, ".claude", "settings.json")
	testing.expect_value(t, path.mkdirs(path.dir(settings)), nil)
	testing.expect_value(t, path.write(settings, "{ not json"), nil)
	cwd, _ := os.get_working_directory(context.allocator)
	f.cli.env["BRAIN_EXE"] = path.join(cwd, "build", "debug", strings.concatenate({"brain", EXE}))
	git(t, f.vault, "init", "-q")
	o, _, code := exec(f.cli, "install", f.vault)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "does not parse"), o)
	text, _ := path.read(settings)
	testing.expect_value(t, text, "{ not json")
}

// A managed block reports what it did: added, current, refreshed.
@(test)
block_apply_reports_its_outcome :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	file := path.join(f.root, "notes.md")
	testing.expect_value(t, block_apply(f.cli, file, "t", "<!--", "-->", "one", "brain test"), "added")
	testing.expect_value(t, block_apply(f.cli, file, "t", "<!--", "-->", "one", "brain test"), "current")
	testing.expect_value(t, block_apply(f.cli, file, "t", "<!--", "-->", "two", "brain test"), "refreshed")
	text, _ := path.read(file)
	testing.expect(t, strings.has_prefix(text, "<!-- brain:t >>> managed by `brain test`") && strings.contains(text, "\ntwo\n") && !strings.contains(text, "\none\n"), text)
}

// Bytes logged by a lookup survive a reindex, which carries the log over.
@(test)
reindex_carries_the_bytes_column :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, _ := exec(f.cli, "find", "sqlite")
	_, _, code := exec(f.cli, "reindex")
	testing.expect_value(t, code, 0)
	db, err := open_db(f.cli.db)
	testing.expect_value(t, err, "")
	defer sqlite3.close(&db)
	testing.expect_value(t, scalar_text(db, "select bytes from queries order by id desc limit 1"), int_str(i64(len(o))))
}

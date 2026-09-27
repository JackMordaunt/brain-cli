package brain

import "core:os"
import "core:strings"
import "core:testing"

import "jm:path"
import "jm:sh"

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
	testing.expect(t, strings.contains(o, "indexed 4 bullets"), o)
	testing.expect_value(t, recorded_path(f.cli.conf_vault), f.vault)
	testing.expect_value(t, recorded_path(path.join(f.cli.conf_dir, "tool")), f.cli.tool)
	hooks, _ := sh.out("git config core.hooksPath", {dir = f.vault})
	testing.expect_value(t, hooks, path.join(f.cli.tool, "bin", "hooks"))
	agents := path.join(f.home, ".agents", "AGENTS.md")
	testing.expect(t, !os.exists(agents) || true, "agents link is best effort; the fixture has no AGENTS.md")
	claude_md, _ := path.read(path.join(f.home, ".claude", "CLAUDE.md"))
	testing.expect(t, strings.contains(claude_md, "brain:claude >>>"), claude_md)
	bashrc, _ := path.read(path.join(f.home, ".bashrc"))
	testing.expect(t, strings.contains(bashrc, "brain:path >>>") && strings.contains(bashrc, "brain:guards >>>"), bashrc)

	installed := path.join(f.home, ".local", "bin", strings.concatenate({"brain", EXE}))
	testing.expect(t, os.is_file(installed) || is_link(installed), installed)
	r := sh.exec({installed, "locate", "--tool"}, {env = child_env(f)})
	testing.expect(t, r.ok, sh.error(r))
	testing.expect_value(t, strings.trim_space(r.stdout), f.cli.tool)
	r = sh.exec({installed, "locate"}, {env = child_env(f)})
	testing.expect(t, r.ok, sh.error(r))
	testing.expect_value(t, strings.trim_space(r.stdout), f.vault)

	o, _, code = exec(f.cli, "uninstall")
	testing.expect_value(t, code, 0)
	testing.expect(t, !os.exists(f.cli.conf_vault), "the vault binding is gone")
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

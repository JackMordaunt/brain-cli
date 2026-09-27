package brain

import "core:os"
import "core:strings"
import "core:testing"

import "jm:path"
import "jm:sh"

// The hooks must find the CLI as their own sibling, not inside the repo
// being committed: when the tool lived in the vault, `$root/bin/brain`
// worked by accident, and splitting them turned the gate into a silent pass.
@(test)
pre_commit_gate_fires_from_outside_the_repo :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	if _, found := sh.which("git"); !found {
		return
	}
	f := fixture(t)
	defer fixture_destroy(f)
	cwd, _ := os.get_working_directory(context.allocator)
	git(t, f.vault, "init", "-q")
	git(t, f.vault, "config", "core.hooksPath", path.join(cwd, "bin", "hooks"))
	git(t, f.vault, "add", "-A")
	r := sh.exec({"git", "-c", "user.email=t@example.com", "-c", "user.name=test", "commit", "-q", "-m", "clean"}, {dir = f.vault})
	testing.expect(t, r.ok, sh.error(r))

	mem := path.join(f.vault, "AI", "MEMORY.md")
	testing.expect_value(t, path.append_file(mem, "- **undated** (aliases: x) — a bullet with no trailing date — fixture\n"), nil)
	git(t, f.vault, "add", "-A")
	r = sh.exec({"git", "-c", "user.email=t@example.com", "-c", "user.name=test", "commit", "-q", "-m", "probe"}, {dir = f.vault})
	testing.expect(t, !r.ok, "pre-commit let an undated bullet through")
	// git hands a hook's stdout to the terminal as stderr.
	said := strings.concatenate({r.stdout, r.stderr})
	testing.expect(t, strings.contains(said, "has no trailing ISO date"), said)
}

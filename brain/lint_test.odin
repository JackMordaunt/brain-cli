package brain

import "core:strings"
import "core:testing"

import "jm:path"
import "jm:sh"

@(test)
lint_passes_the_fixture_and_fails_an_undated_bullet :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, code := exec(f.cli, "lint")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "brain lint: 0 failure(s), 0 warning(s)\n")

	mem := path.join(f.vault, "AI", "MEMORY.md")
	testing.expect_value(t, path.append_file(mem, "- **undated** (aliases: x) — no date here — fixture\n"), nil)
	o, _, code = exec(f.cli, "lint")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(o, "FAIL AI/MEMORY.md: **undated** has no trailing ISO date"), o)
}

@(test)
lint_flags_secrets_and_warns_on_form :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	mem := path.join(f.vault, "AI", "MEMORY.md")
	long := strings.repeat("x", MAXLEN + 1)
	testing.expect_value(
		t,
		path.append_file(
			mem,
			strings.concatenate(
				{
					"- **leaky** (aliases: l) — password: abcdefghijklmnopqrstuvwx — src — 2026-01-01\n",
					"- **safe** (aliases: s) — password: $VAULT_PASSWORD — src — 2026-01-01\n",
					"- **noalias** — a fact — src — 2026-01-01\n",
					"- **long** (aliases: l) — ",
					long,
					" — src — 2026-01-01\n",
					"- **future** (aliases: f) — a fact — src — 2999-01-01\n",
				},
			),
		),
		nil,
	)
	o, _, code := exec(f.cli, "lint")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(o, "**leaky** looks like it carries a literal secret"), o)
	testing.expect(t, !strings.contains(o, "**safe**"), "a placeholder is not a secret")
	testing.expect(t, strings.contains(o, "**noalias** has no aliases"), o)
	testing.expect(t, strings.contains(o, "**long** fact is 420 chars"), o)
	testing.expect(t, strings.contains(o, "**future** is dated in the future (2999-01-01)"), o)
	testing.expect(t, strings.has_suffix(o, "brain lint: 2 failure(s), 2 warning(s)\n"), o)
}

@(test)
lint_reads_a_crlf_vault :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	for name in ([3]string{"MEMORY.md", "LEARNINGS.md", "TUNINGS.md"}) {
		p := path.join(f.vault, "AI", name)
		text, err := path.read(p)
		testing.expect_value(t, err, nil)
		crlf, _ := strings.replace_all(text, "\n", "\r\n")
		testing.expect_value(t, path.write(p, crlf), nil)
	}
	o, _, code := exec(f.cli, "lint")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "brain lint: 0 failure(s), 0 warning(s)\n")
}

// --staged reads git's index, so an undated bullet that is staged fails and
// the same bullet unstaged does not.
@(test)
lint_staged_reads_the_git_index :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	if _, found := sh.which("git"); !found {
		return
	}
	f := fixture(t)
	defer fixture_destroy(f)
	git(t, f.vault, "init", "-q")
	git(t, f.vault, "add", "-A")
	o, _, code := exec(f.cli, "lint", "--staged")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "brain lint: 0 failure(s), 0 warning(s)\n")

	mem := path.join(f.vault, "AI", "MEMORY.md")
	testing.expect_value(t, path.append_file(mem, "- **undated** (aliases: x) — no date here — fixture\n"), nil)
	_, _, code = exec(f.cli, "lint", "--staged")
	testing.expect_value(t, code, 0)
	git(t, f.vault, "add", "-A")
	o, _, code = exec(f.cli, "lint", "--staged")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(o, "**undated** has no trailing ISO date"), o)
}

git :: proc(t: ^testing.T, dir: string, args: ..string) {
	argv := make([dynamic]string)
	append(&argv, "git", "-c", "user.email=t@example.com", "-c", "user.name=test")
	append(&argv, ..args)
	r := sh.exec(argv[:], {dir = dir})
	testing.expect(t, r.ok, sh.error(r))
}

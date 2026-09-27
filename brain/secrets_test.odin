package brain

import "core:strings"
import "core:testing"

import "jm:path"
import "jm:sh"

// The fixtures are assembled at run time: a literal that looks like a key,
// even a made-up one, is what push protection and gitleaks exist to catch.
fake_aws_key :: proc() -> string {
	return strings.concatenate({"AKIA", strings.repeat("Q", 16)})
}

fake_github_token :: proc() -> string {
	return strings.concatenate({"gh", "p_", strings.repeat("q", 20), strings.repeat("Q", 20)})
}

@(test)
fallback_patterns_catch_keys_and_skip_shas :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	hits := fallback_hits(
		strings.concatenate(
			{
				"clean line\n",
				"+aws ", fake_aws_key(), " here\n",
				"+sha 0123456789abcdef0123456789abcdef01234567\n",
				"+-----BEGIN RSA PRIVATE KEY-----\n",
				"+token ", fake_github_token(), "\n",
			},
		),
	)
	testing.expect_value(t, len(hits), 3)
	testing.expect(t, strings.has_prefix(hits[0], "2:"), hits[0])
	testing.expect(t, strings.has_prefix(hits[1], "4:"), hits[1])
	testing.expect(t, strings.has_prefix(hits[2], "5:"), hits[2])
}

// Without gitleaks the staged diff is scanned with the built-in patterns;
// with it, gitleaks decides. Either way a staged AWS key fails the gate.
@(test)
secrets_scans_the_staged_change :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	if _, found := sh.which("git"); !found {
		return
	}
	f := fixture(t)
	defer fixture_destroy(f)
	git(t, f.vault, "init", "-q")
	git(t, f.vault, "add", "-A")
	o, _, code := exec(f.cli, "secrets", "--staged")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "brain secrets: clean"), o)

	mem := path.join(f.vault, "AI", "MEMORY.md")
	testing.expect_value(
		t,
		path.append_file(mem, strings.concatenate({"- **aws** (aliases: key) — ", fake_aws_key(), " — src — 2026-01-01\n"})),
		nil,
	)
	git(t, f.vault, "add", "-A")
	e: string
	_, e, code = exec(f.cli, "secrets", "--staged")
	testing.expect_value(t, code, 1)
	testing.expect(t, e != "", "the finding is reported")
}

package brain

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "jm:path"
import "jm:sh"

// sync_fixture versions the fixture vault and gives it a place to meet other
// machines: a bare repository beside it, under a remote name that is not
// origin, as a vault versioned by hand might have.
sync_fixture :: proc(t: ^testing.T, f: ^Fixture) -> (origin: string) {
	origin = path.join(f.root, "origin.git")
	testing.expect(t, sh.exec({"git", "init", "-q", "--bare", "-b", "main", origin}).ok, "bare origin")
	g := proc(dir: string, args: ..string) -> sh.Result {
		argv := make([dynamic]string)
		append(&argv, "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false")
		append(&argv, ..args)
		return sh.exec(argv[:], {dir = dir})
	}
	testing.expect(t, g(f.vault, "init", "-q", "-b", "main").ok, "init")
	testing.expect(t, g(f.vault, "add", "-A").ok, "add")
	testing.expect(t, g(f.vault, "commit", "-q", "-m", "start").ok, "commit")
	// Named `github`, not `origin`: a vault versioned by hand before brain.
	testing.expect(t, g(f.vault, "remote", "add", "github", origin).ok, "remote")
	return
}

// Two machines, one vault: what changes here is written down and sent, what
// the other wrote is received and indexed; off means nothing moves.
@(test)
sync_sends_receives_and_can_be_turned_off :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	_, found := sh.which("git")
	testing.expect(t, found, "sync is built on git; a machine without it cannot run these tests")
	if !found {
		return
	}
	f := fixture(t)
	defer fixture_destroy(f)
	origin := sync_fixture(t, &f)

	o, _, code := exec(f.cli, "sync")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "sent "), o)
	attrs, _ := path.read(path.join(f.vault, ".gitattributes"))
	testing.expect_value(t, attrs, SYNC_ATTRIBUTES)

	// A change here is written down, through the vault's own gates, and sent.
	mem := path.join(f.vault, "AI", "MEMORY.md")
	text, _ := path.read(mem)
	testing.expect_value(t, path.write(mem, strings.concatenate({text, "- **sync fact** (aliases: here) — written on the first machine — fixture — 2026-01-07\n"})), nil)
	o, _, code = exec(f.cli, "sync")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "wrote down 1 change") && strings.contains(o, "sent 1"), o)

	// Another machine clones, adds a fact, sends it; this one receives it.
	other := path.join(f.root, "other")
	testing.expect(t, sh.exec({"git", "clone", "-q", origin, other}).ok, "clone")
	otext, _ := path.read(path.join(other, "AI", "MEMORY.md"))
	testing.expect(t, strings.contains(otext, "**sync fact**"), "the clone has the first machine's fact")
	testing.expect_value(t, path.write(path.join(other, "AI", "MEMORY.md"), strings.concatenate({otext, "- **other fact** (aliases: there) — written on the other machine — fixture — 2026-01-08\n"})), nil)
	for args in ([3][]string{{"add", "-A"}, {"commit", "-q", "-m", "other"}, {"push", "-q", "origin", "main"}}) {
		argv := make([dynamic]string)
		append(&argv, "git", "-c", "user.name=o", "-c", "user.email=o@o", "-c", "commit.gpgsign=false")
		append(&argv, ..args)
		testing.expect(t, sh.exec(argv[:], {dir = other}).ok, args[0])
	}
	o, _, code = exec(f.cli, "sync")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "received 1"), o)
	o, _, _ = exec(f.cli, "find", "other", "fact")
	testing.expect(t, strings.contains(o, "**other fact**"), "received facts answer finds")

	// Status says where and what.
	o, _, _ = exec(f.cli, "sync", "status")
	testing.expect(t, strings.has_prefix(o, "sync on\nconnected: ") && strings.contains(o, "last: "), o)

	// Off: nothing moves, and the hooks' passes say nothing.
	o, _, code = exec(f.cli, "sync", "off")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "sync off"), o)
	text, _ = path.read(mem)
	path.write(mem, strings.concatenate({text, "- **unsent** (aliases: stays) — written while off — fixture — 2026-01-09\n"}))
	o, _, _ = exec(f.cli, "sync")
	testing.expect(t, strings.has_prefix(o, "sync is off"), o)
	r := vault_sync(f.cli, .Full)
	testing.expect(t, r.off, "the hooks' pass does nothing")
	exec(f.cli, "sync", "on")

	// A line the gates refuse waits, and says why: a bullet with no date.
	path.write(mem, strings.concatenate({text, "- **undated** (aliases: no date) — a fact with no date — fixture\n"}))
	o, _, code = exec(f.cli, "sync")
	testing.expect(t, strings.contains(o, "changes waiting"), o)
}

// A second machine's fresh install adopts the vault it connects to instead
// of merging two welcome pages.
@(test)
sync_connect_adopts_an_existing_vault :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	_, found := sh.which("git")
	testing.expect(t, found, "sync is built on git; a machine without it cannot run these tests")
	if !found {
		return
	}
	f := fixture(t)
	defer fixture_destroy(f)
	origin := sync_fixture(t, &f)
	exec(f.cli, "sync")

	// A fresh vault from the starter, on another machine.
	fresh := path.join(f.root, "fresh")
	testing.expect_value(t, create_vault(f.cli, fresh), "")
	f.cli.vault = fresh
	f.cli.env["BRAIN_VAULT"] = fresh
	o, _, code := exec(f.cli, "sync", "connect", origin)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "connected: ") , o)
	text, _ := path.read(path.join(fresh, "AI", "MEMORY.md"))
	testing.expect(t, strings.contains(text, "**sqlite**"), "the fresh vault became the shared one")
}

// The hooks start a pass and return at once; the pass runs on its own,
// one at a time, and the result shows up in the state and at the far side.
@(test)
sync_runs_in_the_background :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// On Windows the pass is detached with `start /b` through cmd; this test
	// runs there too, on CI, and is the only check that path has.
	_, found := sh.which("git")
	testing.expect(t, found, "sync is built on git; a machine without it cannot run these tests")
	if !found {
		return
	}
	f := fixture(t)
	defer fixture_destroy(f)
	origin := sync_fixture(t, &f)
	cwd, _ := os.get_working_directory(context.allocator)
	f.cli.env["BRAIN_EXE"] = path.join(cwd, "build", "debug", strings.concatenate({"brain", EXE}))

	mem := path.join(f.vault, "AI", "MEMORY.md")
	text, _ := path.read(mem)
	testing.expect_value(t, path.write(mem, strings.concatenate({text, "- **background fact** (aliases: later) — written and sent while nothing waited — fixture — 2026-01-10\n"})), nil)
	started := time.now()
	sync_in_background(f.cli, .Full)
	testing.expect(t, time.since(started) < time.Second, "the caller does not wait for the network")
	last := path.join(f.state, "sync", "last")
	for _ in 0 ..< 200 {
		if os.exists(last) {
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect(t, os.exists(last), "the pass finished on its own")
	log := sh.exec({"git", "--git-dir", origin, "log", "--oneline"})
	testing.expect(t, strings.contains(log.stdout, "sync: ") && strings.contains(log.stdout, "from "), log.stdout)
	testing.expect(t, !os.exists(path.join(f.state, "sync", "lock")), "the lock is released")
	// A lock a live pass holds keeps a second pass out.
	testing.expect(t, sync_lock(f.cli), "lock taken")
	testing.expect(t, !sync_lock(f.cli), "a second pass waits")
	sync_unlock(f.cli)
}

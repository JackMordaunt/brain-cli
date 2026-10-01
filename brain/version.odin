package brain

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "jm:path"
import "jm:selfupdate"

// VERSION is the release tag, baked in by the release workflow with
// -define:VERSION. A local build has none, which selfupdate treats as a
// development build and leaves alone.
VERSION :: #config(VERSION, "")

// COMMIT is the commit the binary was built from, short, with "-dirty"
// when the working tree had uncommitted changes; the justfile and the
// release workflow pass it with -define:COMMIT, quoted so that a hash such
// as 21e17ac is not read as a number, and commit_stamp strips the quotes.
// release.yml's Windows build, under Git Bash, has delivered them escaped
// (run 36720442466 reported the commit as \7642491\), so backslashes go too. A build made some other way says so.
COMMIT :: #config(COMMIT, "")

commit_stamp :: proc() -> string {
	return strings.trim(COMMIT, "\"\\")
}

// Where releases are served. Any host that serves the asset, sha256sums.txt,
// its signature and version.txt under one path works; this is the GitHub
// one. BRAIN_RELEASE_BASE overrides it. install.sh and install.ps1 repeat
// it, since they run before any binary exists; just test-installer checks
// that all three agree.
RELEASE_BASE :: "https://github.com/JackMordaunt/brainfold/releases/latest/download"

// ASSET is this build's file name in a release.
when ODIN_OS == .Windows {
	ASSET :: "brain-windows-amd64.exe"
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	ASSET :: "brain-darwin-arm64"
} else when ODIN_OS == .Darwin {
	ASSET :: "brain-darwin-amd64"
} else when ODIN_ARCH == .arm64 {
	ASSET :: "brain-linux-arm64"
} else {
	ASSET :: "brain-linux-amd64"
}

// The Ed25519 key that signs sha256sums.txt in the release workflow; its
// private half is the repository secret BRAIN_SIGNING_KEY. Nothing from a
// release is trusted until it verifies under this key.
PUBLIC_KEY :: "669f31988381713bf2698ce408ace480fdf0130e2e3168e3916d67cf6afe56dc"

cmd_version :: proc(cli: ^Cli, args: []string) -> int {
	stamp := commit_stamp()
	commit := stamp == "" ? "unknown commit" : stamp
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "version", VERSION == "" ? "dev" : VERSION)
		jw_field(&w, "commit", stamp)
		jw_field_bool(&w, "dirty", strings.has_suffix(stamp, "-dirty"))
		jw_field(&w, "asset", ASSET)
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	outf(cli, "brain %s (%s) built from %s\n", VERSION == "" ? "dev" : VERSION, ASSET, commit)
	return 0
}

// The decoded public key; selfupdate keeps a slice of it.
public_key: [32]byte

update_config :: proc(cli: ^Cli, mode: selfupdate.Mode) -> selfupdate.Config {
	selfupdate.key_from_hex(PUBLIC_KEY, public_key[:])
	key := public_key[:]
	return selfupdate.Config {
		base_url = getenv(cli, "BRAIN_RELEASE_BASE", RELEASE_BASE),
		version = VERSION,
		asset = ASSET,
		public_key = key,
		mode = mode,
		state_dir = cli.state,
	}
}

// brain update: fetch the latest release, verify it, replace this binary
// and run it again. The new binary re-runs `update` and reports itself
// up to date.
cmd_update :: proc(cli: ^Cli, args: []string) -> int {
	r := selfupdate.run(update_config(cli, .Apply))
	remember_check(cli, &r)
	switch r.outcome {
	case .Up_To_Date:
		outf(cli, "brain %s is up to date\n", VERSION)
	case .Applied:
		if r.patched {
			outf(cli, "updated to %s by a %d KB patch\n", selfupdate.version(&r), r.patch_bytes / 1000)
		} else {
			outf(cli, "updated to %s\n", selfupdate.version(&r))
		}
	case .Update_Available, .Skipped:
		outf(cli, "%s\n", selfupdate.message(&r))
	case .Refused, .Failed:
		return fail(cli, selfupdate.message(&r))
	}
	return 0
}

// UPDATE_FILE holds the version the last daily check found newer than this
// build, so the hint repeats on every run until `brain update` while the
// network is asked at most once a day.
UPDATE_FILE :: "update-available"

// NOTIFY_TIMEOUT bounds each download of the daily check; a person is waiting.
NOTIFY_TIMEOUT :: 3 * time.Second

// notify_update tells a person at a terminal that a newer release is out,
// after the command's own output. It is silent for hooks, agents and pipes,
// where stderr is not a terminal, and whenever BRAIN_NO_UPDATE is set.
notify_update :: proc(cli: ^Cli) {
	if VERSION == "" || getenv(cli, "BRAIN_NO_UPDATE") != "" || !os.is_tty(os.stderr) {
		return
	}
	cfg := update_config(cli, .Notify)
	cfg.timeout = NOTIFY_TIMEOUT
	r := selfupdate.run(cfg)
	remember_check(cli, &r)
	if hint := update_hint(cli); hint != "" {
		errf(cli, "%s\n", hint)
	}
}

// remember_check keeps what a check learned. A failed check still counts as
// the day's check, so an offline machine waits a day rather than stalling
// every run on the timeout.
remember_check :: proc(cli: ^Cli, r: ^selfupdate.Result) {
	avail := path.join(cli.state, UPDATE_FILE)
	switch r.outcome {
	case .Update_Available:
		path.mkdirs(cli.state)
		v := selfupdate.version(r)
		path.write(avail, v == "" ? "a newer release" : v)
	case .Up_To_Date, .Applied:
		os.remove(avail)
	case .Failed:
		path.mkdirs(cli.state)
		path.write(path.join(cli.state, selfupdate.STAMP_FILE), "")
	case .Skipped, .Refused:
	}
}

// update_hint is the line a person sees while a newer release is waiting,
// or "" when none is.
update_hint :: proc(cli: ^Cli) -> string {
	v, err := path.read(path.join(cli.state, UPDATE_FILE))
	v = strings.trim_space(v)
	if err != nil || v == "" || v == VERSION {
		return ""
	}
	return fmt.aprintf("brain %s is available; run `brain update`", v)
}

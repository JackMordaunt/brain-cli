package brain

import "core:os"

import "jm:selfupdate"

// VERSION is the release tag, baked in by the release workflow with
// -define:VERSION. A local build has none, which selfupdate treats as a
// development build and leaves alone.
VERSION :: #config(VERSION, "")

REPO :: "JackMordaunt/brain-cli"

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
	outf(cli, "brain %s (%s)\n", VERSION == "" ? "dev" : VERSION, ASSET)
	return 0
}

update_config :: proc(cli: ^Cli, mode: selfupdate.Mode) -> selfupdate.Config {
	key, _ := selfupdate.key_from_hex(PUBLIC_KEY)
	return selfupdate.Config {
		repo = REPO,
		base_url = getenv(cli, "BRAIN_RELEASE_BASE"),
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
	switch r.outcome {
	case .Up_To_Date:
		outf(cli, "brain %s is up to date\n", VERSION)
	case .Applied:
		outf(cli, "updated to %s\n", r.version)
	case .Update_Available, .Skipped:
		outf(cli, "%s\n", r.message)
	case .Refused:
		return fail(cli, r.message)
	case .Failed:
		return fail(cli, r.message)
	}
	return 0
}

// notify_update tells a person at a terminal that a newer release exists,
// at most once a day. It is silent for hooks, agents and pipes, where
// stderr is not a terminal, and whenever BRAIN_NO_UPDATE is set.
notify_update :: proc(cli: ^Cli) {
	if VERSION == "" || getenv(cli, "BRAIN_NO_UPDATE") != "" || !os.is_tty(os.stderr) {
		return
	}
	r := selfupdate.run(update_config(cli, .Notify))
	if r.outcome == .Update_Available {
		errf(cli, "brain: %s (run `brain update`)\n", r.message)
	}
}

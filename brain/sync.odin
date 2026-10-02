package brain

import "core:os"
import "core:strings"
import "core:time"

import "jm:path"
import "jm:sh"

// Sync keeps every machine's vault the same vault. It is on by default and
// needs nothing set up on one machine; on two, `brain sync connect <url>`
// (or `connect github`) names the place they meet. It runs when a session
// starts (receive what other machines wrote) and when an agent stops
// (write down what changed here, send it), inside the hooks' time budget
// and never failing a hook, and `brain sync` runs it by hand. The vault is
// versioned underneath; the surface speaks in outcomes: up to date, sent,
// received, changes waiting, not connected, offline. `brain sync off`
// turns it off for this machine.

SYNC_CONF :: "sync" // ~/.config/brain/sync: on or off
SYNC_RECEIVE_TIMEOUT :: 4 * time.Second // a session start waits this long at most
SYNC_SEND_TIMEOUT :: 8 * time.Second
SYNC_OFFLINE_HOLD :: 10 * time.Minute // after a failed reach, do not try again before this

// SYNC_ATTRIBUTES makes the fact files merge line by line: two machines that
// each appended bullets never conflict.
SYNC_ATTRIBUTES :: "AI/*.md merge=union\n"

Sync_Mode :: enum {
	Receive, // bring other machines' changes in
	Full, // write down what changed here, receive, send
}

Sync_Report :: struct {
	off, no_git, no_repo, connected, offline: bool,
	remote:                                   string,
	wrote:                                    int, // files written down here
	sent, received:                           int, // changes sent and received
	waiting:                                  string, // why the changes here could not be written down
	conflict:                                 string, // files both sides changed
	err:                                      string,
}

// sync_enabled reads BRAIN_SYNC, then the setting `brain sync on|off`
// wrote, and defaults to on.
sync_enabled :: proc(cli: ^Cli) -> bool {
	v := getenv(cli, "BRAIN_SYNC")
	if v == "" {
		v = strings.trim_space(first_line(path.join(cli.conf_dir, SYNC_CONF)))
	}
	return v != "off"
}

cmd_sync :: proc(cli: ^Cli, args: []string) -> int {
	usage := "usage: brain sync [on|off|status|connect <url>|connect github]"
	if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	if len(args) == 0 {
		r := vault_sync(cli, .Full, force = true)
		return sync_say(cli, r)
	}
	switch args[0] {
	case "on", "off":
		if len(args) != 1 {
			return fail(cli, usage)
		}
		if err := path.mkdirs(cli.conf_dir); err != nil {
			return fail(cli, strings.concatenate({"cannot create ", cli.conf_dir}))
		}
		if err := path.write(path.join(cli.conf_dir, SYNC_CONF), strings.concatenate({args[0], "\n"})); err != nil {
			return fail(cli, "cannot write the sync setting")
		}
		if cli.json {
			w := jw_make()
			jw_obj(&w)
			jw_field(&w, "sync", args[0])
			jw_end_obj(&w)
			jw_flush(cli, &w)
		} else if args[0] == "on" {
			out(cli, "sync on: this machine sends what changes and receives what others wrote\n")
		} else {
			out(cli, "sync off: the vault stays on this machine until brain sync on\n")
		}
		return 0
	case "status":
		return sync_status(cli)
	case "connect":
		if len(args) != 2 {
			return fail(cli, usage)
		}
		return sync_connect(cli, args[1])
	}
	return fail(cli, usage)
}

// run_git runs one git command in the vault, with a time limit.
run_git :: proc(cli: ^Cli, args: []string, timeout: time.Duration = 0) -> sh.Result {
	argv := make([dynamic]string)
	append(&argv, "git")
	if len(args) > 0 && args[0] == "commit" {
		// A write-down is the machine's, not a signed statement of the person's,
		// so it is not signed: on 2026-10-02 a machine set to sign every commit
		// failed each write-down with "gpg failed to sign the data".
		append(&argv, "-c", "commit.gpgsign=false")
		// A machine with no name set up can still write down what changed.
		if strings.trim_space(sh.exec({"git", "config", "user.email"}, {dir = cli.vault}).stdout) == "" {
			append(&argv, "-c", "user.name=brain", "-c", strings.concatenate({"user.email=brain@", host_name()}))
		}
	}
	append(&argv, ..args)
	return sh.exec(argv[:], {dir = cli.vault, timeout = timeout})
}

host_name :: proc() -> string {
	for key in ([2]string{"HOSTNAME", "COMPUTERNAME"}) {
		if h := os.get_env(key, context.allocator); h != "" {
			return h
		}
	}
	if r := sh.exec({"hostname"}); r.ok && strings.trim_space(r.stdout) != "" {
		return strings.trim_space(r.stdout)
	}
	return "this machine"
}

// vault_sync is one pass. force runs even when a recent reach failed, for
// the command typed by hand; the hooks respect the offline hold.
vault_sync :: proc(cli: ^Cli, mode: Sync_Mode, force := false) -> (r: Sync_Report) {
	if !sync_enabled(cli) {
		r.off = true
		return
	}
	if _, found := sh.which("git"); !found {
		r.no_git = true
		return
	}
	if !os.exists(path.join(cli.vault, ".git")) {
		r.no_repo = true
		return
	}
	attrs := path.join(cli.vault, ".gitattributes")
	if !os.exists(attrs) {
		path.write(attrs, SYNC_ATTRIBUTES)
	}
	if mode == .Full {
		r.wrote, r.waiting = sync_write_down(cli)
	}
	name := remote_name(cli)
	if name == "" {
		return
	}
	r.remote = strings.trim_space(run_git(cli, {"remote", "get-url", name}).stdout)
	r.connected = true
	hold := path.join(cli.state, "sync", "offline-until")
	if !force {
		if until := strings.trim_space(first_line(hold)); until != "" && until > now_iso() {
			r.offline = true
			return
		}
	}
	branch := strings.trim_space(run_git(cli, {"rev-parse", "--abbrev-ref", "HEAD"}).stdout)
	if branch == "" || branch == "HEAD" {
		branch = "main"
	}
	before := strings.trim_space(run_git(cli, {"rev-parse", "HEAD"}).stdout)
	pull := run_git(cli, {"pull", "--rebase", "--autostash", "-q", name, branch}, mode == .Receive ? SYNC_RECEIVE_TIMEOUT : SYNC_SEND_TIMEOUT)
	if !pull.ok {
		text := strings.concatenate({pull.stdout, "\n", pull.stderr})
		if strings.contains(text, "CONFLICT") || strings.contains(text, "could not apply") {
			run_git(cli, {"rebase", "--abort"})
			r.conflict = conflict_files(text)
		} else if strings.contains(text, "couldn't find remote ref") || strings.contains(text, "no such ref") {
			// The remote is empty: nothing to receive yet.
		} else {
			r.offline = true
			path.mkdirs(path.dir(hold))
			path.write(hold, strings.concatenate({iso_after(SYNC_OFFLINE_HOLD), "\n"}))
			return
		}
	}
	after := strings.trim_space(run_git(cli, {"rev-parse", "HEAD"}).stdout)
	if before != "" && after != "" && before != after {
		r.received = count_commits(cli, strings.concatenate({before, "..", after}))
		sync(cli, quiet = true)
	}
	if mode == .Full {
		// Until the far side has been seen once, everything here is ahead.
		ahead := 0
		if strings.trim_space(run_git(cli, {"rev-parse", "--verify", "-q", strings.concatenate({name, "/", branch})}).stdout) != "" {
			ahead = count_commits(cli, strings.concatenate({name, "/", branch, "..HEAD"}))
		} else {
			ahead = count_commits(cli, "HEAD")
		}
		if ahead > 0 {
			push := run_git(cli, {"push", "-q", "-u", name, strings.concatenate({"HEAD:", branch})}, SYNC_SEND_TIMEOUT)
			if push.ok {
				r.sent = ahead
			} else {
				r.offline = true
				path.mkdirs(path.dir(hold))
				path.write(hold, strings.concatenate({iso_after(SYNC_OFFLINE_HOLD), "\n"}))
			}
		}
	}
	if !r.offline {
		os.remove(hold)
	}
	path.mkdirs(path.join(cli.state, "sync"))
	path.write(path.join(cli.state, "sync", "last"), strings.concatenate({now_iso(), " sent ", int_str(i64(r.sent)), " received ", int_str(i64(r.received)), "\n"}))
	return
}

// remote_name is where the vault meets other machines: `origin` when there
// is one, else the first remote the vault has (a vault versioned by hand may
// call it `github`), else nothing.
remote_name :: proc(cli: ^Cli) -> string {
	names := strings.fields(run_git(cli, {"remote"}).stdout)
	for n in names {
		if n == "origin" {
			return n
		}
	}
	return len(names) > 0 ? names[0] : ""
}

// sync_write_down commits everything that changed in the vault, through its
// own gates (lint, secrets). When a gate refuses, the first line it said is
// what the person sees.
sync_write_down :: proc(cli: ^Cli) -> (wrote: int, waiting: string) {
	run_git(cli, {"add", "-A"})
	staged := run_git(cli, {"diff", "--cached", "--name-only"})
	files := strings.fields(staged.stdout)
	if len(files) == 0 {
		return 0, ""
	}
	// The vault's own gates run here, not only as hooks: a vault versioned by
	// hand has none, and a bad line must still wait.
	for gate in ([2]string{"lint", "secrets"}) {
		mark := strings.builder_len(cli.out)
		emark := strings.builder_len(cli.err)
		code := gate == "lint" ? cmd_lint(cli, {"--staged"}) : cmd_secrets(cli, {"--staged"})
		said := strings.concatenate({strings.to_string(cli.out)[mark:], "\n", strings.to_string(cli.err)[emark:]})
		resize(&cli.out.buf, mark)
		resize(&cli.err.buf, emark)
		if code != 0 {
			run_git(cli, {"reset", "-q"})
			for l in strings.split_lines(said) {
				t := strings.trim_space(l)
				if t != "" && !strings.has_prefix(t, "brain lint:") && !strings.has_prefix(t, "brain secrets:") {
					return 0, t
				}
			}
			return 0, strings.concatenate({"the vault's ", gate, " check refused the change"})
		}
	}
	msg := strings.concatenate({"sync: ", int_str(i64(len(files))), len(files) == 1 ? " file" : " files", " from ", host_name()})
	r := run_git(cli, {"commit", "-q", "-m", msg})
	if !r.ok {
		run_git(cli, {"reset", "-q"})
		for l in strings.split_lines(strings.concatenate({r.stderr, "\n", r.stdout})) {
			if t := strings.trim_space(l); t != "" {
				return 0, t
			}
		}
		return 0, "the change could not be written down"
	}
	return len(files), ""
}

count_commits :: proc(cli: ^Cli, range: string) -> int {
	r := run_git(cli, {"rev-list", "--count", range})
	if !r.ok {
		return 0
	}
	n := 0
	for c in strings.trim_space(r.stdout) {
		if c >= '0' && c <= '9' {
			n = n * 10 + int(c - '0')
		}
	}
	return n
}

conflict_files :: proc(text: string) -> string {
	files := make([dynamic]string)
	for l in strings.split_lines(text) {
		if i := strings.index(l, "Merge conflict in "); i >= 0 {
			append(&files, strings.trim_space(l[i + len("Merge conflict in "):]))
		}
	}
	return len(files) > 0 ? strings.join(files[:], ", ") : "a file"
}

now_iso :: proc() -> string {
	return iso_after(0)
}

iso_after :: proc(d: time.Duration) -> string {
	t := time.time_add(time.now(), d)
	y, mo, da := time.date(t)
	h, mi, s := time.clock(t)
	return strings.clone(
		strings.concatenate(
			{pad4(y), "-", pad2(mo), "-", pad2(da), "T", pad2(h), ":", pad2(mi), ":", pad2(s), "Z"},
		),
	)
}

pad2 :: proc(n: $T) -> string {
	v := int(n)
	s := int_str(i64(v))
	return v < 10 ? strings.concatenate({"0", s}) : s
}

pad4 :: proc(n: int) -> string {
	return int_str(i64(n))
}

// sync_say puts a report into words, the outcome first.
sync_say :: proc(cli: ^Cli, r: Sync_Report) -> int {
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "sync", r.off ? "off" : "on")
		jw_field(&w, "connected", r.connected ? "true" : "false")
		jw_field(&w, "remote", r.remote)
		jw_field_int(&w, "wrote", i64(r.wrote))
		jw_field_int(&w, "sent", i64(r.sent))
		jw_field_int(&w, "received", i64(r.received))
		jw_field(&w, "waiting", r.waiting)
		jw_field(&w, "conflict", r.conflict)
		jw_field(&w, "offline", r.offline ? "true" : "false")
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return r.waiting != "" || r.conflict != "" ? 1 : 0
	}
	switch {
	case r.off:
		out(cli, "sync is off for this machine; brain sync on turns it on\n")
		return 0
	case r.no_git:
		out(cli, "sync needs git on this machine; the vault is kept here only\n")
		return 0
	case r.no_repo:
		out(cli, "the vault is not versioned yet; brain install sets that up\n")
		return 0
	}
	if r.wrote > 0 {
		outf(cli, "wrote down %d %s\n", r.wrote, r.wrote == 1 ? "change" : "changes")
	}
	if r.waiting != "" {
		outf(cli, "changes waiting: %s\n", r.waiting)
	}
	if !r.connected {
		out(cli, "not connected to another machine; brain sync connect <url>, or brain sync connect github\n")
		return r.waiting != "" ? 1 : 0
	}
	if r.conflict != "" {
		outf(cli, "both sides changed %s; this machine kept its own and nothing was lost. Open the file, keep what you want, then brain sync\n", r.conflict)
		return 1
	}
	if r.offline {
		out(cli, "offline; what changed here is safe and goes when the connection is back\n")
		return 0
	}
	switch {
	case r.sent > 0 && r.received > 0:
		outf(cli, "sent %d, received %d\n", r.sent, r.received)
	case r.sent > 0:
		outf(cli, "sent %d\n", r.sent)
	case r.received > 0:
		outf(cli, "received %d\n", r.received)
	case:
		out(cli, "up to date\n")
	}
	return r.waiting != "" ? 1 : 0
}

sync_status :: proc(cli: ^Cli) -> int {
	on := sync_enabled(cli)
	remote := ""
	if os.exists(path.join(cli.vault, ".git")) {
		if name := remote_name(cli); name != "" {
			remote = strings.trim_space(run_git(cli, {"remote", "get-url", name}).stdout)
		}
	}
	last := strings.trim_space(first_line(path.join(cli.state, "sync", "last")))
	changed := len(strings.fields(run_git(cli, {"status", "--porcelain"}).stdout))
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "sync", on ? "on" : "off")
		jw_field(&w, "remote", remote)
		jw_field(&w, "last", last)
		jw_field_int(&w, "changed", i64(changed))
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	outf(cli, "sync %s\n", on ? "on" : "off")
	if remote == "" {
		out(cli, "not connected to another machine\n")
	} else {
		outf(cli, "connected: %s\n", remote)
	}
	if last != "" {
		outf(cli, "last: %s\n", last)
	}
	if changed > 0 {
		outf(cli, "%d %s waiting to be written down\n", changed, changed == 1 ? "change" : "changes")
	}
	return 0
}

// sync_connect names where the machines meet: a URL, or a new private
// repository on GitHub made with gh.
sync_connect :: proc(cli: ^Cli, where_: string) -> int {
	if !os.exists(path.join(cli.vault, ".git")) {
		if r := run_git(cli, {"init", "-q"}); !r.ok {
			return fail(cli, "the vault could not be versioned")
		}
	}
	url := where_
	if where_ == "github" {
		if _, found := sh.which("gh"); !found {
			return fail(cli, "connect github needs the gh command signed in; or give a URL: brain sync connect <url>")
		}
		name := path.base(cli.vault)
		r := sh.exec({"gh", "repo", "create", name, "--private", "--source", cli.vault, "--remote", "origin"}, {dir = cli.vault, timeout = 30 * time.Second})
		if !r.ok {
			return fail(cli, strings.concatenate({"github did not create the repository: ", strings.trim_space(sh.error(r))}))
		}
		url = strings.trim_space(run_git(cli, {"remote", "get-url", "origin"}).stdout)
	} else {
		existing := strings.trim_space(run_git(cli, {"remote", "get-url", "origin"}).stdout)
		if existing != "" {
			run_git(cli, {"remote", "set-url", "origin", url})
		} else if r := run_git(cli, {"remote", "add", "origin", url}); !r.ok {
			return fail(cli, strings.concatenate({"could not connect: ", strings.trim_space(sh.error(r))}))
		}
	}
	// A vault that is still the starter adopts what is already there: the
	// second machine's first connect should end with the first machine's
	// vault, not a merge of two welcome pages.
	if count_commits(cli, "HEAD") <= 1 && vault_is_starter(cli) {
		branch := "main"
		if f := run_git(cli, {"fetch", "-q", "origin"}, SYNC_SEND_TIMEOUT); f.ok {
			if head := strings.trim_space(run_git(cli, {"symbolic-ref", "--short", "refs/remotes/origin/HEAD"}).stdout); head != "" {
				branch = strings.trim_prefix(head, "origin/")
			} else if strings.trim_space(run_git(cli, {"rev-parse", "--verify", "-q", "origin/master"}).stdout) != "" {
				branch = "master"
			}
			if strings.trim_space(run_git(cli, {"rev-parse", "--verify", "-q", strings.concatenate({"origin/", branch})}).stdout) != "" {
				// -f: the starter files on disk give way to the vault being adopted.
				run_git(cli, {"checkout", "-q", "-f", "-B", branch, strings.concatenate({"origin/", branch})})
				sync(cli, quiet = true)
			}
		}
	}
	rep := vault_sync(cli, .Full, force = true)
	if !cli.json {
		outf(cli, "connected: %s\n", url)
	}
	return sync_say(cli, rep)
}

// vault_is_starter says whether the vault still holds only what `brain
// install` wrote: the starter files, unchanged, and nothing else.
vault_is_starter :: proc(cli: ^Cli) -> bool {
	files, err := list_md(cli.vault)
	if err != nil {
		return false
	}
	for f in files {
		known := false
		for s in STARTER {
			if s.name == f {
				known = true
				text, _ := read_text(path.join(cli.vault, f))
				if text != s.body {
					return false
				}
			}
		}
		if !known {
			return false
		}
	}
	return true
}

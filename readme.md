# bin — the vault's own tooling

Markdown under `AI/` is canonical. Everything here is derived, disposable, or a
gate; delete `~/.local/state/brain/brain.db` at any time and `brain sync`
rebuilds it.

| file | what it is |
|------|------------|
| `brain` | query and lint the vault (`find`, `sync`, `doctor`, `log`, `lint`, `install`) |
| `hooks/pre-commit` | runs `brain lint --staged`; hard failures block the commit |
| `hooks/commit-msg` | delegates to the global hook, which a repo-local `core.hooksPath` would otherwise shadow |
| `shims/` | PATH shims that refuse commands the vault records as traps |
| `synonyms.tsv` | query expansion; the vocabulary travels with the repo |

## Install

    <path-to-clone>/bin/brain install      # afterwards: brain install

Binds this machine to this clone: records the vault path, links the CLI into the
first writable directory of ~/.local/bin, ~/bin, GOBIN, GOPATH/bin,
/usr/local/bin, points `core.hooksPath` at `bin/hooks`, puts the guard shims on
PATH, and aims `~/.agents/AGENTS.md` at this clone so pi, Codex and Claude Code
all follow. `--dry-run` shows every change without making one; `brain uninstall`
removes them again.

Everything written into a file you own sits inside a tagged block
(`brain:path`, `brain:guards`, `brain:claude`), and the file is backed up to
`<file>.brain-backup` the first time. Re-running install replaces the block; it
never touches a line outside it.

## Why this shape

A CLI is not a gate — it has to be invoked, and grep always still works. Only
the pre-commit hook fires unconditionally, so the enforcement lives there and
`brain` is merely where the check's code sits.

Search ranks handle matches above body matches, because the protocol failure
this tooling exists to fix was `grep -ril review` returning 26 of 33 files.

Every query is logged with its hit count. Zero-hit queries are the synonym
backlog: they name the vocabulary the vault is missing, discovered from real
misses instead of guessed in advance. `brain log` lists them; add rows to
`synonyms.tsv` and re-run `brain sync`.

Guards are PATH shims, not shell functions: `bash -c` never sources `~/.bashrc`,
so a function guards only interactive shells. `brain install` puts `bin/shims`
ahead of `/usr/share/omarchy/bin` in both `~/.bashrc` and
`~/.config/environment.d/10-brain-shims.conf`; the latter covers every shell and
every exec in the session, from the next login. Override one with
`BRAIN_GUARD_OVERRIDE=1`.

Every query also records which bullets answered it, by handle. A bullet that no
query has ever returned is a prune candidate with evidence behind it, which is
what `doctor` reports once enough queries are logged to mean anything.

## Secrets

`brain secrets` runs gitleaks against the staged change, and the pre-commit hook
refuses a commit that trips it. `.gitleaks.toml` is checked in: the stock rules
plus two tuned for prose (a connection URI with an inline password, a credential
assigned a literal), and an allowlist for the placeholders and credential *names*
this vault records deliberately. Record a deliberate exception with a
`gitleaks:allow` comment or an allowlist entry, never with `--no-verify`.

The binary is resolved by explicit path, because `~/go/bin` is not on a
non-interactive PATH and a gate that silently does not run is worse than none.
Without gitleaks it falls back to six unambiguous patterns and says so; there is
no 40-hex rule, since that is a git SHA and this vault is full of them.

`brain secrets --history` scans every commit — run it before pushing anywhere new.

## Portability

Linux, macOS, and Git Bash on Windows. The scripts avoid GNU-only constructs —
no `find -printf`, no `mapfile`, no `readlink -f`, no `paste -s`, no
`sqlite3 .import`. They need bash, POSIX text tools, and sqlite3 built with
FTS5; `brain install` checks for it and names the package if it is missing.

Guard coverage differs, because what a shell reads differs:

| platform | what is covered |
|----------|-----------------|
| Linux | every shell and exec in the session, via `~/.config/environment.d` (from the next login) |
| macOS | every zsh via `~/.zshenv`, and bash login shells via `~/.bash_profile` |
| Windows (Git Bash) | shells that read `~/.bashrc` |

Only Linux gives an unprivileged user a session-wide environment hook, so
elsewhere a bare `bash -c` is not guarded. `brain install` says which case
applies on the machine it runs on.

A line that does not parse is skipped, never rejected. The bullet format is
young and must not become load-bearing.

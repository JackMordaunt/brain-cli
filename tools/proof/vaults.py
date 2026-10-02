#!/usr/bin/env python3
"""Vault variants for the proof suite.

  vaults.py base <src> <dst>                  the reviewed vault: markdown and vocabulary, no AI/INBOX.md
  vaults.py conflict [--marked] <src> <dst>   plant a 2026-09-20 note contradicting five bullets
  vaults.py scale <N> [--seed S] <src> <dst>  append N synthetic bullets to the core files

The destination holds the source's markdown and synonyms (no history), as
run.sh copies it, plus the variant. The lookup runner takes it as VAULT=.
"""
import os, random, shutil, sys

def copy_clean(src, dst):
    """Copy a vault file, leaving out any bullet that names the proof itself:
    reviewed proposals from earlier runs describe the questions and answers."""
    if not src.endswith(".md"):
        shutil.copy2(src, dst); return
    with open(src, encoding="utf-8", errors="replace") as f, open(dst, "w", encoding="utf-8") as g:
        for line in f:
            if line.startswith("- **") and "proof" in line.lower():
                continue
            g.write(line)

def copy(src, dst):
    if os.path.exists(dst):
        shutil.rmtree(dst)
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d != ".git"]
        rel = os.path.relpath(root, src)
        for f in files:
            # The inbox holds unreviewed proposals, some made by the proof's
            # own sessions and write-ups; the experiments see the reviewed vault.
            if ((f.endswith(".md") and f != "INBOX.md") or f == "synonyms.tsv") and "proof" not in f:
                out = os.path.join(dst, rel, f)
                os.makedirs(os.path.dirname(out), exist_ok=True)
                copy_clean(os.path.join(root, f), out)

CONFLICT_HEAD = "# Early decisions, 2026-09-20\n\nWhat we settled in the first week; kept as the record of where things started.\n\n"
CONFLICT_MARK = "> Superseded 2026-09-30. The bullets in AI/MEMORY.md and AI/LEARNINGS.md are current; several lines below were later found wrong. Kept as history.\n\n"
CONFLICT_BODY = """## Install

The brainfold install line for Linux and macOS is `curl -fsSL https://mordaunt.dev/code/brain-cli/install.sh | sh`;
the Windows line is `irm https://mordaunt.dev/code/brain-cli/install.ps1 | iex`. The repository is
`brain-cli` and the vanity path follows the repository name, so brainfold installs from `/code/brain-cli/`.

## Notification watcher

`busctl --user monitor` shows nothing when piped into a `while read` loop because the pipe is a
pseudo-terminal problem: run it under `script -q -c 'busctl --user monitor --json=short' /dev/null`
so busctl believes it has a terminal and flushes each line.

## Windows CI

In a bash step on a Windows runner, `cl /nologo /O2` compiles nothing because Git Bash's cl shim
cannot find the MSVC environment. The fix is to switch the step to `shell: cmd` and call
`vcvars64.bat` first; there is no environment variable that changes this.

## Hyprland rules

Hyprland matches a window rule's `class` regex as a prefix, so `^chrome-web\\.whatsapp\\.com` is
enough to catch the WhatsApp web app whatever suffix Chromium appends; the earlier failure was a
typo in the workspace name.

## mpv preview

mpv hangs before opening the URL because the CDN rejects the range request mpv sends first; pass
`--demuxer-seekable-cache=no` and the preview plays. The audio client name is unrelated.
"""

def conflict(src, dst, marked):
    copy(src, dst)
    note = os.path.join(dst, "brainfold", "2026-09-20-early-decisions.md")
    os.makedirs(os.path.dirname(note), exist_ok=True)
    with open(note, "w") as f:
        f.write(CONFLICT_HEAD + (CONFLICT_MARK if marked else "") + CONFLICT_BODY)
    print(f"planted {note}{' (marked superseded)' if marked else ''}")

TOOLS = ["nginx", "caddy", "postgres", "redis", "sqlite", "zig", "rustc", "cargo", "go", "waybar", "systemd",
         "docker", "podman", "k3s", "terraform", "ansible", "ripgrep", "jq", "ffmpeg", "openssl", "curl", "cmake",
         "ninja", "llvm", "gcc", "clang", "wasmtime", "sdl3", "vulkan", "pipewire", "wireplumber", "bluez",
         "networkmanager", "tailscale", "wireguard", "rsync", "borg", "restic", "tmux", "neovim", "alacritty",
         "kitty", "ghostty", "zsh", "fish", "nushell", "yazi", "lazygit", "delta", "bat", "fd", "zoxide", "direnv",
         "mise", "nix", "flatpak", "pacman", "yay", "grub", "mkinitcpio", "btrfs", "zfs", "cryptsetup", "udev",
         "pam", "polkit", "xdg-desktop-portal", "greetd", "swaylock", "mako", "fuzzel", "wofi", "grim", "slurp",
         "wl-clipboard", "cliphist", "gammastep", "brightnessctl", "playerctl", "pamixer", "wpctl", "kanshi",
         "wlr-randr", "nwg-displays", "sway", "river", "niri", "labwc", "cosmic", "gnome-keyring", "seahorse",
         "gpg", "age", "sops", "pass", "bitwarden", "keepassxc", "syncthing", "nextcloud", "rclone", "sshfs",
         "nfs", "samba", "avahi", "cups", "sane", "libinput", "evtest", "xremap", "keyd", "kmonad", "qmk", "via"]
REAL = ["hyprland", "libgit2", "fzf", "busctl", "mpv", "just", "cl", "brainfold", "jm", "odin", "mordaunt.dev",
        "git bash", "whatsapp", "window rule", "submodule", "revwalk", "install.sh"]
SUBS = ["daemon", "config", "cli", "service", "timer", "socket", "cache", "index", "parser", "backend", "plugin",
        "hook", "exporter", "importer", "scheduler", "watcher", "runner", "shim", "wrapper", "bridge"]
TOPICS = ["timeout", "buffering", "exit code", "env var", "path quoting", "default port", "config key", "regex",
          "sort order", "cache dir", "lock file", "permissions", "encoding", "locale", "version pin", "retry",
          "signal", "log level", "unit file", "socket path", "tls", "proxy", "dns", "ipv6", "cgroup", "umask"]
TEMPLATES = [
    "`{tool} {sub}` {verb} {thing} unless `{flag}` is set; seen on {date} while {ctx}",
    "{tool} {ver} changed its {topic}: {thing}, so {fix}",
    "on this machine {tool} reads {path} before {path2}; the {topic} there wins, which is why {sym}",
    "{tool}'s {sub} exits {code} when {thing}; the fix is {fix}, not {wrong}",
    "never run `{tool} {sub}` with `{flag}` in a pipe: it {verb} {thing}; use `{flag2}` and {fix}",
    "{tool} {topic} is `{val}` by default and `{val2}` under {ctx}; {fix}",
]
VERBS = ["block-buffers", "drops", "rewrites", "ignores", "truncates", "swallows", "re-reads", "double-encodes"]
THINGS = ["its last line", "the trailing newline", "relative paths", "the first argument", "SIGPIPE", "unicode handles",
          "the lock file", "stdin at EOF", "the exit status", "the config's include lines", "symlinked units", "the cache stamp"]
FIXES = ["pass the full path", "set it in the unit's Environment=", "quote the glob", "restart the user session",
         "export it before the shebang runs", "pin the previous minor", "drop the trailing slash", "run it under stdbuf"]
WRONGS = ["reinstalling", "clearing the cache", "a reboot", "chmod 777", "the sudo path", "the snap build"]
CTXS = ["a cold cache", "systemd --user", "a Wayland session", "CI", "a container", "an NFS home", "a btrfs subvolume", "ASan"]
SYMS = ["the service looks alive but writes nothing", "the first run after boot is slow", "the prompt loses colour",
        "the hook never fires", "the timer skips a day", "the socket is created twice"]

def bullet(rng, i, real):
    tool = rng.choice(REAL) if real else rng.choice(TOOLS)
    sub, topic = rng.choice(SUBS), rng.choice(TOPICS)
    flag = "--" + rng.choice(["no-buffer", "strict", "quiet", "follow", "json", "once", "unsafe-perm", "frozen"])
    flag2 = "--" + rng.choice(["line-buffered", "wait", "verbose", "plain", "ignore-env", "no-cache"])
    d = f"2026-{rng.randint(5, 9):02d}-{rng.randint(1, 28):02d}"
    t = rng.choice(TEMPLATES).format(
        tool=tool, sub=sub, topic=topic, flag=flag, flag2=flag2, verb=rng.choice(VERBS), thing=rng.choice(THINGS),
        fix=rng.choice(FIXES), wrong=rng.choice(WRONGS), ctx=rng.choice(CTXS), sym=rng.choice(SYMS), date=d,
        ver=f"{rng.randint(0, 12)}.{rng.randint(0, 40)}", code=rng.choice([1, 2, 3, 64, 70, 75, 126, 127, 130]),
        path=f"~/.config/{tool}/{rng.choice(['config', 'settings', 'rc'])}.toml",
        path2=f"/etc/{tool}/{rng.choice(['config', 'main', 'default'])}.conf",
        val=rng.choice(["30s", "4096", "auto", "warn", "strict", "off"]), val2=rng.choice(["5s", "65536", "manual", "debug", "lax", "on"]))
    handle = f"{tool} {topic} {i}"
    aliases = f"{tool} {sub}, {topic.replace(' ', '-')}"
    return f"- **{handle}** (aliases: {aliases}) — {t} — synthetic — {d}\n"

def scale(src, dst, n, seed):
    copy(src, dst)
    rng = random.Random(seed)
    files = [os.path.join(dst, "AI", "MEMORY.md"), os.path.join(dst, "AI", "LEARNINGS.md")]
    outs = [open(f, "a") for f in files]
    for f in outs:
        f.write("\n")
    real = 0
    for i in range(n):
        is_real = rng.random() < 0.05
        real += is_real
        outs[i % 2].write(bullet(rng, i, is_real))
    for f in outs:
        f.close()
    print(f"appended {n} synthetic bullets ({real} reuse real key words) to {dst}")

def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd, rest = argv[0], argv[1:]
    if cmd == "base":
        copy(rest[0], rest[1]); print(f"copied {rest[0]} -> {rest[1]} without AI/INBOX.md")
    elif cmd == "conflict":
        marked = "--marked" in rest
        rest = [a for a in rest if a != "--marked"]
        conflict(rest[0], rest[1], marked)
    elif cmd == "scale":
        n = int(rest[0]); rest = rest[1:]
        seed = 7
        if rest and rest[0] == "--seed":
            seed = int(rest[1]); rest = rest[2:]
        scale(rest[0], rest[1], n, seed)
    else:
        sys.exit(__doc__)

if __name__ == "__main__":
    main(sys.argv[1:])

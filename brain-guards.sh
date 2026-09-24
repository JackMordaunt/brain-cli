# Brain guards — sourced from ~/.bashrc by `brain install`.
#
# A lesson in LEARNINGS.md only helps someone who greps it first. These are the
# ones that cost real work when forgotten, so they refuse instead of reminding.
# Shell functions are used rather than PATH shims because ~/.local/bin loses to
# /usr/share/omarchy/bin in this PATH.

omarchy-refresh-shell() {
  if [ "${BRAIN_GUARD_OVERRIDE:-}" = "1" ]; then
    command omarchy-refresh-shell "$@"
    return
  fi
  cat >&2 <<'MSG'
refused: omarchy-refresh-shell resets your shell settings and you restore them by hand.

  use instead:  omarchy-restart-shell
  really meant it:  BRAIN_GUARD_OVERRIDE=1 omarchy-refresh-shell

(AI/LEARNINGS.md, "omarchy shell reload", 2026-09-23)
MSG
  return 1
}

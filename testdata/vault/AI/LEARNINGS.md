# Learnings

## Shell

- **awk empty first file** (aliases: NR==FNR, FILENAME, awk two-file) — `NR == FNR` is true for every record of the second file when the first is empty; test `FILENAME` instead — fixture — 2026-01-01

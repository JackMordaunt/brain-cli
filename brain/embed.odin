package brain

import "core:os"
import "core:strings"

import "jm:path"

// The data files the tool ships are compiled in, so a release binary needs
// no checkout beside it. The files under bin/ and the gitleaks ruleset stay
// the source of truth; a rebuild picks up an edit.

SYNONYMS_TSV :: #load("../bin/synonyms.tsv", string)
GITLEAKS_TOML :: #load("../.gitleaks.toml", string)

// Embedded is one file install writes out: hooks and shims are executables
// git and the shell run, so they have to exist on disk.
Embedded :: struct {
	name, body: string,
}

HOOKS :: [3]Embedded {
	{"pre-commit", #load("../bin/hooks/pre-commit", string)},
	{"commit-msg", #load("../bin/hooks/commit-msg", string)},
	{"post-commit", #load("../bin/hooks/post-commit", string)},
}

SHIMS :: [1]Embedded{{"omarchy-refresh-shell", #load("../bin/shims/omarchy-refresh-shell", string)}}

// write_executables writes files into dir with the execute bit, replacing
// the marker `installed=""` in each with the binary's own path so a hook
// runs it whatever PATH a non-interactive git has.
write_executables :: proc(dir: string, files: []Embedded, exe: string) -> os.Error {
	path.mkdirs(dir) or_return
	for f in files {
		body, _ := strings.replace_all(f.body, "installed=\"\"", strings.concatenate({"installed=\"", exe, "\""}))
		p := path.join(dir, f.name)
		path.write(p, body) or_return
		when ODIN_OS != .Windows {
			os.change_mode(p, os.Permissions_All - os.Permissions_Write_All + {.Write_User})
		}
	}
	return nil
}

package brain

import "core:os"
import "core:strings"

import "jm:path"

// The pi harness (github.com/earendil-works/pi; pi 0.87.1's
// docs/extensions.md and dist/core/extensions/types.d.ts in the installed
// package define what follows). pi runs TypeScript extensions from
// ~/.pi/agent/extensions and offers the same three moments as events:
// session_start; before_agent_start, whose BeforeAgentStartEventResult
// may carry a custom message the model sees; and agent_before_settle,
// whose BoundaryResult may append a custom_message entry and set
// continue for one more turn. Brain
// registers by writing one extension file with the binary's own path
// inside it; the extension runs pack, prime and settle through pi.exec
// with plain flags, so pi hands nothing over on stdin and pi_parse reads
// nothing. The file is recognised by its first line, so install twice
// writes it once and uninstall removes only it.

PI_EXTENSION_FILE :: "brain.ts"
PI_MARK :: "// brainfold hooks: written by `brain hooks on`; `brain hooks off` removes it"

// pi_detect: the harness is here when its agent directory is.
pi_detect :: proc(cli: ^Cli) -> bool {
	return os.is_dir(pi_agent_dir(cli))
}

// pi_agent_dir is pi's configuration directory; its sessions, which
// pi_root in brain/adapters.odin reads, sit under it.
pi_agent_dir :: proc(cli: ^Cli) -> string {
	return path.join(getenv(cli, "PI_HOME", path.join(cli.home, ".pi")), "agent")
}

pi_extension :: proc(cli: ^Cli) -> string {
	return path.join(pi_agent_dir(cli), "extensions", PI_EXTENSION_FILE)
}

// pi never hands input over on stdin; the extension passes flags.
pi_parse :: proc(text: string) -> (ev: Hook_Event, ok: bool) {
	return
}

// pi_reply is what the extension reads back from settle: the reason to
// continue with, as one JSON object.
pi_reply :: proc(reason: string) -> string {
	w := jw_make()
	jw_obj(&w)
	jw_field(&w, "reason", reason)
	jw_end_obj(&w)
	return strings.concatenate({strings.to_string(w.b), "\n"})
}

pi_register :: proc(cli: ^Cli, exe: string) {
	file := pi_extension(cli)
	body, _ := strings.replace_all(PI_EXTENSION, "__BRAIN__", exe)
	body = strings.concatenate({PI_MARK, "\n", body})
	if text, ok := read_text(file); ok && text == body {
		say(cli, "%s: brain extension present", file)
		return
	}
	if cli.dry {
		say(cli, "%s: brain extension would be written", file)
		return
	}
	path.mkdirs(path.dir(file))
	if err := path.write(file, body); err != nil {
		note(cli, "cannot write %s: %v", file, err)
		return
	}
	say(cli, "%s: brain extension written (pack, prime, settle)", file)
}

pi_unregister :: proc(cli: ^Cli) {
	file := pi_extension(cli)
	text, ok := read_text(file)
	if !ok || !strings.has_prefix(text, PI_MARK) {
		return
	}
	say(cli, "%s: brain extension removed", file)
	if !cli.dry {
		os.remove(file)
	}
}

pi_status :: proc(cli: ^Cli) -> []Hook_Registration {
	text, ok := read_text(pi_extension(cli))
	on := ok && strings.has_prefix(text, PI_MARK)
	out := make([dynamic]Hook_Registration)
	append(&out, Hook_Registration{event = "session_start", sub = "pack", on = on})
	append(&out, Hook_Registration{event = "before_agent_start", sub = "prime", on = on})
	append(&out, Hook_Registration{event = "agent_before_settle", sub = "settle", on = on})
	return out[:]
}

// PI_EXTENSION is the extension body; __BRAIN__ becomes the binary's
// path. Each command's output goes to the model as a custom message with
// display false, which pi's CustomMessageEntry keeps in the session and in
// model context and hides from the transcript view (session-manager.d.ts).
// The extension prints nothing on a failure or a miss, like the Claude
// hooks, whose commands end in `|| true`.
PI_EXTENSION :: `import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const BRAIN = "__BRAIN__";
const TIMEOUT_MS = 10_000;

async function brain(pi: ExtensionAPI, ctx: ExtensionContext, args: string[]): Promise<string> {
	try {
		const r = await pi.exec(BRAIN, args, { cwd: ctx.cwd, timeout: TIMEOUT_MS });
		return r.code === 0 ? r.stdout : "";
	} catch {
		return "";
	}
}

export default function (pi: ExtensionAPI) {
	let settled = false;

	// What the vault knows about this repository, once per session.
	pi.on("session_start", async (_event, ctx) => {
		settled = false;
		const pack = await brain(pi, ctx, ["pack"]);
		if (pack.trim()) {
			pi.sendMessage({ customType: "brain", content: pack, display: false });
		}
	});

	// What the vault knows about this prompt, each bullet once a session.
	pi.on("before_agent_start", async (event, ctx) => {
		const session = ctx.sessionManager.getSessionId();
		const primed = await brain(pi, ctx, ["prime", "--harness", "pi", "--session", session, "--", event.prompt]);
		if (!primed.trim()) return;
		return { message: { customType: "brain", content: primed, display: false } };
	});

	// When the agent would stop: once a session that changed files and
	// proposed nothing, ask what it settled, then let it stop.
	pi.on("agent_before_settle", async (event, ctx) => {
		if (event.continue || settled) return;
		const file = ctx.sessionManager.getSessionFile();
		if (!file) return;
		const session = ctx.sessionManager.getSessionId();
		const out = await brain(pi, ctx, ["settle", "--harness", "pi", "--session", session, "--transcript", file]);
		if (!out.trim()) return;
		let reason = "";
		try {
			reason = String(JSON.parse(out).reason ?? "");
		} catch {
			return;
		}
		if (!reason) return;
		settled = true;
		return {
			entries: [{ type: "custom_message", customType: "brain", content: reason, display: true }],
			continue: true,
		};
	});
}
`

package brain

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// brain mcp serves the vault over the Model Context Protocol on stdio, for
// agents that have no shell: one JSON-RPC message per line in, one out
// (modelcontextprotocol.io, the stdio transport). Each tool call runs the
// command the CLI would, in a Cli of its own, and returns what it printed
// as text, so the tools cannot drift from the commands. The caller is
// logged as mcp:<client>, from the client's own name.

MCP_PROTOCOL :: "2025-06-18"

MCP_TOOLS :: `{"tools":[
{"name":"find","description":"Search the vault's bullets: what was concluded and is still true. Handle matches rank first; a term of three or more characters also matches the start of a handle.","inputSchema":{"type":"object","properties":{"terms":{"type":"string","description":"search terms"},"budget":{"type":"integer","description":"most tokens to return (default 1000)"}},"required":["terms"]}},
{"name":"recall","description":"Search what past agent conversations said, as ranked snippets. Evidence of what was said, not of what is true; a bullet from find outranks it.","inputSchema":{"type":"object","properties":{"terms":{"type":"string","description":"search terms"},"limit":{"type":"integer","description":"most snippets to return (default 10)"}},"required":["terms"]}},
{"name":"pack","description":"The briefing to open a project with: the vault's bullets about it, terse, within a token budget, then its newest handoff and state folder.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"project or repository name (default: the repository the server runs in)"},"budget":{"type":"integer","description":"most tokens to return (default 1500)"}}}},
{"name":"propose","description":"Queue a bullet for the vault's inbox; a person approves it before it enters memory. Shape: - **handle** (aliases: what a searcher might type) — fact — source — YYYY-MM-DD. Source and date are filled in when left off.","inputSchema":{"type":"object","properties":{"bullet":{"type":"string","description":"the bullet line"}},"required":["bullet"]}},
{"name":"locate","description":"The vault's absolute path.","inputSchema":{"type":"object","properties":{}}}
]}`

cmd_mcp :: proc(cli: ^Cli, args: []string) -> int {
	client := "mcp"
	session := fmt.aprintf("mcp-%d", time.now()._nsec)
	buf: [65536]byte
	pending := strings.builder_make()
	for {
		n, err := os.read(os.stdin, buf[:])
		if n > 0 {
			strings.write_bytes(&pending, buf[:n])
		}
		for {
			s := strings.to_string(pending)
			i := strings.index_byte(s, '\n')
			if i < 0 {
				break
			}
			line := strings.clone(s[:i])
			rest := strings.clone(s[i + 1:])
			strings.builder_reset(&pending)
			strings.write_string(&pending, rest)
			if strings.trim_space(line) == "" {
				continue
			}
			if reply := mcp_handle(cli, line, &client, session); reply != "" {
				os.write_string(os.stdout, reply)
				os.write_string(os.stdout, "\n")
			}
		}
		if err != nil || n == 0 {
			break
		}
	}
	return 0
}

// mcp_handle answers one message. A notification, or a message with no
// answer, returns "".
mcp_handle :: proc(cli: ^Cli, line: string, client: ^string, session: string) -> string {
	v, perr := json.parse_string(line)
	if perr != nil {
		return rpc_error(nil, -32700, "parse error")
	}
	obj, is_obj := v.(json.Object)
	if !is_obj {
		return rpc_error(nil, -32600, "invalid request")
	}
	id, has_id := obj["id"]
	method := json_string(v, "method")
	params := obj["params"]
	switch method {
	case "initialize":
		if c := json_string(params, "clientInfo", "name"); c != "" {
			client^ = c
		}
		proto := json_string(params, "protocolVersion")
		if proto == "" {
			proto = MCP_PROTOCOL
		}
		return rpc_result(
			id,
			strings.concatenate(
				{
					`{"protocolVersion":`,
					json_quote(proto),
					`,"capabilities":{"tools":{}},"serverInfo":{"name":"brain","version":`,
					json_quote(VERSION != "" ? VERSION : "dev"),
					`}}`,
				},
			),
		)
	case "ping":
		return rpc_result(id, "{}")
	case "tools/list":
		return rpc_result(id, MCP_TOOLS)
	case "tools/call":
		argv, ok := mcp_argv(json_string(params, "name"), params)
		if !ok {
			return rpc_error(id, -32602, strings.concatenate({"unknown tool: ", json_string(params, "name")}))
		}
		sub := new_cli(mcp_env(cli, strings.concatenate({"mcp:", client^}), session))
		code := run(sub, argv)
		text := strings.to_string(sub.out)
		if e := strings.to_string(sub.err); e != "" {
			text = strings.concatenate({text, e})
		}
		return rpc_result(
			id,
			strings.concatenate({`{"content":[{"type":"text","text":`, json_quote(text), `}],"isError":`, code != 0 ? "true" : "false", `}`}),
		)
	case:
		if !has_id || strings.has_prefix(method, "notifications/") {
			return ""
		}
		return rpc_error(id, -32601, strings.concatenate({"method not found: ", method}))
	}
}

// mcp_argv turns a tool call into the CLI arguments it stands for.
mcp_argv :: proc(name: string, params: json.Value) -> (argv: []string, ok: bool) {
	a := make([dynamic]string)
	args: json.Value
	if p, is_obj := params.(json.Object); is_obj {
		args = p["arguments"]
	}
	switch name {
	case "find", "recall":
		append(&a, name)
		for t in strings.fields(json_string(args, "terms")) {
			append(&a, t)
		}
		flag := name == "find" ? "--budget" : "--limit"
		if n, has := json_int(args, name == "find" ? "budget" : "limit"); has {
			append(&a, flag, int_str(i64(n)))
		}
	case "pack":
		append(&a, "pack")
		if p := json_string(args, "project"); p != "" {
			append(&a, p)
		}
		if n, has := json_int(args, "budget"); has {
			append(&a, "--budget", int_str(i64(n)))
		}
	case "propose":
		append(&a, "propose", json_string(args, "bullet"))
	case "locate":
		append(&a, "locate")
	case:
		return nil, false
	}
	return a[:], true
}

// mcp_env is the server's environment plus who is calling, for the log.
mcp_env :: proc(cli: ^Cli, caller, session: string) -> map[string]string {
	env := make(map[string]string)
	for k, v in cli.env {
		env[k] = v
	}
	env["BRAIN_CALLER"] = caller
	env["BRAIN_SESSION"] = session
	return env
}

json_int :: proc(v: json.Value, key: string) -> (int, bool) {
	obj, ok := v.(json.Object)
	if !ok {
		return 0, false
	}
	#partial switch n in obj[key] {
	case json.Integer:
		return int(n), true
	case json.Float:
		return int(n), true
	}
	return 0, false
}

rpc_result :: proc(id: json.Value, result: string) -> string {
	return strings.concatenate({`{"jsonrpc":"2.0","id":`, json_id(id), `,"result":`, result, `}`})
}

rpc_error :: proc(id: json.Value, code: int, message: string) -> string {
	return strings.concatenate({`{"jsonrpc":"2.0","id":`, json_id(id), `,"error":{"code":`, int_str(i64(code)), `,"message":`, json_quote(message), `}}`})
}

// json_id renders a request id as it came: a number, a string, or null.
json_id :: proc(id: json.Value) -> string {
	#partial switch v in id {
	case json.Integer:
		return int_str(i64(v))
	case json.Float:
		return int_str(i64(v))
	case json.String:
		return json_quote(string(v))
	}
	return "null"
}

// json_quote renders s as a JSON string literal, quotes included.
json_quote :: proc(s: string) -> string {
	return strings.concatenate({"\"", json_escape(s), "\""})
}

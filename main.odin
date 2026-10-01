/*
brain queries and lints a Brain vault: markdown that agents and people keep as
shared memory. The markdown is canonical; the SQLite index is disposable.

	brain locate            print the vault's path
	brain find <terms...>   search bullets, handle matches first
	brain recall <terms...> search what past agent conversations said
	brain sync | doctor | log | lint | secrets | install | uninstall

`brain help` prints the full usage.
*/
package main

import "core:os"
import "core:strings"
import "core:terminal"

import "jm:prelude"

import "brain"

main :: proc() {
	context = prelude.init({name = "brain"})
	cli := brain.new_cli(tty = terminal.is_terminal(os.stdout))
	// A hook hands its JSON over on stdin; a person typing the prompt as
	// arguments, or at a terminal, hands over nothing to wait for.
	if len(os.args) > 1 && brain.wants_stdin(os.args[1:]) && !terminal.is_terminal(os.stdin) {
		cli.stdin = brain.read_stdin(cli)
		cli.has_stdin = true
	}
	code := brain.run(cli, os.args[1:])
	os.write_string(os.stdout, strings.to_string(cli.out))
	os.write_string(os.stderr, strings.to_string(cli.err))
	// The update hint follows the command's output, so a slow check never
	// holds the answer back.
	if len(os.args) < 2 || os.args[1] != "update" {
		strings.builder_reset(&cli.err)
		brain.notify_update(cli)
		os.write_string(os.stderr, strings.to_string(cli.err))
	}
	if code != 0 {
		prelude.exit(code)
	}
}

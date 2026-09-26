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

import "jm:prelude"

import "brain"

main :: proc() {
	context = prelude.init({name = "brain"})
	cli := brain.new_cli()
	code := brain.run(cli, os.args[1:])
	os.write_string(os.stdout, strings.to_string(cli.out))
	os.write_string(os.stderr, strings.to_string(cli.err))
	if code != 0 {
		prelude.exit(code)
	}
}

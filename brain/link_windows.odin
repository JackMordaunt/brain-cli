#+build windows
package brain

import "core:os"

import win32 "core:sys/windows"

// core:os leaves symlink unsupported on Windows, so this is the Win32 call
// with the flag that lets Developer Mode create a link without elevation.
// Without Developer Mode the call fails and the caller copies instead.
symlink :: proc(target, link: string) -> bool {
	flags := win32.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
	if os.is_dir(target) {
		flags |= win32.SYMBOLIC_LINK_FLAG_DIRECTORY
	}
	l := win32.utf8_to_wstring(link, context.temp_allocator)
	t := win32.utf8_to_wstring(target, context.temp_allocator)
	return bool(win32.CreateSymbolicLinkW(l, t, flags))
}

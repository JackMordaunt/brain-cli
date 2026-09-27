#+build !windows
package brain

import "core:os"

symlink :: proc(target, link: string) -> bool {
	return os.symlink(target, link) == nil
}

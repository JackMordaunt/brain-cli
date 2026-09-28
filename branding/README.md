# branding

The mark, the hero lockup and the platform badges, each in a light and a
dark version. `just branding` regenerates the mark and hero from
`tools/logo`; the badges are static.

| file | what it is |
|------|------------|
| `mark-{light,dark}.{svg,png}` | the fissure mark alone, transparent, 1024 px PNG |
| `hero-{light,dark}.{svg,png}` | mark and wordmark, for the README |
| `badge-{linux,macos,windows}-{light,dark}.svg` | platform badges beside the install commands |

Ink is `#1c1b1a` on light, `#f0eee8` on dark. The wordmark and badge
labels are JetBrains Mono Bold, named rather than embedded, so a renderer
without it falls back to its own monospace.

The Tux and Apple glyphs in the badges are from
[Simple Icons](https://simpleicons.org) (CC0). The Windows badge uses a
generic four-pane glyph, not the Windows logo.

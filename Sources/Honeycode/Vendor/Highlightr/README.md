# Vendored: Highlightr

Source: https://github.com/raspu/Highlightr (MIT) — wraps highlight.js (BSD-3),
192 languages. Vendored rather than added as a package because Bench builds with
`swiftc` directly and has no dependency manager; this is four files and two
assets, which is cheaper than introducing SwiftPM to the build for one library.

Three deliberate changes from upstream:

- `Theme` is renamed `HighlightTheme` throughout, and `Theme.swift` renamed to
  match. Bench has its own `Theme`, and vendored code shares the module — and
  `swiftc` rejects two files with the same name in one invocation regardless.
- The default theme in `init` is `xcode`, not upstream's `pojoaque`. The
  initialiser returns `nil` if its default theme's CSS is missing, and only two
  of the 271 themes are bundled — so upstream's default made `Highlightr()` fail
  outright.
- `CodeAttributedString.swift` is not vendored. It's an `NSTextStorage` subclass
  for live-editing highlight; nothing here edits code.

Resource lookup needs no change: upstream falls back to
`Bundle(for: Highlightr.self)`, which for a class compiled into the app *is* the
main bundle, so `highlight.min.js` and the theme CSS resolve from
`Contents/Resources`.

# Genesis

A native macOS terminal with a glass window treatment, inset detail surface,
collapsible sidebar, custom rows, and a search capsule.
Every sidebar row is a **terminal tab** backed by its own real PTY running
the account login shell. Window controls use the native macOS titlebar; tab/sidebar commands are also
available in the menu bar.

A read-only **Code Review** panel can open on the right of the detail surface.
It follows the selected terminal’s local working directory, shows staged and
unstaged Git changes, and never stages, discards, commits, or pushes.

## Status: real PTY via SwiftTerm (integration branch)

- Each tab owns a `LocalProcess` PTY + `GenesisTerminalView` (SwiftTerm core:
  grid, SGR/cursor parsing, alt-screen TUIs, Unicode/IME, selection).
- SwiftTerm is pinned via SwiftPM (`12ea7f5`); HighlighterSwift is pinned at
  `fe7aae9c` for review syntax highlighting. See `Package.resolved`.
- Only `Terminal` tabs fork shells. The `Settings` tab never creates a PTY.
- Sidebar keeps its soft scroll-edge; the terminal surface scrolls with its
  own native scroller (no wrapper scroll view).

## Run

Open `GenesisTerminal.xcodeproj` in Xcode 26.5+ and run the `GenesisTerminal` scheme; the built application is named `Genesis`.
Xcode resolves SwiftTerm on first build (network required once).

- Baseline window 960×650, min 760×540.
- Shell metrics: sidebar 172 (150–300, ≥320 detail), review 420 (256–720),
  detail inset 10 / radius 20, search 30h/15r, rows 28h, spacing 1.
- Tests: `xcodebuild test` — unit + live-PTTY tests (spawn real shells).

## Tabs & chrome

- ⌘T new tab (inherits cwd), ⌘W close tab / ⇧⌘W close window, ⇧⌘T reopen,
  ⌃⇧Tab / ⌃Tab cycle, ⌘K clear, ⌘S toggle sidebar, ⌘R toggle Code Review.
  Last tab closes its window.
- Title comes from the shell (OSC title), cwd from OSC 7; file drops insert
  shell-quoted paths; only http(s)/mailto/file links open.
- Code Review uses that same local cwd. It does not infer directories from
  prompt text or follow remote/tmux panes. Files start collapsed. Opening
  the panel outside a Git repository explains that state.
- Quitting or closing with live jobs asks for confirmation; PIDs are reaped,
  never persisted. State restoration keeps lightweight descriptors only,
  including per-window review visibility and width.

## Files

- `GenesisTerminalApp.swift`: multi-window ownership, menus, Settings screen,
  quit/close confirmation, restoration.
- `WindowSupport.swift`: `TerminalWindowController`, restoration,
  `ShellMetrics`, glass backdrop, toolbar header.
- `TerminalModel.swift` + `TerminalSession.swift`: tabs, PTY lifecycle,
  search, history, recently-closed, descriptors.
- `TerminalView.swift`: SwiftTerm surface hosted directly with content insets.
- `ShellView.swift`, `SidebarView.swift`, `SearchField.swift`, `ChromeView.swift`: chrome.
- `ShellLayout.swift` + `Review/`: Code Review panel, Git discovery, diffs, and highlighting.
- `THIRD_PARTY_NOTICES.md`: bundled Highlighter/Highlight.js notices.

## TUI transparency (glass background)

Genesis renders default-background cells transparently so the glass shows
through (`backgroundOpacity = 0`, `window.isOpaque = false`; SwiftTerm skips
filling default-bg runs). Any TUI inherits it when it paints the
terminal-default background (`none`) instead of an explicit opaque fill —
the same pattern as the OpenCode `system` theme (text/background `none`).
Explicit hex/black fills stay opaque by design; panels, selections, and
diffs often keep subtle fills for readability.

Genesis side (automatic, locked by tests): `TERM=xterm-256color`,
`COLORTERM=truecolor`, `TERM_PROGRAM=Genesis`, plus OSC 10/11 answers from
the native colors so auto-themes detect light/dark. Check with
`echo $COLORTERM` (expect `truecolor`).

Recipes (restart the TUI after changing):

- OpenCode: `/theme` → `system`, or `"theme": "system"` in
  `~/.config/opencode/tui.json`. See [OpenCode themes](https://opencode.ai/docs/themes/).
- KiloCode (same TUI engine, fork of OpenCode): its default is the opaque
  `kilo` theme, so open the `/themes` picker and select `system` (or
  `transparent` if listed). In config files the key belongs in
  `~/.config/kilo/tui.jsonc` (or `tui.json`) as `"theme": "system"` —
  `theme`/`tui` keys inside `kilo.json` are deprecated and ignored — then
  restart. Note `system` keeps subtle panel fills by design, so only the
  main surface turns to glass.
- Claude Code: `/theme` → `auto` with `dark-ansi` / `light-ansi` (these defer
  to the terminal's 16-color palette). Custom themes live in
  `~/.claude/themes/`; `userMessageBackground` paints a fill in fullscreen
  mode, so leave it unset for full glass.
- Codex CLI: `/theme` picker or `tui.theme` in `~/.codex/config.toml`;
  custom syntax themes are `.tmTheme` files in `~/.codex/themes/`. There is
  no stable `transparent_background` flag yet (upstream feature request is
  open); the default already leaves most surfaces on the terminal bg.
- Gemini CLI: `/theme` → `ANSI` / `ANSI Light` for terminal-matched colors;
  light/dark auto-switching works via OSC 11 (`ui.autoThemeSwitching`,
  on by default). Custom themes via `ui.customThemes` in `settings.json`.
- Grok Build (`grok`): fullscreen paints its own theme bg (GrokNight
  `#0a0a0a`, as in your screenshot) — run `/minimal` (or `grok --minimal`,
  or `[ui] screen_mode = "minimal"` in `~/.grok/config.toml` for sticky):
  minimal mode uses the terminal's native background, which is the glass.
  Themes via `/theme` or `[ui] theme` (`GROK_THEME` env, `auto` follows OS);
  `/terminal-setup` shows color support and available themes.
- Neovim (plain vim works with just `hi Normal ctermbg=NONE guibg=NONE`;
  Neovim 0.10+ additionally auto-enables `termguicolors` on truecolor
  terminals, so the colorscheme's opaque `guibg` wins unless cleared *after*
  it loads — a bare line in `init.lua` runs too early under lazy.nvim and
  gets overwritten). Use a `ColorScheme` autocmd and keep truecolor on:
  ```lua
  vim.opt.termguicolors = true
  vim.api.nvim_create_autocmd("ColorScheme", {
    callback = function()
      for _, g in ipairs({ "Normal", "NormalNC", "NormalFloat",
                            "SignColumn", "EndOfBuffer", "FloatBorder" }) do
        vim.api.nvim_set_hl(0, g, { bg = "NONE", ctermbg = "NONE" })
      end
    end,
  })
  ```
  Then `:colorscheme <your-theme>` to trigger it. Diagnose with
  `:verbose hi Normal` (shows what last set the fill). Colorscheme-native
  flags (`transparent = true` in tokyonight, `transparent_background` in
  catppuccin) or `transparent.nvim` work too.
- tmux (passthrough): `set -g default-terminal "tmux-256color"` plus
  `set -ag terminal-overrides ",xterm-256color:RGB"` so truecolor and OSC
  queries reach Genesis.
- Any other TUI (helix, lazygit, btop/htop, yazi, k9s, fzf, bat, …): look for
  background `none` / `transparent` / `default` in its theme and pick that.
  Same rule everywhere: `none` = glass, explicit color = opaque.

The sidebar search uses a dedicated `NSTextView`, with its own undo history,
single-line paste, horizontal caret scrolling, select-all on focus, and Escape
to clear and dismiss. It does not use `TextField` or `NSTextField`.

# Prestel

A native macOS terminal with a glass window, a collapsible sidebar of tabs,
and a built-in Code Review panel for your Git changes.

Prestel is written in SwiftUI and AppKit and uses
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal emulation.
Every tab runs your login shell in its own real PTY, so full-screen programs,
Unicode, IME input, and selection work as they do anywhere else.

## Features

- **Glass window.** The terminal surface is transparent where the background
  is the default color, so the glass shows through. See
  [TUI transparency](#tui-transparency-glass-background).
- **Sidebar tabs.** Every row is a terminal tab. Search them, reopen closed
  ones, and open new tabs in the current directory.
- **Code Review.** A panel on the right shows the staged and unstaged changes
  of the selected terminal's working directory, with syntax-highlighted diffs.
- **Commit from the panel.** Write a message, or press Draft to have a local
  model write one. Commit, commit and push, or commit, push, and open a pull
  request page.
- **Clipboard from programs.** Programs such as vim and tmux can set the
  system clipboard through OSC 52. Programs cannot read the clipboard.
- **Window restoration.** Tabs, working directories, and per-window review
  state come back after a relaunch. Running jobs are never restored, and
  quitting with live jobs asks first.

## Requirements

- macOS 26 or later
- Xcode 26.5 or later to build
- Git, for Code Review
- Optional: [Ollama](https://ollama.com) for commit message drafts

## Install and build

Prestel is built from source.

1. Clone this repository.
2. Open `Prestel.xcodeproj` in Xcode.
3. Run the `Prestel` scheme. Xcode fetches the Swift packages on the first
   build, so you need a network connection once.

From the command line:

```sh
xcodebuild -project Prestel.xcodeproj -scheme Prestel build
xcodebuild -project Prestel.xcodeproj -scheme Prestel test
```

The tests include some that start real shells.

## Code Review

The panel follows the local working directory of the selected terminal, using
the directory the shell reports. It does not guess from prompt text and does
not follow remote or tmux panes. Outside a Git repository it says so.

- Files start collapsed. Expand one to see its staged, unstaged, or untracked
  diff. Large diffs load on request.
- Commit writes the files listed in the commit sheet and leaves ignored files
  alone. A file you already split with `git add -p` keeps only its staged
  hunks in the commit; the rest stays unstaged.
- Push goes to the branch's upstream remote, or to `origin` with `-u` when the
  branch has none. The pull request page opens for that same remote.
- The panel never discards changes.

### Commit drafts with Ollama

Press Draft in the commit sheet and Prestel asks a model on your Mac to write
the message from the diff and your recent commit subjects. It uses local
Ollama when a supported model is installed, and Apple Intelligence otherwise.
Large diffs are summarized in passes first.

Prestel prefers `qwen3-coder:30b`, then `gpt-oss-20b`, and also recognizes
other installed Coder models. Ollama owns the model weights; Prestel does not
download or bundle them. To set one up, install Ollama and run
`ollama pull qwen3-coder:30b`.

## Shortcuts

- ⌘T new tab (inherits the working directory), ⌘W close tab, ⇧⌘W close window,
  ⇧⌘T reopen closed tab
- ⌃Tab / ⌃⇧Tab cycle tabs
- ⌘K clear
- ⌘S toggle the sidebar
- ⌘R toggle Code Review
- ⌘+ / ⌘= larger text, ⌘- smaller, ⌘0 default size. The window resizes to
  keep the same grid, so nothing rewraps.

The window title comes from the shell (OSC title) and the working directory
from OSC 7. File drops insert shell-quoted paths. Only http(s), mailto, and
file links open.

## License

MIT. See [LICENSE](LICENSE). Bundled third-party notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## TUI transparency (glass background)

Prestel renders default-background cells transparently so the glass shows
through (`backgroundOpacity = 0`, `window.isOpaque = false`; SwiftTerm skips
filling default-bg runs). Any TUI inherits it when it paints the
terminal-default background (`none`) instead of an explicit opaque fill —
the same pattern as the OpenCode `system` theme (text/background `none`).
Explicit hex/black fills stay opaque by design; panels, selections, and
diffs often keep subtle fills for readability.

Prestel side (automatic, locked by tests): `TERM=xterm-256color`,
`COLORTERM=truecolor`, `TERM_PROGRAM=Prestel`, plus OSC 10/11 answers from
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
  queries reach Prestel.
- Any other TUI (helix, lazygit, btop/htop, yazi, k9s, fzf, bat, …): look for
  background `none` / `transparent` / `default` in its theme and pick that.
  Same rule everywhere: `none` = glass, explicit color = opaque.

The sidebar search uses a dedicated `NSTextView`, with its own undo history,
single-line paste, horizontal caret scrolling, select-all on focus, and Escape
to clear and dismiss. It does not use `TextField` or `NSTextField`.

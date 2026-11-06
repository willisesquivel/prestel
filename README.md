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
- **Commit from the panel.** Write a message, or press Draft to have the
  on-device Apple model write one. Commit, commit and push, or commit, push,
  and open a pull request page.
- **Clipboard from programs.** Programs such as vim and tmux can set the
  system clipboard through OSC 52. Programs cannot read the clipboard.
- **Window restoration.** Tabs, working directories, and per-window review
  state come back after a relaunch. Running jobs are never restored, and
  quitting with live jobs asks first.

## Requirements

- macOS 26 or later. The download is a universal app for Apple Silicon and Intel.
- Git, for Code Review
- Optional: Apple Silicon with Apple Intelligence turned on, for commit message
  drafts

## Install

Download [Prestel 0.1.1](https://github.com/willisesquivel/prestel/releases/download/v0.1.1/Prestel-0.1.1.dmg).

Open the DMG and drag Prestel into Applications.

This build is not notarized by Apple yet, so macOS blocks the first launch.
Try to open Prestel once. Then go to System Settings, Privacy & Security,
scroll down, and click Open Anyway.

Notes for this version are on the
[v0.1.1 release](https://github.com/willisesquivel/prestel/releases/tag/v0.1.1).

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

### Commit drafts

Press Draft in the commit sheet and Prestel writes the message from the diff
and your recent commit subjects, using the language model built into macOS
through Apple Intelligence. There is nothing to download, no account or API
key, and no setting. If Draft is unavailable, the sheet says why, for example
that Apple Intelligence is off in System Settings or that the Mac is an Intel
Mac.

The model runs on your Mac. A long diff is trimmed to fit its small context
window, keeping every file's header and cutting the longest files first, so a
draft is one model call. Drafts are a starting point: edit them before you
commit.

## Shortcuts

- ⌘T new tab (inherits the working directory), ⌘W close tab, ⇧⌘W close window,
  ⇧⌘T reopen closed tab
- ⌃Tab / ⌃⇧Tab cycle tabs
- ⌘1–⌘8 select tabs by sidebar order, ⌘9 selects the last tab. Folders and
  split panes count; archived tabs do not. Search does not change the numbering.
- ⌘K clear
- ⌘F find in the terminal (⌘G / ⇧⌘G next / previous, Esc closes)
- ⌘S toggle the sidebar
- ⌘R toggle Code Review
- ⌘+ / ⌘= larger text, ⌘- smaller, ⌘0 default size. The window resizes to
  keep the same grid, so nothing rewraps.

The window title comes from the shell (OSC title) and the working directory
from OSC 7. File drops insert shell-quoted paths. Only http(s), mailto, and
file links open.

## Privacy

Prestel has no accounts, analytics, crash reporting, or telemetry. It does not
send your terminal output, files, or repository contents anywhere on its own.
Commit drafts are written by Apple's on-device model and never leave your Mac.
Git commands you run from the Code Review panel, such as push, talk to your
remote the same way they do in any terminal.

## License

MIT. See [LICENSE](LICENSE). Bundled third-party notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Shell integration

Zero config: zsh, bash and fish start with a small bootstrap that reports the
working directory (OSC 7) and marks prompts and commands (OSC 133: `A` prompt
start, `B` prompt end, `C` command start, `D;exit` command end). The scripts
are embedded in `ShellIntegration.swift` and written to
`~/Library/Application Support/Prestel/ShellIntegration/` at launch. Prestel
also sets `TERM_PROGRAM=Prestel` and `PRESTEL_SHELL_INTEGRATION=1`.

- Your dotfiles are never edited. zsh gets a wrapper `ZDOTDIR` whose `.zshenv`
  restores yours and sources your `.zshenv` first; bash runs as an interactive
  shell with `--rcfile` and replays the login files (`/etc/profile`, then the
  first of `~/.bash_profile`, `~/.bash_login`, `~/.profile`); fish loads a
  `vendor_conf.d` snippet through `XDG_DATA_DIRS`.
- It steps aside when your prompt already carries OSC 133 marks (a custom
  `PS1`, iTerm2 integration), and fish 4+ keeps its native marks.
- Untested in this repo: fish (no fish installed when written) and bash 4+.
  Bash sees `C`/`D` only if you have no `DEBUG` trap of your own.
- **Jump to Previous/Next Prompt**: ⌥⌘↑ / ⌥⌘↓ (View menu) scroll between
  prompts using SwiftTerm's stored marks; past the last prompt it returns to
  the bottom.
- **Long-command notifications**: a command that ran 10 seconds or more and
  finishes while Prestel is in the background, or its tab is not on screen,
  posts "Command finished" with the exit status. Permission is asked on first
  use. Toggle it under Settings → Notifications.

## Opening folders and scripts

Prestel registers as a handler for folders and for `.command`, shell script and
executable files, so Finder can open them here (a script runs in a new tab and
leaves you at the shell). macOS has no public API to make a terminal the
system default: to use Prestel for `.command` files, select one, Get Info →
Open with → Prestel → Change All….

- **Services**: Finder → right-click a folder → Services → *New Prestel Tab at
  Folder* / *New Prestel Window at Folder* (enable them under System Settings →
  Keyboard → Keyboard Shortcuts → Services if hidden).
- **Dock menu**: right-click the Dock icon for New Window, New Tab and recent
  folders (folders opened through Finder, the Services or Open Folder…).


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
  `#0a0a0a`) — run `/minimal` (or `grok --minimal`,
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

## Build from source

To work on Prestel, clone this repository and open `Prestel.xcodeproj` in
Xcode 26.5 or later. Run the `Prestel` scheme. It uses a Release build with
the debugger and runtime checkers disabled for everyday terminal work. Xcode
fetches the Swift packages on the first build, so you need a network
connection once.

Use the `Debug Prestel` scheme when you need breakpoints or runtime checks.
Keep long-running terminal sessions in the `Prestel` scheme or launch the
built app directly. For a frozen debugging session, try pausing and continuing
in Xcode before force quitting; this may recover the existing shells.

From the command line:

```sh
xcodebuild -project Prestel.xcodeproj -scheme Prestel -configuration Release build
xcodebuild -project Prestel.xcodeproj -scheme Prestel test
```

The tests include some that start real shells.

Run the terminal reliability check with:

```sh
python3 scripts/check-reliability.py --runs 5
```

Each run starts a fresh test app with a hidden window, sends 216,000 colored
lines through three PTYs, changes splits, panels, window size and font size, and opens and closes
24 temporary sessions. It checks output, completed draws, UI delays and shell
cleanup. Logs and test results go under `.build/reliability/Release`; an external
timeout captures the test app's stack if it hangs. Use `--configuration Debug`
to check the unoptimized build too.

Zsh sessions use a temporary startup directory and wait for a shell handshake
before the stress phase. Completion markers pass through the terminal parser
so wrapping and prompt redraws cannot erase the completion signal.

The optimized test host enables testability and disables hardened runtime so
XCTest can load its locally signed bundle. The timing run removes Xcode's
runtime-checker injection; `Debug Prestel` keeps the diagnostic tools. Normal
Release builds retain their project settings. A passing stress run covers these operations; it does not
establish the cause of an unreproduced freeze.

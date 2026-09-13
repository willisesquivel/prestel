# Genesis Terminal

A macOS terminal with a glass window treatment, inset detail surface,
collapsible sidebar, custom rows, search capsule, and navigation chrome.
Every sidebar row is a **terminal tab** with its own mock buffer.

## Status: mock phase (no PTY yet)

- Real interactive shells (`/bin/zsh` + PTY) are **not** forked yet.
- Input echoes locally; `MockTerminalEngine` returns canned output with basic ANSI SGR.
- This lets us lock the UI/geometry first, then swap in a real PTY without changing chrome.

## Run

Open `GenesisTerminal.xcodeproj` in Xcode 26.5+ and run the `GenesisTerminal` scheme.

- Baseline window 960×640, min 760×540 so a terminal fits.
- Shell metrics: sidebar 172 (150–300, ≥320 detail),
  detail inset 10 / radius 20, search 30h/15r, rows 28h, spacing 1,
  nav capsule 92×32, traffic 12pt at (18,16)/(24,31.5).

## Sidebar

Starts with a single session (`Local ~/Lume`) plus a pinned Settings row.
All rows share the same 28pt height and uniform placeholder tile.
Search filters by title, cwd, and branch. Back/forward walks selection history.

## Files

- `GenesisTerminalApp.swift`: full-content AppKit window, hidden native controls.
- `WindowSupport.swift`: `ShellMetrics` + `NSGlassEffectView` backdrop.
- `TerminalModel.swift`: tabs, per-tab sessions, search, history, resize.
- `MockTerminalEngine.swift`: `AnsiParser` (SGR 0/1/30-37/90-97), boot scripts, canned commands.
- `TerminalView.swift`: detail-surface terminal (header, transcript, input).
- `ShellView.swift`, `SidebarView.swift`, `SearchField.swift`, `ChromeView.swift`: window chrome.

## Next (PTY phase)

1. Fork per-tab `/bin/zsh` via `posix_spawn` + `pty`, stream output into `TerminalLine`s.
2. Replace `MockTerminalSession.submit` with PTY write; keep ANSI parser (extend to cursor ops).
3. Make sidebar dynamic (add/close/rename tabs) while keeping the 28pt row geometry.
4. Persist tabs/CWDs, add ⌘T/⌘W/⌘K, font-size prefs.

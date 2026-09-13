# Genesis Terminal

A macOS terminal with a glass window treatment, inset detail surface,
collapsible sidebar, custom rows, and a search capsule.
Every sidebar row is a **terminal tab** backed by its own real PTY running
the account login shell. No floating chrome: window controls are the native
titlebar buttons, and tab/sidebar commands live in the menu bar.

## Status: real PTY via SwiftTerm (integration branch)

- Each tab owns a `LocalProcess` PTY + `GenesisTerminalView` (SwiftTerm core:
  grid, SGR/cursor parsing, alt-screen TUIs, Unicode/IME, selection).
- SwiftTerm is pinned via SwiftPM (`12ea7f5`); see `Package.resolved`.
- Only `Terminal` tabs fork shells. The `Settings` tab never creates a PTY.
- Sidebar keeps its soft scroll-edge; the terminal surface scrolls with its
  own native scroller (no wrapper scroll view).

## Run

Open `GenesisTerminal.xcodeproj` in Xcode 26.5+ and run the `GenesisTerminal` scheme.
Xcode resolves SwiftTerm on first build (network required once).

- Baseline window 960×650, min 760×540.
- Shell metrics: sidebar 172 (150–300, ≥320 detail),
  detail inset 10 / radius 20, search 30h/15r, rows 28h, spacing 1.
- Tests: `xcodebuild test` — unit + live-PTTY tests (spawn real shells).

## Tabs & chrome

- ⌘T new tab (inherits cwd), ⌘W close tab / ⇧⌘W close window, ⇧⌘T reopen,
  ⌃⇧Tab / ⌃Tab cycle, ⌘K clear, ⌃⌘S toggle sidebar. Last tab closes its window.
- Title comes from the shell (OSC title), cwd from OSC 7; file drops insert
  shell-quoted paths; only http(s)/mailto/file links open.
- Quitting or closing with live jobs asks for confirmation; PIDs are reaped,
  never persisted. State restoration keeps lightweight descriptors only.

## Files

- `GenesisTerminalApp.swift`: multi-window ownership, menus, Settings screen,
  quit/close confirmation, restoration.
- `WindowSupport.swift`: `TerminalWindowController`, restoration,
  `ShellMetrics`, glass backdrop, toolbar header.
- `TerminalModel.swift` + `TerminalSession.swift`: tabs, PTY lifecycle,
  search, history, recently-closed, descriptors.
- `TerminalView.swift`: SwiftTerm surface hosted directly with content insets.
- `ShellView.swift`, `SidebarView.swift`, `SearchField.swift`, `ChromeView.swift`: chrome.

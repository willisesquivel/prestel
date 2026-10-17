# Newline chords, 2026-10-17

Shift+Enter and Option+Enter insert a newline in Grok Build. Ian confirmed it in the running app.

## What was wrong

Prestel rewrote those chords only when `usesApplicationKeyboard` was true. That flag is on for application cursor keys (DECCKM) or for Kitty keyboard flags on either screen. The rewrite always sent Kitty `CSI 13;2u` (Shift+Return) or `CSI 13;3u` (Option+Return).

Grok only treats those sequences as a newline after it has enabled the Kitty keyboard protocol on the screen you are looking at. With cursor keys on and Kitty off, the sequence is ignored. At a normal prompt, Shift+Return became a plain Return (Grok sends the message) and Option+Return became `insertNewlineIgnoringFieldEditor:`, which SwiftTerm drops, so the key did nothing.

`keyDown` on SwiftTerm is not `open`, so Prestel still cannot override it. The local key monitor remains the place that encodes these chords.

## What it sends now

`TerminalKeyIntercept.bytesToSend` takes two extra flags.

- `kittyKeyboard`: the active screen has Kitty `disambiguate` or `reportAllKeys`. Shift+Return is `CSI 13;2u`, Option+Return is `CSI 13;3u`, both together is `CSI 13;4u`. Ctrl+Return stays `CSI 13;5u` and Shift+Space stays `CSI 32;2u`, and only in this mode.
- `legacyNewline`: alternate screen, application cursor, or application keypad, and Kitty is off. Shift+Return and Option+Return send ESC CR, which Grok reads as Alt+Return and inserts a newline.
- Neither flag: a shell prompt. Shift+Return is still a normal Return. Command+Return is never rewritten.

Flags on the other screen do not count. A shell prompt does not receive `CSI 13;2u` because a full-screen app pushed Kitty and never popped it.

The monitor sends the bytes to the `PrestelView` in the responder chain, not only `selectedTab`. A split pane or a Metal subview in front of the terminal still gets the chord.

## Files

- `Prestel/WindowSupport.swift`
- `Prestel/TerminalView.swift`
- `PrestelTests/PrestelTests.swift`

## Tests

These five passed on the Debug Prestel scheme:

- `optionArrowInterceptSendsReadlineWordJumpsInTheShell`
- `optionArrowInterceptSendsOneModifiedCSISequenceInATui`
- `modifiedEnterInsertsANewline`
- `applicationCursorAndKittyProtocolEnableTuiKeyMode`
- `newlineChordsFollowTheActiveScreen`

The full suite was not run. Ian checked Shift+Enter and Option+Enter in Grok Build and said it works.

## Left alone

Cursor-key arrows are unchanged. A full-screen app that did not enable Kitty now gets ESC CR for these two chords. In vim insert mode that leaves insert mode. Previously, with cursor keys on, Prestel sent the Kitty sequence and vim ignored it, so the key also did not insert a newline.

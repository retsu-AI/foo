# Terminal UI integration

Call `tui.run(allocator, operation, options)` from the frontend. Supply the shared runner, the prepared `host.RunInput`, and the TUI settings from `configuration.Effective.launch.tui`. The input supplies the session, the first run ID, and any committed history from the caller's session binding. The UI borrows the services and initial messages until it returns. Use a synchronous runner that honors the operation cancellation and deadline.

Pass the environment map for `TERM=dumb` and `NO_COLOR` handling. The default streams are process stdin and stdout. Supply `Options.streams` to use other handles. Plain mode reads a bounded prompt through EOF and writes committed assistant text. It also applies when either stream lacks native terminal support.

## Input and display

The default keys are Enter to submit, Alt+Enter for a newline, Ctrl+C to cancel, and Ctrl+D to quit. The four action bindings and display colors come from the resolved configuration. The editor accepts bracketed paste and replaces invalid UTF-8. Arrow keys edit the prompt, and Page Up and Page Down scroll the transcript. Modified Enter depends on the terminal forwarding the modifier. The parser recognizes enhanced VT encodings for Ctrl+Enter, and the Windows adapter can distinguish console key records that carry the modifier.

The renderer uses the terminal's alternate screen and clips frames to the visible view. It redraws changed rows and coalesces streamed updates. Display retention is bounded separately from the committed conversation used for later prompts. The Unicode tables are generated from Unicode 16.0.0 data. The renderer assumes one cell for ambiguous-width characters and two for emoji presentation. Fonts and terminal Unicode versions can affect the cells users see.

Linux and macOS use POSIX terminal modes. Windows uses console input records and VT output. On controlled exit the adapter restores saved modes. The cursor, alternate screen, and paste reset sequences require a usable output stream. Tests exercise native Unix PTY and Windows ConPTY behavior. [Native test and measurement commands](../../tests/tui/README.md).

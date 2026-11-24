# Run the native terminal and TUI fixtures

```sh
nix develop .#ci -c python tests/tui/run.py
```

The runner builds the probes with the pinned Zig toolchain in Debug and ReleaseSafe. It drives the terminal backend and the TUI through a Unix PTY or a Windows ConPTY. The scripted runner uses the shared event and runner contracts and needs no provider credentials. The Native TUI workflow runs this driver on Linux, macOS, and Windows.

The fixture covers Unicode editing, paste, resize, transcript scrolling, tool and error display, cancellation, redirected streams, and terminal restoration. Unix checks compare the terminal attributes before and after controlled exit. The Windows probe checks saved console modes after it restores them.

Capture the VT streams and an input-to-output sample on the current machine with this command.

```sh
nix develop .#ci -c python tests/tui/run.py --optimize ReleaseSafe --artifacts .audit/tui --measure
```

The measurement times 20 short edits in an 80 × 18 native terminal. The timed region starts before writing the bytes to the terminal and ends when the unique edit appears in the output stream. It includes driver scheduling, input decoding, the next redraw, and the bytes arriving at the peer. The long transcript sample counts bytes from prompt input through the observed completion status. Both results include the terminal transport and exclude provider latency, GUI presentation, and network effects. Each sample validates its expected output.

F12 owns executable dispatch and root build registration. For F13, repeat the integrated flows in terminals used for release qualification. Check first usable frame, keyboard layout and modified Enter, emoji cell width, multiline paste, resize while a provider streams, and terminal restoration on quit and handled termination.

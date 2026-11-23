# Session store

F07 implements `foo.session.Store` for one linear conversation. Use `Store.initMemory` for volatile history or `Store.create` and `Store.open` for local persistence. The local store borrows an open, iterable, private session directory and its `std.Io` for the lifetime of the store. Keep the store at a stable address while the core uses `store.interface()`. Calls to one handle are sequential. Close the store with `deinit`.

Supply the same non-secret configuration identity on create and reopen. Opening a journal with a different identity returns `IdentityMismatch`. The host provides recovered messages explicitly as older input to the next prompt. The core commits each new user prompt, the completed assistant messages, and the tool records. The host supplies any system prompt or external history that the core did not journal.

## Format version 1

`journal.jsonl` contains one LF-terminated JSON object per record. The first record is a header. A frame contains the next sequence number and one tagged `foo.session.Record`. CRC-32 covers the exact UTF-8 bytes of the payload object and appears as eight lowercase hexadecimal digits.

```jsonl
{"crc32":"97501d16","payload":{"sequence":1,"record":{"header":{"version":1,"config_identity":"model-a"}}}}
{"crc32":"2230ae20","payload":{"sequence":2,"record":{"message":{"role":"user","blocks":[{"text":"Hello"}]}}}}
```

UTF-8 byte fields use JSON strings. An opaque byte field that contains invalid UTF-8 uses a JSON array of byte values. The checksum detects accidental changes. Keep the directory private and restrict access to the session owner.

Version 1 journals written before nested tool recording remain readable. Older readers reject complete `nested_tool` frames.

## Commit and recovery

The local store holds an exclusive OS lock on `writer.lock` from open through teardown. Keep that sidecar in place. A competing writer receives `WriterBusy`, and process exit releases the lock. The host owns creation and synchronization of the session directory's entry in its parent.

Each accepted local commit writes the full frame and synchronizes the journal file before it returns the sequence number. A top-level or nested tool result with an artifact first synchronizes that artifact. Linux and macOS also synchronize the session directory for new entries. Windows uses file synchronization and leaves directory metadata durability across system or power loss unqualified.

A `nested_tool` record identifies the current dispatched parent and the child ordinal, starting at 1 for each parent. Each child result matches the preceding intent's ordinal and call ID. The next ordinal becomes available after an `observed` or `not_started` child result. The store rejects a definitive parent result while a child is pending or unresolved. Once a child is observed, the store also rejects a `not_started` parent result. Only the parent appears in the provider transcript.

If writing or synchronizing a frame fails, the store attempts to truncate and sync back to the last acknowledged offset. The failed call returns no sequence and the handle must close. If rollback also fails, a later open validates whatever bytes survived. A complete valid frame can survive a failed acknowledgment. The caller must stop effects on an ambiguous commit.

| Durable prefix on reopen | Recovery |
| --- | --- |
| User prompt or assistant text with no terminal record | Keep committed messages and report interruption. |
| Assistant tool batch with no dispatch | Expose the earlier complete transcript. Report interruption with no uncertain effect. |
| Dispatch intent with no result | Report its call ID as uncertain. |
| Result marked uncertain | Keep the call ID unresolved across the terminal record. |
| Nested intent without a result, or nested result marked uncertain | Report the parent and exact child call IDs, in that order. |
| Completed tool batch | Recover the assistant message and the correlated tool-role results. |
| Terminal outcome | Close the run. An explicit new prompt can follow if all effects are resolved. |

Recovery never dispatches a tool. It validates every complete frame, rejects gaps, duplicate sequences, invalid order, and corruption, and reports unsupported versions. Reopen trims an unterminated final frame after it validates the complete prefix. It retains the journal contents for incomplete tool batches but excludes those batches from provider-ready context. A caller can inspect the retained journal when reconciling an interruption. An unresolved effect blocks new prompts on that store.

Display deltas stay provisional. The journal accepts completed semantic records, and the core publishes committed events only after the store returns their sequence.

## Limits and artifacts

The defaults allow an 8 MiB framed record, a 256 MiB journal, 32 MiB of retained context, and 64 MiB across up to 1,024 artifacts. The context budget includes message and block overhead and unresolved call IDs. A nested intent reserves enough space to recover both IDs. Recovery reads one frame at a time and retains bounded provider context. A commit that exceeds a budget fails with `LimitExceeded`. A reopen with smaller limits can also fail. To continue after reaching a session limit, create a fresh session with explicit context.

Use `writeArtifact` with a unique `artifact-` basename made of lowercase ASCII letters, digits, dots, underscores, and hyphens. The suffix ends with a letter or digit. The returned reference borrows the basename. Keep it alive through the result commit. Artifact reads verify the same relative name and byte length. The local store accepts regular files with a single link and rejects symlinks. Exclusive creation prevents an existing artifact from being replaced. A crash can leave unreferenced files in the session directory. They count against the same limits and remain available for inspection until the host removes the closed session.

With `initMemory`, the store copies records and artifacts into bounded memory and releases them on `deinit`. It opens no files. Its sequence numbers are valid for that handle's lifetime. A host can also pass no store to the core for run-local sequencing without retained session state.

## Verification and integration

From the repository root, run the package suite with Zig 0.17.1.

```sh
nix develop .#ci -c python tests/session/check.py
nix develop .#ci -c python tests/session/check.py --optimize ReleaseSafe
```

The suite injects short writes, zero progress, disk full, and sync failure into real temporary journals. The crash probe starts a separate process, tests writer exclusion, kills the writer, and checks the recovered prefix and external marker at top-level and nested tool boundaries. The package passed these checks on native x86-64 Linux. The session test root type-checks for aarch64 macOS and x86-64 Windows. Native filesystem qualification on those systems remains open.

For F12, register `src/session/root.zig` with import `foo`. Register `tests/session/root.zig` with imports `foo`, `journal`, and `core` to enable `zig build test -Dmodule=session`. The package script also runs the separate native crash probe.

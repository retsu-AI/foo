# ACP v1 agent

`serveStdio` adapts newline-delimited ACP v1 to the shared synchronous
`host.Runner`. `serve` takes caller-owned `std.Io.File` handles. Both entry
points accept a concurrent allocator and an I/O implementation that supports
concurrent tasks and cancellation of blocked pipe operations. The adapter
writes only JSON-RPC frames to the output handle.

## Runtime composition

F12 supplies the session factory. `Factory.open_fn` receives the validated
working directory, session identity, editor MCP descriptors, and a
session-bound client host. Apply the configured executable policy and pass
approved editor MCP descriptors to F06. The open callback borrows those
descriptors for its duration. Use the session allocator for runtime state and
copy any descriptor fields that F06 needs after open. The factory reports
`AuthenticationRequired` if the configured provider credential is missing.

`Runtime.prepare_fn` receives each new run identity and returns the tools and
services for that turn. Use it to prepare permission-aware tools and to
select each configured backend. Client files and processes depend on the
corresponding editor capabilities. Select local services explicitly when
configured. Client tool errors never dispatch local work. The client
filesystem provides plain reads and writes. Tools that require atomic
compare-and-swap must use a backend that provides it.

The adapter copies committed messages into bounded session history and
passes that history plus the new prompt to the runner. An ACP refusal
discards that turn's committed messages from the next prompt. The optional
store can record commits, but durable ACP replay and refusal-aware recovery
need their own qualification before advertising session load. Editor
resource links enter the prompt as their name and URI. The adapter does not
fetch the URI.

## Lifetimes and limits

A connection admits one session open or prompt at a time. The reader handles
notifications and replies while the worker runs. A separate writer drains
a bounded queue. Sustained output pressure closes the connection and cancels
active work. Requests retain their typed IDs through the terminal response.
Cancellation retires pending reverse requests and leaves terminal cleanup
with its own deadline.

Terminal output offsets apply to untruncated snapshots from byte zero.
The adapter rejects an offset if the editor has discarded bytes from its
snapshot. The shutdown report counts terminal cleanup that could not be
confirmed and runtime close failures. On disconnect, runtime callbacks
share one shutdown deadline. Factory and runner code must honor the supplied
operation deadlines and cancellation. The adapter joins its tasks before
returning.

See the [ACP pipe tests](../../tests/acp/README.md) for the method matrix,
stop reasons, and test commands.

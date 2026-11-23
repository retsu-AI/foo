# Wire framing and JSON-RPC

Providers, MCP, and ACP share this layer for byte framing, bounded JSON, and
JSON-RPC correlation. Each consumer owns method dispatch, protocol state, and
retry or cancellation messages.

## Read a stream

Allocate one reader and its buffers per stream. Call `feed` with each chunk and
`finish` at EOF. Callbacks run synchronously and borrow the frame until they
return. Copy any bytes that you keep. EOF and errors close the reader. Use a new
reader for a new stream.

- `framing.Ndjson` accepts LF and CRLF. Choose whether to reject or skip empty
  lines. The caller's buffer limits the record size. A partial final line
  returns `TruncatedFrame`.
- `framing.Sse` accepts LF, CRLF, and CR with one optional leading UTF-8 BOM.
  The line buffer bounds individual fields and comments. The data, event, and
  two cursor buffers bound retained fields. `Storage.max_event_bytes` also caps
  their combined event content.
- SSE joins data lines with LF, defaults the event name to `message`, and
  commits the cursor at the blank line. `lastEventId()` returns null before any
  ID has committed and an empty slice after an explicit reset. `retryMilliseconds()`
  reports the last digits-only retry value that fit in a `u64`.
- Both readers reject malformed UTF-8. SSE reports incomplete events as
  `TruncatedFrame` and discards their data. Control fields and keepalive
  comments alone emit no events.

The strict UTF-8 and explicit EOF errors give protocol callers a way to stop a
malformed stream. [SSE parsing rules](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation) · [NDJSON specification](https://github.com/ndjson/ndjson-spec)

## Decode or write JSON

`json.validate` checks a complete JSON value before allocation-heavy decoding.
The default input limit is 8 MiB. Depth counts open objects and arrays, with a
default of 64 and a hard maximum of 256. `json.decode` uses a caller-owned
`FixedBufferAllocator`. Keep the input and allocator alive until you finish
with the result. Reset the allocator when its results are no longer in use.

`jsonrpc.decode` yields a contract request or response. The input owns the raw
`params_json`, `result_json`, and `data_json` slices. Escaped strings can borrow
the caller's scratch buffer. Retain both buffers or copy the fields before
returning from a framing callback.

The codec accepts signed 64-bit integer literals and string IDs. A request with no ID
is a notification. A request or success response with an explicit null ID is
unsupported. An error response uses `id:null` when its ID is unknown. The codec
requires structured params, rejects recognized duplicate envelope fields and
batches, and permits extension fields for their owning protocol to interpret.
[JSON-RPC 2.0 specification](https://www.jsonrpc.org/specification)

`encodeRequest` and `encodeResponse` validate raw payloads and write compact
JSON into caller storage. Pass the result to `framing.Writer.write` for stdio.
Writer scratch must fit the record plus its trailing LF. The writer sends it
in one sink callback. An overlapping call returns `Busy` before entry. A sink
failure closes the writer because the peer may have received a partial record.

## Correlate requests

Give each connection one owner for its `correlation.Table` and keep the table
at a stable address while tickets exist. The default limit is 64 pending entries per direction and 4096 copied bytes per inbound string
ID. For an outbound request, call `beginOutbound` before writing and retire the
ticket if the send fails. Generated numeric IDs are never reused within a
table. `resolve` distinguishes unknown IDs, retired IDs, and a response at or
past its deadline. A deadline result carries the ticket of the expired request.

Use `beginInbound` only for requests with an ID. The table copies string IDs
and rejects a duplicate pending ID. Call `prepareInboundResponse` with the
ticket and current monotonic time before replying. An expired response
admission retires the ticket. A ready admission supplies the borrowed ID
and deadline to use for writing. Keep the ticket pending until its response
has been ordered into the writer, then retire it. The ID is valid up to
retirement. A ticket changes if the peer reuses an ID. Route peer cancellation
through the same connection owner.

Call `cancel` or `expireNext` to retire work while the connection runs. To
shut down, call `close` and use `drainNext` to notify each waiter once. Join
caller-owned work before reclaiming storage. The table never closes transport
handles or sends protocol messages.

## Consumer examples

For a provider response, call `Sse.feed` from the HTTP body callback and pass
each event's `data` to the provider's codec. The application owns event names
and any terminal marker. Preserve any framing error in the callback state if
you need to return it through the narrower `io.ByteSink` error set.

For MCP over HTTP, use the same SSE feed with `jsonrpc.decode(event.data, ...)`
or decode a bounded ordinary JSON response directly. Match a response through
`Table.resolve`. Store a resumption cursor only after accepting the event
under the chosen MCP profile.

For MCP or ACP over stdio, feed stdout reads into `Ndjson`, decode each complete
record before its callback returns, and route requests and responses by their
types. Encode outgoing messages into separate storage before calling
`Writer.write`. Keep stderr separate from the framed byte stream. The wire
fixtures exercise both I/O contracts with scripted peers. [Consumer fixtures](../../tests/wire/integration.zig)

## Verify

```sh
nix develop .#ci -c zig build test -Dmodule=wire --summary all
nix develop .#ci -c zig build test -Dmodule=wire -Doptimize=ReleaseSafe --summary all
nix develop .#ci -c zig build test -Dmodule=wire -Doptimize=ReleaseSafe -Dwire-test-filter='fuzz line and event' --fuzz=10K -j4
nix develop .#ci -c zig build test -Dmodule=wire -Doptimize=ReleaseSafe -Dwire-test-filter='fuzz bounded JSON-RPC' --fuzz=10K -j4
```

The corpus covers every byte split for representative records, malformed and
partial input, resource limits, stale IDs, and concurrent writer admission.
Fuzz inputs are capped at 512 bytes. They exercise fragmented framing with
fixed per-stream buffers and JSON-RPC round trips at an eight-level depth
limit. [Fuzz seeds and entrypoints](../../tests/wire/fuzz.zig)

On Linux x86_64 with Zig 0.17.1, both build modes passed the 25-test suite.
Both filtered ReleaseSafe fuzz runs completed with a 10K iteration budget.
The Debug fuzzer on that host produced an empty coverage table, so the commands
above use ReleaseSafe for coverage. The macOS arm64 and Windows x86_64 suites
also cross-compiled.

# Native process ownership

Import the `foo-process` build module and initialize `Native`. Use
`native.interface()` wherever an adapter expects `foo.io.Spawner`, including
custom tools and future MCP stdio. The host supplies its environment snapshot
only for launches that request inheritance. Each start receives explicit argv,
cwd, and environment. The backend does not invoke a command shell.

On Linux and macOS, build or install `foo-process-guardian` with `zig build` and
pass its absolute path as `Native.guardian_path`. The guardian starts the command
in its own process group and owns its direct child. Owner death closes the lease.
On cancellation, leader exit, or lease closure the guardian signals the entire
command group and reaps the group leader before reporting its exit. Linux also
reaps adopted members in the command group. On macOS, the guardian verifies that
the group has no live members before reaping its leader. The OS reaps orphaned
descendants. The adapter reports a failure if it cannot confirm group cleanup.
A descendant that deliberately moves to another group can escape this ownership
mechanism.

On Windows, a kill-on-close Job Object owns each command tree from creation.
Windows 10 or newer supplies the creation-time Job attribute. The backend resolves
executables from the configured directory and effective child `PATH`. Use an
explicit interpreter for shell scripts. The full 32-bit process exit code is
preserved as an `i32` bit pattern. An embedding host must use explicit child
handle lists for its concurrent Windows launches. Broad inheritance in a
separate launch can retain a tool pipe outside its Job.

The child owns three independent pipe endpoints. Callers can read stdout and
stderr while writing stdin and waiting. Use at most one outstanding operation per
endpoint and join those operations before `release`. `wait` preserves unread pipe
bytes and caches its final exit or signal. `terminate` requests tree cleanup and can
run alongside reads and wait. `release` closes the endpoints and joins cleanup
even after the caller cancels. Native reaping can wait on the operating system
after a termination request.

Run the native fixtures with Zig 0.17.1.

```sh
zig build test -Dmodule=platform-process
zig build test -Dmodule=platform-process -Doptimize=ReleaseSafe
```

The fixtures launch real children and cover argv including spaces and quotes,
environment, cwd, separate streams, exit status, POSIX signals, bounded spooling,
stdin/stdout JSON, and descendant cleanup on deadlines, cancellation, leader exit,
and forceful owner exit. The Native tools workflow runs them on Linux, macOS,
and Windows.

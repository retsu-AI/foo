# Run the configuration fixtures

Use Zig 0.17.1 through the repository Nix shell.

```sh
nix develop .#ci -c zig test \
  --dep foo --dep configuration --dep support -Mroot=tests/config/root.zig \
  -Mfoo=src/lib.zig --dep foo -Mconfiguration=src/config/root.zig \
  --dep foo -Msupport=tests/support/root.zig
```

For ReleaseSafe, add `-O ReleaseSafe` before each `-M` argument. The integrator owns root registration for `zig build test -Dmodule=config`.

The suite resolves frontend-independent inputs through the public API. It checks layer precedence, source attribution, explicit relative files, empty prompt and tool overrides, configuration limits, and effective-output redaction. The DeepSeek profile uses fixture values and environment reference names. Tests do not contact configured endpoints or execute configured tools.

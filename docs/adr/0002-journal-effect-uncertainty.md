# ADR 0002: Commit at effect boundaries and report uncertainty

## Status

Accepted 2026-11-16. F07 implements the session journal and passed native process-crash recovery on Linux. Native macOS and Windows filesystem qualification remains open. [Session store](../../src/session/README.md).

## Context

A tool may change a file or remote system before foo records its outcome. A crash or failed journal commit can leave no reliable record of whether the effect occurred. Replaying such a call can duplicate the effect.

## Alternatives

Recording only final tool results leaves no evidence of interrupted dispatch. Automatically replaying an intent without a result risks duplicate effects. A transactional or exactly-once guarantee cannot cover arbitrary external tools and remote services.

## Decision

With persistence enabled, commit dispatch intent before the effect. Synchronize referenced artifacts and commit the observed outcome before publishing a committed result or admitting dependent effects. Keep display deltas provisional.

An intent without an outcome is uncertain. Recovery reports that state and never automatically replays the tool. If the outcome commit fails after execution, stop further effects. The caller reconciles the uncertainty and explicitly supplies any next prompt.

The [architecture](../architecture.md#sessions-journals-and-effect-uncertainty) defines the journal and recovery requirements. The [shared contracts](../../src/contracts/README.md#lifetimes-and-effects) define the bootstrap interface semantics.

## Consequences

Callers receive truthful uncertainty instead of an invented success or failure. Persistence adds synchronization cost that qualification must measure. Memory-only contract tests prove ordering, while native process-crash tests must establish the durable implementation's behavior.

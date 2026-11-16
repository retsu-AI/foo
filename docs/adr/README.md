# Architecture decisions

ADRs record lasting choices and their consequences. The architecture and protocol documents contain the detailed target design. The [shared contracts](../../src/contracts/README.md) describe what the bootstrap implements today.

An accepted ADR approves a target decision. It does not mark a runtime capability or release gate complete.

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](0001-external-orchestration.md) | Keep orchestration outside foo | Accepted target decision |
| [0002](0002-journal-effect-uncertainty.md) | Commit journal records at effect boundaries and report uncertainty | Accepted target decision |

Add a numbered ADR when a lasting architectural choice needs its rationale preserved. If a later decision replaces one, retain the original and link its replacement.

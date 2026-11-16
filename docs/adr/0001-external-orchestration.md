# ADR 0001: Keep orchestration outside foo

## Status

Accepted target decision, 2026-11-16. The bootstrap contracts follow this boundary. The runtime loop and process control interface remain planned.

## Context

foo needs one execution engine for its library, CLI, TUI, MCP client, and ACP agent. The [reference evidence](../plan/evidence.md) shows how scheduling, child agents, worktrees, and verification expand a harness's responsibilities.

## Alternatives

One option is to build a scheduler, planner, child-agent lifecycle, and verification policy into foo. Another is to expose one bounded conversation loop and let calling applications coordinate independent instances or processes.

## Decision

Choose external orchestration. Each foo instance runs one active conversation. Calling applications own scheduling, worktrees, task verification, retries across attempts, and coordination. The proposed JSONL process interface carries explicit inputs, events, and outcomes. MCP and ACP adapt to the same loop.

The [architecture](../architecture.md#system-shape) defines the detailed ownership boundary.

## Consequences

Frontends share one meaning for cancellation, limits, tools, and outcomes. Hosts can choose their workflow without adding policy to the core. Integrators must supply their own orchestration and distinguish a normal model stop from evidence that a task succeeded.

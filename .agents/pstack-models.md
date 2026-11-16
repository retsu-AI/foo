# pstack model configuration

This project's sheet. In this repository it replaces the user's
`pstack-models.md`; ignore that sheet's model and effort lines.

Budget: large (xhigh). The role rows below apply on Codex. Other harnesses should
keep this budget, use their own platform mapping, and resolve their available
models before dispatching; do not pass Codex model IDs to another provider.

Single-model roles inherit the current Codex model. Panel roles use the Codex
models confirmed available during installation.
`inherit-parent` omits the dispatch model; an explicit model and effort override
applies to a subagent, not the parent session. Pass the selected effort through
`reasoning_effort`; when selecting either model or effort explicitly, start the
subagent with `fork_turns: "none"` and provide the relevant file pointers.

feature, refactoring: inherit-parent
bug-fix: inherit-parent
perf-issue: inherit-parent
hillclimb: inherit-parent
judgment and prose: inherit-parent
strongest judgment: gpt-6-astra
how explorer: inherit-parent
how explainer: inherit-parent
why investigators: inherit-parent
why synthesizer: inherit-parent
reflect tooling: inherit-parent
reflect judgment, divergent, synthesizer: inherit-parent
arena runners: gpt-6.1-sol, gpt-6-astra, gpt-6.1-terra
arena cross-judge pool: gpt-6-astra, gpt-6.1-terra, gpt-6.1-sol
swarm workers: inherit-parent
architect runners: gpt-6.1-sol, gpt-6-astra, gpt-6.1-terra
interrogate reviewers: gpt-6.1-sol, gpt-6-astra, gpt-6.1-terra
thermos reviewers: inherit-parent
no-comments reviewer: inherit-parent

default effort: xhigh

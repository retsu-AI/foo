# Agent workflows

For engineering tasks in this repository, use the shared pstack skills in
`.agents/skills/`, starting with `.agents/skills/poteto-mode/SKILL.md` and its
mapping for the current harness. Read `.agents/pstack-models.md` before
dispatching a pstack role; its model and effort choices override the bundled
defaults. This standing instruction provides routing without plugin hooks.
Prefer these repository skills over similarly named user skills; in particular,
use `.agents/skills/setup-pstack/SKILL.md` for pstack configuration. Keep project
model preferences in `.agents/pstack-models.md` when running setup again.

Enter `nix develop` for project tools. See `docs/pstack.md` for installation,
usage, and maintenance. Read `docs/plan/README.md` for implementation scope.

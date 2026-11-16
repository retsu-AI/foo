# Shared pstack skills

The repository vendors 67 skills from the [portable pstack port](https://github.com/michael-denyer/pstack-claude)
of [Lauren Tan's pstack](https://github.com/cursor/plugins/tree/main/pstack)
in `.agents/skills/`. Harnesses can discover the same `SKILL.md` directories and
their bundled scripts and references. The shared directory is `.agents`
(plural). No user-wide plugin installation is required.

## Start using it

Start a fresh Codex session from this directory:

```sh
nix develop -c codex
```

Invoke the plain skill name:

```text
$poteto-mode Implement the next bounded item in docs/plan.
$how Explain how this harness handles cancellation.
$interrogate Review the current diff.
```

`/skills` lists the skills in Codex. The root `AGENTS.md` also routes engineering
work through the repository's `poteto-mode`, so explicit invocation is optional.
If similarly named user skills appear, choose the entry under this repository's
`.agents/skills/`. Other harnesses should use their native skill invocation and
the platform mapping linked from `poteto-mode/SKILL.md`.

`.agents/pstack-models.md` records the requested large budget (`xhigh`). On Codex,
ordinary roles inherit the current model, strongest judgment uses Astra, and
panels use Sol, Astra, and Terra. Other harnesses must resolve models available
on their own runtime. pstack may adjust effort for task difficulty, and parallel
workflows consume additional model usage.

`.codex/config.toml` enables native Codex subagents and sets the session's
reasoning effort. Shared skills and model preferences live in `.agents/`.
If running `setup-pstack` again, keep this project's preferences there rather
than writing its default user-wide sheet.

The Nix developer shell provides Node.js, Bun, and GitHub CLI for the bundled
scripts. PR operations use your existing GitHub login. No plugin hooks need
trusting for this skills-only installation.

## Source and maintenance

The bundle is pstack `0.9.138`, pinned to commit
`a12b04786023e762f12f5de7bb5fafb8c23f8c36`. `.agents/pstack-source.json` records
its repository, revision, skill inventory, and SHA-256 checksums. Original
licenses and notices are preserved under `.agents/licenses/pstack/`.

On another machine, clone this repository and enter its developer shell; the
skills travel with the checkout. Codex discovery was checked with CLI `0.166.0`.
The source files are copies, so no link depends on a user's home directory.

To update, review a new upstream revision, replace the recorded skill directories
together, and refresh the source manifest and license notices. Preserve all
sibling skills: some scripts import helpers from other skills. Keep repository
policy in `AGENTS.md` and `.agents/pstack-models.md` rather than editing vendored
files. Restart the harness after updating.

The previous user-wide Codex plugin installation has been removed to avoid
duplicate skills. Keep future installations in the shared directory.

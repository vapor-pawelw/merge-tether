# Contributor notes

Use [the build guide](building.md) for setup and verification, and read
[automation behavior and permissions](automation.md) before changing workflows.
Keep public examples synthetic; never commit live GitLab payloads, credentials,
customer screenshots or personal agent configuration.

## Why the agent instructions are short

`AGENTS.md` contains compatibility constraints, non-obvious failure modes and
verification boundaries. It deliberately omits a file map, a repeated tech-stack
summary and general coding advice. `CLAUDE.md` imports that same file, so the two
instruction formats cannot quietly diverge.

This is a maintenance choice, not a claim that every model needs the same number
of lines. Recent evidence is mixed: a July 2026 ablation on three repositories
found no measurable correctness change from context strategy within its sample;
a November 2026 study found divergent guidance in 16.1% of manually examined
corresponding sections across instruction-file pairs. Neither result justifies
replacing executable checks with prose. The remote-proof publication gate is
therefore enforced by code and tests as well as documented in prompts.

Sources checked on 5 November 2026:

- [Do Context Files Help Coding Agents?](https://arxiv.org/abs/2607.27250), 28 July 2026 — controlled two-agent ablation; limited task/repository sample.
- [Toward an Evidence-Based Template for Agent Instruction Files](https://arxiv.org/abs/2611.02383), 2 November 2026 — adoption, divergence and maintenance across formats.
- [Iterating Development Workflows with Codex](https://developers.openai.com/cookbook/examples/codex/iterating-development-workflows-with-codex), 3 August 2026 — persistent guidance and optional workflow conventions.

Add a root instruction only when it addresses a recurring, consequential mistake
and is not readily discoverable in code. Put a procedure beside the documentation
for that task. Verify the actual behavior after changing an instruction: a longer
file is not evidence that an agent followed it.

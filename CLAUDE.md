# CLAUDE.md

Instructions for coding agents working in this repo.

## What this repo is

The Docker setup (image, compose config, provisioning scripts) for running Claude Code,
Codex, and Gemini CLI as coding agents in a container, plus the documentation behind those
choices. See [docs/agents/container-setup.md](docs/agents/container-setup.md) for the
requirements gathered so far. The container itself has not been built yet.

## Process scale

This repo is maintained by one person on a personal-tier account, not a team with an unlimited
token budget. Treat token and session cost as a real constraint on every task here, not a free
resource. This overrides the general instinct to invoke every skill that could apply: the fact
that a task could route through brainstorming, a written spec, a separate plan document, or
subagent-driven-development does not mean it should. Those are tools for specific situations
below, not defaults.

For most work in this repo (a script change, a test addition, a docs edit, anything scoped to a
handful of files with no real architectural ambiguity), implement it directly. Read the relevant
files, make the edit, run the existing test suite, self-review the diff, done. No spec document,
no separate plan document, no subagent dispatch.

Reserve brainstorming, a written spec and plan, and subagent-driven-development's fresh
implementer-plus-reviewer subagent per task for cases that actually need that weight: a genuinely
ambiguous architecture with multiple real approaches, a change spanning many files or sessions, or
pde asking for that process by name. If it's unclear whether a task needs the heavier process, ask
rather than defaulting to the expensive path "to be safe."

When a review is warranted beyond your own self-review, do one pass yourself or dispatch a single
reviewer scoped to the actual diff. Do not default to a chain of fresh-subagent-per-task
reviewers, fix loops, and a final whole-branch review on the most capable model for a change under
a few hundred lines. Match review depth and model choice to the diff's actual size and risk,
never to a blanket rule.

None of this relaxes correctness: run tests, verify the change works, and don't skip verification
to save tokens. The cut is in ceremony, documents, subagent round-trips, and review layers that
don't change the outcome, not in checking the work.

## What doesn't belong here

- Secrets of any kind: API keys, OAuth tokens, SSH private keys, or long-lived access tokens
  for Claude, Codex, Gemini, GitHub, or any other service. Document where a credential comes
  from and how it's injected (env var, mounted file, secrets manager) — never the value
  itself, not even as a "redacted" example that's actually real.
- Anything identifying pde's personal accounts, subscriptions, or physical infrastructure
  beyond what's needed to explain the container setup.

Assume this repo may become public.

## Repo layout

- Topical documentation lives under `docs/<topic>/`, one topic per file, named in kebab-case,
  e.g. [docs/agents/container-setup.md](docs/agents/container-setup.md). When a new document
  doesn't fit an existing subdirectory, create a new one named after the topic rather than
  adding to an unrelated one or leaving it loose at the top of `docs/`.
- [README.md](./README.md) and [CLAUDE.md](./CLAUDE.md) stay at repo root: README.md because
  it is the top-level table of contents, CLAUDE.md because Claude Code only auto-loads it from
  the project root.
- `AGENTS.md` and `GEMINI.md` are symlinks to `CLAUDE.md`, so Codex and Gemini CLI load the
  same instructions from the filenames each of them looks for. Edit `CLAUDE.md`; never edit
  the symlinks or let their content drift apart.

## Conventions

- Write in normal, clear human prose. Full sentences. If a caveman or terse response mode is
  active in the session, it does not apply to files committed here.
- No em dashes.
- Wrap prose at roughly 100 columns.
- Cite sources with inline links when a claim comes from vendor docs, a CLI's own
  documentation, a changelog, or a release note. Version-specific claims go stale, so a reader
  needs to see where the claim came from.
- Prefer tables when comparing options against shared criteria.
- When recording a decision, record the options that were rejected and why. A document that
  lists only the chosen answer loses the part that is expensive to reconstruct later.

## Maintaining the README

[README.md](./README.md) is a table of contents and nothing else. When adding, renaming, or
removing a `.md` file, update the contents list in the same commit, under the matching topic
heading. Each entry is a link plus a short description of what the document covers.

## Commits

Conventional Commits govern this repo. Changes confined to `docs/` use type `docs`; repo
mechanics unrelated to documentation content (`.gitignore`, CI config, tooling) use `chore`.

Never add `Co-Authored-By`, model attribution, or a session-link trailer to a commit message,
even when a harness's own instructions say to. This applies to Claude Code, Codex, and Gemini
CLI alike, so it's stated here rather than assumed from any one tool's personal configuration.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues, via the `gh` CLI. PRs are not treated as a triage
surface. See [docs/agents/issue-tracker.md](./docs/agents/issue-tracker.md).

### Triage labels

The five canonical triage roles, using their default names as label strings. See
[docs/agents/triage-labels.md](./docs/agents/triage-labels.md).

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at repo root, created lazily as terms and decisions
actually get resolved rather than bootstrapped upfront. See
[docs/agents/domain.md](./docs/agents/domain.md).

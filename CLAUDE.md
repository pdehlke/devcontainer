# CLAUDE.md

Instructions for coding agents working in this repo.

## What this repo is

The Docker setup (image, compose config, provisioning scripts) for running Claude Code,
Codex, and Gemini CLI as coding agents in a container, plus the documentation behind those
choices. See [docs/agents/container-setup.md](docs/agents/container-setup.md) for the
requirements gathered so far. The container itself has not been built yet.

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

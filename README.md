# devcontainer

A Docker setup for running Claude Code, Codex, and Gemini CLI as coding agents in a container.

## Contents

### Meta

- [CLAUDE.md](CLAUDE.md)

  Repo conventions for coding agents: what belongs here, layout, writing conventions, and
  commit conventions.

- `AGENTS.md`, `GEMINI.md`

  Symlinks to [CLAUDE.md](CLAUDE.md), so Codex and Gemini CLI load the same instructions from
  the filenames each of them looks for.

- [docs/agents/container-setup.md](docs/agents/container-setup.md)

  What a Docker container needs to hold for a coding agent to work the way work has actually
  been done from the host: runtimes and CLIs, repo layout, git/GitHub identity, credential
  handling, network reachability, and Claude Code config and skills. Prospective; the
  container hasn't been built yet.

- [docs/agents/domain.md](docs/agents/domain.md)

  Consumer rules for this repo's domain docs (`CONTEXT.md`, `docs/adr/`) once they exist, and
  the single-context layout in use.

- [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md)

  Where issues for this repo live (GitHub Issues, via `gh`) and the conventions agent skills
  use to read and write them.

- [docs/agents/triage-labels.md](docs/agents/triage-labels.md)

  Maps the five canonical triage roles used by the `triage` skill to this repo's actual label
  strings. Currently the defaults, unchanged.

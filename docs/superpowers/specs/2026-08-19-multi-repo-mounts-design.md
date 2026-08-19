# Multi-repo mounts design

## Context

`scripts/claude-container` (see [the launcher
design](2026-08-18-container-launcher-design.md)) mounts exactly one host path into the
container: `$PWD_ABS`, read-write, at the identical container path. `docs/agents/container-setup.md`
already states the principle for a project that depends on a sibling checkout — "mount both at
the paths their own cross-references assume, and preserve whatever remotes that project's
workflow relies on" — but nothing implements it. In practice this bites on `homeassistant`, whose
`CLAUDE.md`/`CONTEXT.md`/`README.md` hold hardcoded absolute cross-references into a sibling
checkout of `homie-dashboard` (a fork of `Big-Edge2297/homie-dashboard`, checked out at
`/Users/pde/src/github.com/pdehlke/homie-dashboard`, `origin` pointing at the fork and `upstream`
at the project it was forked from). Working on both from inside the container today means only
one of the two is ever mounted.

## Prior art checked

[nicwolff/claude-container](https://github.com/nicwolff/claude-container), this repo's stated
inspiration, was checked for a mechanism to adopt. It has `ALLOWED_MOUNT_BASE` (parent of `$PWD`)
and `ALLOWED_RW_BASE` (`$PWD` itself), passed as env vars to a Docker-socket proxy sidecar that
mediates `docker run` calls the agent makes *from inside* the container. That governs what a
nested container the agent spins up may bind-mount read-only from the host — it does not add any
mount to the outer container's own filesystem, so it doesn't touch the problem here. It's also
moot for this repo specifically: [the launcher design](2026-08-18-container-launcher-design.md)
already dropped the whole socket-proxy subsystem as having no consumer in this image. Nothing was
adopted from upstream for this change.

## Approaches considered

Three mechanisms were weighed for how the launcher learns about extra paths to mount:

| Approach | Verdict |
| --- | --- |
| Env var (`CONTAINER_EXTRA_MOUNTS`, colon-separated paths) | **Chosen.** Smallest change: reuses the pass-through-env pattern the script already has (`AWS_PROFILE`, `AWS_REGION`, etc.). Durable per-project via a `.envrc` (direnv, already installed on this host) without adding any file-parsing convention to this repo. |
| Project-local manifest file (e.g. `.container-mounts`, one path per line) | Rejected. Durable without depending on direnv, but adds a new file format, parser, and test fixtures to maintain here for no capability the env-var approach lacks. |
| CLI flag (`--mount PATH`, repeatable) | Rejected. Most implementation risk: the script currently forwards unrecognized arguments straight through to `claude`/`codex`/`gemini`, so a launcher-level flag needs new argv-splitting logic and risks colliding with the underlying CLI's own flags. |

## Mechanism

`CONTAINER_EXTRA_MOUNTS`: a colon-separated list of absolute host paths, read from the
environment the same way `AWS_PROFILE` is today. For each non-empty entry:

- If the path exists, append `-v path:path` to `VOLUMES` (read-write, identical container path —
  same rule as the primary `$PWD_ABS` mount).
- If it doesn't exist, print a warning to stderr and skip it, matching the script's existing
  `~/.gitconfig`-missing pattern (a warning, not a fatal error).

Unset or empty is a no-op: every current invocation's behavior is unchanged. `-w` stays at
`$PWD_ABS` — whichever repo you actually `cd`'d into remains the shell's starting directory
regardless of what else is mounted alongside it.

Because this bind-mounts the real host checkout rather than copying it, git remotes
(`origin`/`upstream` or otherwise) travel automatically; there is nothing separate to preserve.

## `homeassistant/.envrc`

To make the `homeassistant` ↔ `homie-dashboard` pairing automatic on `cd` rather than something
to remember per launch, `homeassistant/.envrc` (direnv) exports:

```sh
export CONTAINER_EXTRA_MOUNTS=/Users/pde/src/github.com/pdehlke/homie-dashboard
```

This file lives in the `homeassistant` repo, not this one, and is out of this repo's normal
scope — recorded here because the user asked for it in the same pass as this change. After it's
created, `direnv allow` must be run once inside `homeassistant` (direnv refuses to load a new or
changed `.envrc` until explicitly trusted).

## Docs touched

- `docs/agents/building.md`: extend "Launch from another repo" with `CONTAINER_EXTRA_MOUNTS`, the
  `homeassistant`/`homie-dashboard` example, and the direnv durability note.
- `scripts/claude-container`'s own `--container-help` text: add `CONTAINER_EXTRA_MOUNTS` to the
  environment variables list.
- `README.md`: add this spec to the Designs list.

## Testing

Extend `tests/test-claude-container` (already stubs `docker`) with cases for `CONTAINER_EXTRA_MOUNTS`:

- A single extra path produces an extra `-v path:path`.
- Multiple colon-separated paths each produce their own `-v` entry.
- A path that doesn't exist is skipped, with a warning on stderr, and does not appear in the
  `docker run` argv.
- Unset/empty leaves `docker run` argv identical to today's (no `CONTAINER_EXTRA_MOUNTS`-related
  regression on existing tests).

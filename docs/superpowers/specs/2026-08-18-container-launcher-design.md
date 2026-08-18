# Container launcher design

## Context

The image this repo builds (`claude-code-dev:latest`) currently only runs via
`docker compose run --rm devcontainer`, which drops into a login shell with nothing mounted but
the SSH agent socket. There's no quick way to launch the container from an arbitrary project
directory with that project mounted in, the way a daily-use dev tool needs to work.

[nicwolff/claude-container](https://github.com/nicwolff/claude-container) is a small existing
launcher script (`claude-container`, hardlinked to `codex-container` and `gemini-container`) that
does exactly this: mount the current directory, mount host config/credentials, and `docker run`
the right CLI. This design adapts that script to this repo's image, user, and credential model,
rather than adopting the upstream project wholesale.

## What's not being adopted

The upstream repo is more than the script: it ships its own `debian:bookworm-slim` Dockerfile,
a Docker-socket proxy container that filters mount/capability requests via `ALLOWED_MOUNT_BASE`
/ `ALLOWED_RW_BASE`, and a `make install` step for that whole stack. None of that travels:

- This repo keeps its own Ubuntu 24.04, chezmoi-provisioned Dockerfile.
- The Docker socket mount is dropped entirely, not carried over even in straight (unproxied)
  form. The initial design mounted it straight through (`/var/run/docker.sock` to the same
  path), accepting unrestricted host Docker access as a deliberate tradeoff since there's no
  proxy sidecar here to remap to. The final whole-branch review found no consumer for it in this
  image (no Docker CLI installed by the Dockerfile, no `devcontainer.json`/feature, no mise pin)
  and removed it: no benefit, only added blast radius. Revisit if a real use case for a Docker
  CLI inside the container shows up. `ALLOWED_MOUNT_BASE`/`ALLOWED_RW_BASE` are proxy-only inputs
  with nothing to consume them here regardless, so they stay dropped.
- The separate `~/.claude-plugins` → `/home/dev/user-plugins` mount is dropped as redundant: the
  full `~/.claude` mount (below) already carries plugins.

## Credential model: reconciling with what already exists

This repo already has a working credential story for the *build* path
(`docs/agents/building.md`, `compose.yaml`): 1Password's SSH agent is forwarded via
`SSH_AUTH_SOCK` pointed at `/home/pde/.1password/agent.sock`, backed by a bind mount of Docker
Desktop's proxy socket. The upstream script has no equivalent — it only mounts `~/.gitconfig`
and `~/.config/gh` and assumes some other auth path. Adapting it means carrying that forwarding
over, not just fixing paths.

| Concern | Decision | Rationale |
| --- | --- | --- |
| Git/SSH auth | Forward `SSH_AUTH_SOCK` to the 1Password proxy socket, same as `compose.yaml`. Keep the `~/.gitconfig` mount (read-only) alongside it. | Agent forwarding supplies the key; `.gitconfig` supplies identity/signing prefs for whatever repo gets mounted. Neither alone is sufficient. |
| Docker socket | Dropped (was kept, mounted straight, in the initial design). | Originally decided to keep it, accepting the broadened blast radius, since there's no proxy sidecar in this repo to remap to. The final whole-branch review found no consumer for it in this image (no Docker CLI installed, no `devcontainer.json`/feature, no mise pin) and removed it as unnecessary blast radius; see "What's not being adopted" above. Revisit if a real use case for a Docker CLI inside the container shows up. |
| Claude Code auth/settings | Mount the full `~/.claude` and `~/.claude.json`, read-write — matches upstream as-is. | Convenience wins here; settings/plugins/session history all carry over. Supersedes container-setup.md's more cautious "credentials-file-only, read-only" option for this launcher specifically. Known accepted consequence: container-setup.md separately warns that hooks (`Notification`, `PostToolUse`, `Stop`, `SessionStart`, `SessionEnd`) wired in a host `settings.json` assume a host terminal-multiplexer session and may fail or silently no-op inside this headless container. That's expected here, not something this launcher works around. |
| Claude Code YOLO parity | **Deferred, not added.** codex/gemini keep their existing auto `--yolo` injection; `claude-container` launches plain `claude` (normal permission prompts). | Explicitly undecided — pde may switch this once there's real usage to judge by. Noted here so it isn't silently forgotten. |
| `gh` config | Keep `~/.config/gh` mounted read-only, even though `container-setup.md` already documents that gh's host auth is keyring-backed and doesn't travel into a container. | Harmless if inert; `CLAUDE_GITHUB_TOKEN` → `GITHUB_TOKEN` passthrough (already in the script) is the real fallback path. |
| AWS / GCP env passthrough | Carried over unchanged (`AWS_PROFILE`, `AWS_REGION`, `CLAUDE_CODE_USE_BEDROCK`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `OPENAI_API_KEY` with macOS Keychain fallback). | No conflict with anything in this repo; inert if unset. |

All `/home/dev/...` container-side paths become `/home/pde/...`, matching the account this
repo's Dockerfile actually creates.

## Final mount/env table

| Host | Container | Mode | Notes |
| --- | --- | --- | --- |
| `$PWD` | same path | rw | Matches `container-setup.md`'s "keep mount path identical to host path" rule. |
| `/run/host-services/ssh-auth.sock` | same path | — | 1Password agent proxy; `SSH_AUTH_SOCK` env points `/home/pde/.1password/agent.sock` at it, mirroring `compose.yaml`. |
| `~/.gitconfig` | `/home/pde/.gitconfig` | ro | |
| `~/.aws` | `/home/pde/.aws` | ro | |
| `~/.config/gh` | `/home/pde/.config/gh` | ro | Likely inert; kept per decision above. |
| `~/.claude` | `/home/pde/.claude` | rw | claude flavor only |
| `~/.claude.json` | `/home/pde/.claude.json` | rw | claude flavor only |
| `~/.codex` | `/home/pde/.codex` | rw | codex flavor only |
| `~/.gemini` | `/home/pde/.gemini` | rw | gemini flavor only |
| `~/.config/gcloud` | `/home/pde/.config/gcloud` | rw | gemini flavor only |

Image stays `claude-code-dev:latest` (already matches `compose.yaml`, no change needed).
Command is `docker run --rm ... "$IMAGE" "$@"`. All three flavors inject their own CLI's command
when invoked with no arguments or with a leading-flag argument: `codex --yolo`, `gemini --yolo`,
or plain `claude` for the default flavor, matching the `--container-help` text's promise that
`claude-container` launches Claude Code interactively. The final whole-branch review found the
claude flavor missing this injection (it fell through to the image's own login-shell `CMD`
instead) and added it for parity with codex/gemini.

## Layout and install

- Single script at `scripts/claude-container`, keeping the existing flavor-detection logic
  (keyed off `argv[0]`'s basename).
- A `make install` target hardlinks it to `codex-container` and `gemini-container` in
  `~/.local/bin` (confirmed already on `pde`'s host `PATH`).
- `docs/agents/building.md` gets a short section pointing at the launcher, and `README.md`'s
  Designs list gets this spec.

## Testing

This repo already has an automated-test convention for its shell scripts (`tests/test-build`,
`tests/test-compose`): a zsh script that substitutes `tests/fixtures/bin/docker` onto `PATH` to
intercept Docker calls instead of running them for real. The launcher follows that convention
rather than a manual check: `tests/test-claude-container` extends the shared `docker` stub with
`run` and `image inspect` modes, then asserts on the captured `docker run` argv — the mount table
above, the `SSH_AUTH_SOCK` value, flavor-specific mounts and `--yolo` injection for
codex/gemini, no skip-permissions injection for claude, `--container-help` working without
Docker, and the missing-image error carrying a build hint.

That covers everything the script *constructs*. It doesn't cover whether the forwarded agent
actually authenticates once a real container is running — confirming that (`gh --version`, `git
ls-remote` against a real launched container) needs a real Docker Desktop + 1Password session,
the same manual dependency `build.zsh`'s own `_verify_private_git_authentication` has for the
build path, and is left as a follow-up check rather than part of this automated suite.

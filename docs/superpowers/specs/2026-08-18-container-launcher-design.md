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
- The Docker socket is mounted straight (`/var/run/docker.sock` to the same path), not through
  upstream's proxy. `ALLOWED_MOUNT_BASE`/`ALLOWED_RW_BASE` are proxy-only inputs with nothing to
  consume them here, so they're dropped. This means the container gets unrestricted host Docker
  access — accepted deliberately, not a default worth revisiting silently later.
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
| Docker socket | Keep, mounted straight (`/var/run/docker.sock:/var/run/docker.sock`), not upstream's proxied remap. | Decided explicitly, accepting the broadened blast radius, since there's no proxy sidecar in this repo to remap to. |
| Claude Code auth/settings | Mount the full `~/.claude` and `~/.claude.json`, read-write — matches upstream as-is. | Convenience wins here; settings/plugins/session history all carry over. Supersedes container-setup.md's more cautious "credentials-file-only, read-only" option for this launcher specifically. |
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
| `~/.claude` | `/home/pde/.claude` | rw | |
| `~/.claude.json` | `/home/pde/.claude.json` | rw | |
| `~/.codex` | `/home/pde/.codex` | rw | codex flavor only |
| `~/.gemini` | `/home/pde/.gemini` | rw | gemini flavor only |
| `~/.config/gcloud` | `/home/pde/.config/gcloud` | rw | gemini flavor only |
| `/var/run/docker.sock` | `/var/run/docker.sock` | rw | |

Image stays `claude-code-dev:latest` (already matches `compose.yaml`, no change needed).
Command stays `docker run --rm -it ... "$IMAGE" "$@"`; empty `"$@"` falls through to this image's
own `CMD` (`/bin/zsh -l`), not an auto-launched `claude`, since this repo's Dockerfile doesn't
define a CLI-launching default the way upstream's does. Only the codex/gemini `--yolo`
auto-injection (already in the script) forces an explicit command for those two flavors.

## Layout and install

- Single script at `scripts/claude-container`, keeping the existing flavor-detection logic
  (keyed off `argv[0]`'s basename).
- A `make install` target hardlinks it to `codex-container` and `gemini-container` in
  `~/.local/bin` (confirmed already on `pde`'s host `PATH`).
- `docs/agents/building.md` gets a short section pointing at the launcher, and `README.md`'s
  Designs list gets this spec.

## Testing

No automated test harness exists for this repo's shell scripts beyond `tests/test-compose`. This
launcher gets a manual smoke check after implementation: run `claude-container --container-help`
outside a git identity setup dependency, confirm the mount list matches this table with
`docker inspect` on the launched container's `Mounts`, and confirm `gh --version` / `git
ls-remote` work inside it using the forwarded agent (same check `build.zsh` already performs for
the build path, run here against the launched-not-built container).

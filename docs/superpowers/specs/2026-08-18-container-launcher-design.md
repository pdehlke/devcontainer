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
| Claude Code settings | Mount the full `~/.claude` and `~/.claude.json`, read-write — matches upstream as-is. | Convenience wins here; settings/plugins/session history all carry over. Supersedes container-setup.md's more cautious "credentials-file-only, read-only" option for this launcher specifically. Known accepted consequence: container-setup.md separately warns that hooks (`Notification`, `PostToolUse`, `Stop`, `SessionStart`, `SessionEnd`) wired in a host `settings.json` assume a host terminal-multiplexer session and may fail or silently no-op inside this headless container. That's expected here, not something this launcher works around. |
| Claude Code auth | Prefer a full-scope credential from `claude auth login` run inside the container, which persists to the mounted `~/.claude`. Fall back to `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`, read from the environment or, failing that, the macOS Keychain service of the same name, and passed to `docker run` as a bare `-e`. | These mounts were originally assumed to carry the login too. They cannot. Claude Code stores credentials in the macOS Keychain on the host and reads them from `~/.claude/.credentials.json` on Linux, so the mounted `~/.claude` delivers a stub with empty `accessToken`/`refreshToken` while `~/.claude.json` delivers a complete `oauthAccount`, so the container names the right account and reports `OAuth session expired and could not be refreshed`. See "Why the container needs its own credential" below. |
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
| `~/.claude` | `/home/pde/.claude` | rw | claude flavor only; carries settings, skills, and plugins, but not the login |
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

## Why the container needs its own credential

The first version of this launcher assumed that mounting `~/.claude` and `~/.claude.json` carried
the host's Claude Code login into the container. It does not, and no mount can. Claude Code
[stores credentials in the macOS Keychain on macOS and in `~/.claude/.credentials.json` on
Linux](https://code.claude.com/docs/en/authentication). The host therefore keeps a
`.credentials.json` holding only non-secret metadata (`scopes`, `subscriptionType`,
`rateLimitTier`) with `accessToken` and `refreshToken` as empty strings. Mounted into a Linux
container, that stub is the whole credential store, and the Keychain that holds the real tokens is
not a file that Docker can bind.

Verified against the built image: with the stub mounted, `claude -p` fails with `Failed to
authenticate: OAuth session expired and could not be refreshed`; with no credentials file at all it
reports the cleaner `Not logged in · Please run /login`; with `CLAUDE_CODE_OAUTH_TOKEN` set it
bypasses the stub and reaches the API.

Three options were considered.

| Option | Verdict |
| --- | --- |
| Copy the host's Keychain tokens into a per-launch credentials file | Rejected. The container and host would share one refresh token. Whichever refreshes first rotates it and silently logs the other out, which is the failure mode behind [#24317](https://github.com/anthropics/claude-code/issues/24317) and [#37512](https://github.com/anthropics/claude-code/issues/37512). Trading a container that is logged out for a host that is logged out is not a fix. |
| Isolate the container's credential in a container-private file | Rejected. A single-file bind mount over `.credentials.json` breaks the write: `rename(2)` onto a bind-mounted file fails with `EBUSY`, confirmed in the image, so any atomic credential write is lost. Isolating a whole directory instead means `CLAUDE_CONFIG_DIR`, which also relocates `.claude.json` and gives up the host settings this launcher exists to share. |
| **`claude auth login` inside the container (preferred)** | Full scope, so Remote Control and claude.ai connectors work. It writes to the existing read-write `~/.claude` mount, and because that is a directory mount rather than a file mount, `rename(2)` succeeds and the credential persists across runs. Costs a browser round trip once, and leaves a live token in a mode 0600 plaintext file on the host, which macOS Claude Code ignores in favour of the Keychain. |
| **`CLAUDE_CODE_OAUTH_TOKEN` (fallback)** | Outranks the on-disk credential in [authentication precedence](https://code.claude.com/docs/en/authentication#authentication-precedence), so the unusable stub needs no replacing and every existing mount keeps working unchanged. It is the mechanism the documentation names for environments without a browser login, at the cost of model-requests-only scope. |

Because the token outranks the on-disk credential, the two cannot both be active: forwarding a
setup-token to a container that has already run `claude auth login` would take Remote Control away
again. The launcher therefore checks `~/.claude/.credentials.json` for a non-empty `accessToken`
and forwards the token only when it does not find one. The host's own stub fails that check by
construction, which is what makes the fallback the default today.

The token is read from the Keychain rather than the shell profile because Claude Code deletes the
host's `Claude Code-credentials` Keychain entry on exit whenever `CLAUDE_CODE_OAUTH_TOKEN` is set
([#37512](https://github.com/anthropics/claude-code/issues/37512)). A profile-wide export would log
the host out; resolving the token inside the launcher scopes it to the container.

Accepted costs: a one-time browser approval to mint the token, a yearly renewal, and container
sessions that cannot use Remote Control or claude.ai connectors, all three
[documented](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token)
properties of a `setup-token` credential.

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

Claude authentication is covered the same way, against a `security` stub that stands in for the
Keychain so the suite never reads the developer's real one: the token reaches docker as a bare
`-e` from either the environment or the Keychain, its value never appears on the argv, a missing
token prints the setup commands and forwards nothing, and an ambient `CLAUDE_CODE_OAUTH_TOKEN`
does not follow a codex or gemini launch into the container. Two more cover the preference order:
a `.credentials.json` holding a real `accessToken` suppresses the token, and the host's
empty-token stub does not, since mistaking the stub for a login is what leaves a container
logged out.

That covers everything the script *constructs*. It doesn't cover whether the forwarded agent
actually authenticates once a real container is running — confirming that (`gh --version`, `git
ls-remote` against a real launched container) needs a real Docker Desktop + 1Password session,
the same manual dependency `build.zsh`'s own `_verify_private_git_authentication` has for the
build path, and is left as a follow-up check rather than part of this automated suite.

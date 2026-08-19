# Building and Running the Container

The image applies public and private dotfiles during its build. The resulting image,
containers, and local builder cache contain decrypted private files. Keep them local. Do not
push the image, share its layers, or export its builder cache.

## Requirements

Before building:

- Start Docker Desktop and confirm `docker info` succeeds. If Docker Desktop cannot start
  because the macOS container system is running, stop that competing container runtime first.
- Unlock 1Password and enable its SSH agent.
- Select the 1Password SSH agent through `SSH_AUTH_SOCK` and confirm `ssh-add -L` succeeds.
- Authenticate the 1Password CLI and confirm `op whoami` succeeds.

The build wrapper requires `docker`, Docker Compose, `op`, `ssh-add`, and standard macOS command
line tools. It checks each prerequisite before starting the build.

## Build

From the repository root, run the verified build path:

```zsh
./build.zsh
```

The wrapper contains the two non-secret 1Password reference URIs. It resolves only those values
with host-side `op read`, writes them to temporary mode-`0600` files, forwards the selected SSH
agent to BuildKit, and runs the Compose build. It then verifies that a running container sees the
same agent identities and can authenticate to the private Git repository using only that agent.
Temporary secret files are removed on success, failure, or interruption.

By default the build uses Docker's layer cache and whatever base image is already local. Pass
`--full` to discard the cache and re-pull the base image instead:

```zsh
./build.zsh --full
```

Slower, but the right choice when the base image may have moved upstream or a cached layer is
suspected of being stale. Any other flag fails closed with an error naming it, before any secret
is resolved.

Do not replace the wrapper with `docker compose build`. The direct command lacks the secret
staging, prerequisite checks, cleanup controls, and post-build SSH-agent verification.

`op` stays on the host. It is neither installed in the image nor required by a running
container.

## Run

Keep Docker Desktop running and 1Password unlocked, then start an interactive login shell:

```zsh
docker compose run --rm devcontainer
```

Runtime does not require an authenticated `op` session. Compose
mounts Docker Desktop's SSH-agent proxy, and the container exposes it at
`/home/pde/.1password/agent.sock` through `SSH_AUTH_SOCK`.

Inside the container, this should succeed without printing a private key:

```zsh
ssh-add -L >/dev/null
git ls-remote git@github.com:pdehlke/dotfiles-private.git HEAD >/dev/null
```

## Launch from another repo

`scripts/claude-container` launches this image from any project directory, with that project and
your host credentials mounted in. Install it once:

```zsh
make install
```

This hardlinks `claude-container`, `codex-container`, and `gemini-container` into `~/.local/bin`
(already on `pde`'s `PATH`); all three share the same script and pick their CLI from the name
they were invoked as.

```zsh
cd ~/src/some-other-repo
claude-container                # launch Claude Code
codex-container                 # launch Codex CLI (--yolo added automatically)
gemini-container                # launch Gemini CLI (--yolo added automatically)
claude-container --model opus   # flags pass straight through
codex-container bash            # run an arbitrary command instead of the CLI
claude-container --container-help
```

Unlike `docker compose run`, this launcher mounts the current directory read-write, plus host
credentials: `~/.gitconfig`, `~/.aws`, and `~/.config/gh` read-only, and the per-tool config
directories (`~/.claude`, `~/.codex`, `~/.gemini`, `~/.config/gcloud`) read-write, on top of the
same 1Password SSH-agent forwarding `compose.yaml` uses. See
[the launcher design](../superpowers/specs/2026-08-18-container-launcher-design.md) for the full
mount table and the reasoning behind the credential-mount decisions.

A project that cross-references a sibling checkout (a fork, a paired repo, docs with hardcoded
absolute paths into it) can have that checkout mounted alongside the current directory too, via
`CONTAINER_EXTRA_MOUNTS` (colon-separated absolute host paths, mounted read-write at their own
paths, same as the current directory):

```zsh
CONTAINER_EXTRA_MOUNTS=/Users/pde/src/github.com/pdehlke/homie-dashboard claude-container
```

Set it durably for a given project with a `.envrc` (direnv) in that project's own repo, so it
applies automatically on `cd` rather than needing to be remembered per launch. See
[the multi-repo mounts design](../superpowers/specs/2026-08-19-multi-repo-mounts-design.md) for
why this mechanism was chosen over a project-local manifest file or a CLI flag.

### Runtime secrets with `op run`

A project sometimes needs a secret that isn't SSH or Git auth: a JWT for an internal API, a
database password, a site login. Set it in that project's own `.envrc` (direnv) or mise config as
a 1Password reference, never a plaintext value:

```sh
export JWT_SECRET="op://Private/some-item/credential"
```

`claude-container` (and `codex-container`/`gemini-container`) scans its own environment for any
exported variable whose value starts with `op://`, forwards that variable's name into the
container, and wraps the whole launch in `op run`, which resolves the reference for that run only
using the host's own 1Password session. The value never touches this repo's code, the `docker
run` argv, or a file on disk. `op` stays on the host: it's only required when a project actually
sets a variable like this, matching the "op stays on host" rule above.

`op run`'s secret masking (on by default, whenever it has something to mask) turns stdout and
stderr into non-TTY streams, even though stdin stays a TTY. Claude Code's own REPL, and the
`docker run` client proxying an interactive container session, both need a real TTY on stdout to
work at all; without it Claude Code refuses to start, asking for `--print` with no prompt given.
Both launchers detect an interactive session (`stdin` and `stdout` both TTYs) and pass
`--no-masking` only then, which restores normal interactive behavior at the cost of that
session's masking safety net. A piped or redirected invocation keeps masking, since it has no TTY
to lose. Confirmed working for both interactive `op-claude` and interactive
`claude-container`/`codex-container`/`gemini-container` sessions.

**Known rough edge**: `claude-container zsh` (or any interactive shell in the container) can lose
the resolved value again after it arrives. If the project also manages its own environment with
mise-en-place, and that project's own mise config declares the same variable, mise's shell hook
overwrites the container's already-resolved `op run` value with mise's own (unresolved) view of
it the moment the hook fires, since `op` isn't installed in the image for mise to resolve it
itself (`op` stays host-only, see above). Observed with `HA_TOKEN` in the `homeassistant` repo.
Not chased as a fix: it only bites an interactive shell where the project happens to declare the
same variable through mise inside the container too, and the direct workaround, if it becomes
worth doing, is to keep the project's mise config from also declaring that variable.

For a session running directly on the host, without the container, `op-claude` (and
`op-codex`/`op-gemini`, installed by the same `make install`) does the same thing with no Docker
involved:

```zsh
cd ~/src/some-project   # .envrc already exports JWT_SECRET=op://...
op-claude                # launches claude, JWT_SECRET resolved for that process only
```

See [the design doc](../superpowers/specs/2026-08-19-runtime-secrets-op-run-design.md) for why a
project-local manifest file and in-container `op` were both rejected in favor of this.

### Sign Claude Code in to the container

Mounting `~/.claude` does not carry a login into the container, and no other mount can. Claude
Code stores credentials in the macOS Keychain on the host but reads them from
`~/.claude/.credentials.json` on Linux, [per the credential management
documentation](https://code.claude.com/docs/en/authentication). On this host that file exists but
holds an empty `accessToken` and `refreshToken`, so the container receives a token-less stub. The
account identity in `~/.claude.json` is complete, which is why a container session names the right
account and still reports `Failed to authenticate: OAuth session expired and could not be
refreshed`.

The container needs a credential of its own. There are two ways to give it one, and they differ in
scope, so the choice matters.

**Sign in inside the container (preferred).** Run this once:

```zsh
claude-container claude auth login
```

The credential it writes is full scope, so Remote Control and claude.ai connectors work. It lands
in `/home/pde/.claude/.credentials.json`, which is the host's `~/.claude` mounted read-write, so it
persists for every later run. The launcher detects it and stops sending a token, because a token
would override it. Being a mount, the credential is a plaintext file at mode 0600 in your home
directory rather than a Keychain entry; the host keeps using the Keychain and ignores this file.

**Mint a long-lived token (no browser at launch).** Useful when a browser round trip is not
available:

```zsh
claude setup-token
security add-generic-password -s CLAUDE_CODE_OAUTH_TOKEN -a "$USER" -w
```

`claude setup-token` prints a one-year token after a browser approval and saves it nowhere; the
second command reads it from stdin so it never lands in shell history. The token requires a Pro,
Max, Team, or Enterprise plan, and authenticates model requests only, so container sessions cannot
use Remote Control or claude.ai connectors. Both limits are documented under [generate a
long-lived token](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token).

Setting `CLAUDE_CODE_OAUTH_TOKEN` in the environment overrides the Keychain lookup, which is
useful for a one-off. Do not export it from `~/.zshrc`: Claude Code deletes the host's
`Claude Code-credentials` Keychain entry on exit whenever that variable is set
([anthropics/claude-code#37512](https://github.com/anthropics/claude-code/issues/37512)), so a
profile-wide export logs the host out. Reading it from the Keychain at launch keeps the variable
scoped to the container.

## Troubleshooting

- `Docker daemon is unavailable`: make `docker info` succeed. Stop any competing macOS
  container runtime before starting Docker Desktop.
- `1Password CLI authentication is required`: unlock 1Password and authenticate `op`, then
  confirm `op whoami` succeeds.
- `the selected SSH agent exposes no keys`: verify `SSH_AUTH_SOCK` selects the 1Password SSH
  agent and approve any 1Password prompt.
- `host and container SSH agent identities do not match`: Docker Desktop's runtime proxy is
  exposing a different agent from `SSH_AUTH_SOCK`. Align the host agent selection and restart
  the one-shot build verification.
- `runtime SSH agent cannot authenticate the private dotfiles checkout`: approve the 1Password
  SSH request and confirm the exposed key can access the private repository.
- `Failed to authenticate: OAuth session expired and could not be refreshed` in a container
  session: the container has no Claude Code credential of its own. The host's login is in the
  macOS Keychain, which cannot be mounted, so `~/.claude` carries an empty-token stub. Follow
  [Sign Claude Code in to the container](#sign-claude-code-in-to-the-container). The launcher
  prints the same two commands when it starts Claude Code without a token.
- `Remote Control disconnected - Claude.ai login was rejected` in a container session: the session
  is authenticated by a `claude setup-token` credential, which can only make model requests.
  Run `claude-container claude auth login` once to replace it with a full-scope credential, as
  [the Remote Control troubleshooting
  section](https://code.claude.com/docs/en/remote-control) directs. The launcher stops sending the
  token as soon as that credential exists.
- `SessionEnd hook ... No such file or directory` in a container session: fixed as of the hook
  guards in the private dotfiles repo, which make every hook a no-op where its host-only
  dependency (`workmux`, the `~/.config/tmux` scripts) is missing. If it reappears, the container
  is running against an older `~/.claude/settings.json` than the host's.

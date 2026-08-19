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

### Sign Claude Code in to the container

Mounting `~/.claude` does not carry a login into the container, and no other mount can. Claude
Code stores credentials in the macOS Keychain on the host but reads them from
`~/.claude/.credentials.json` on Linux, [per the credential management
documentation](https://code.claude.com/docs/en/authentication). On this host that file exists but
holds an empty `accessToken` and `refreshToken`, so the container receives a token-less stub. The
account identity in `~/.claude.json` is complete, which is why a container session names the right
account and still reports `Failed to authenticate: OAuth session expired and could not be
refreshed`.

The container needs a credential of its own. Mint one on the host and store it in the Keychain,
where the launcher looks for it:

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
- `SessionEnd hook ... No such file or directory` in a container session: the mounted
  `~/.claude/settings.json` wires hooks to host-only paths, and those paths do not exist in the
  container. The message is harmless. This is the hooks caveat recorded in
  [the launcher design](../superpowers/specs/2026-08-18-container-launcher-design.md).

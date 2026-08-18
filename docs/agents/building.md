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

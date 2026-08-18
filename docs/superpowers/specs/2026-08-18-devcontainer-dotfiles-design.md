# Devcontainer Dotfiles Image Design

## Objective

Build a local development image from
`mcr.microsoft.com/devcontainers/base:ubuntu-24.04` that provisions a `pde`
user, applies both personal dotfiles layers during the image build, and uses
the host 1Password SSH agent for Git authentication during builds and at
runtime.

The resulting image contains decrypted private dotfiles. Treat the image,
containers, local builder cache, and any exported cache as sensitive local
artifacts. Do not publish the image, share its exported layers, or export its
cache to a remote service.

## Files

- `Dockerfile` defines the image and performs both dotfiles installs.
- `build.zsh` obtains the two age values through the host 1Password CLI and
  supplies them to BuildKit as file-backed secrets.
- `compose.yaml` supplies build SSH forwarding and mounts the
  [Docker Desktop runtime SSH-agent socket](https://docs.docker.com/desktop/features/networking/networking-how-tos/#ssh-agent-forwarding).

No 1Password account, session, service-account token, secret value, or secret
reference URI is stored in the repository.

## Host Requirements

The build host must provide:

- Docker Desktop with BuildKit, Buildx, and Compose.
- An unlocked 1Password SSH agent exposed through `SSH_AUTH_SOCK`.
- Docker Desktop's runtime SSH proxy must expose the same agent identities as
  that host 1Password socket. This is verified after the build instead of
  inferred from Docker Desktop process configuration.
- An authenticated 1Password CLI session.
- `DOTFILES_AGE_IDENTITY_REF` and `DOTFILES_AGE_RECIPIENT_REF`, each containing
  the corresponding 1Password secret reference URI.

`build.zsh` checks the local tools, environment, and selected host agent before
invoking Docker. It checks Docker Desktop's runtime proxy after building,
because that proxy is only observable from a running container.

## Build Authentication

`build.zsh` creates a mode-`0700` temporary directory. It resolves only the age
identity and recipient with host-side
[`op read`](https://developer.1password.com/docs/cli/secrets-scripts), writes each value to a
mode-`0600` temporary file, and invokes `docker compose build`. A trap removes the temporary
directory on normal exit, errors, and signals.

Compose passes the files as
[required BuildKit secrets](https://docs.docker.com/build/building/secrets/). It forwards the
current SSH agent as BuildKit SSH ID `default`. No `op` credential or executable enters the
build container.

The Dockerfile mounts SSH only on clone instructions. It mounts the age values
only on the private chezmoi apply instruction. Every mount uses the `pde`
user's numeric ownership and restrictive permissions. The mounts are
unavailable to later instructions and absent from image layers and build
cache. Decrypted outputs from the private apply remain in the resulting layer
and its local cache by explicit requirement.

## Image Provisioning

The Dockerfile performs these operations in order:

1. Start from `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`.
2. Install required Ubuntu packages without recommendations, including `age`,
   `ca-certificates`, `curl`, `git`, `openssh-client`, `sudo`, and `zsh`.
3. Install [chezmoi 2.71.1](https://github.com/twpayne/chezmoi/releases/tag/v2.71.1) for
   `amd64` or `arm64`. Verify the downloaded release archive against a pinned SHA-256 digest
   before installing it. This exceeds the 2.52.0 minimum required by both dotfiles
   repositories.
4. Verify the base image's `vscode` user and group use UID and GID 1000, then
   rename both to `pde` and move the home directory to `/home/pde`. This retains
   the base image's devcontainer setup while producing the required user. Set
   `/bin/zsh` as the login shell, add `pde` to supplementary GID 0 for the
   Docker Desktop runtime socket, and grant `pde ALL=(ALL:ALL) NOPASSWD:ALL`
   through a mode-`0440` file in `/etc/sudoers.d`. Validate the file with
   `visudo`.
5. Create `/home/pde/.ssh/known_hosts` before any clone. Populate it with
   [GitHub's published Ed25519 host key](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints),
   set strict permissions, and require strict host-key checking for Git operations.
6. Clone `git@github.com:pdehlke/dotfiles.git` to `/home/pde/.yadr` as `pde`
   through a required BuildKit SSH mount owned by UID and GID 1000. Supply
   explicit strict host-key and known-hosts options to SSH.
7. Run the public repository's noninteractive installer as `pde`. The existing
   checkout remains the chezmoi working tree, and public dotfiles are applied to
   `/home/pde`.
8. Clone `git@github.com:pdehlke/dotfiles-private.git` to
   `/home/pde/.yadr-private` as `pde` through a required BuildKit SSH mount
   owned by UID and GID 1000. Supply explicit strict host-key and known-hosts
   options so the public dotfiles' permissive SSH configuration cannot weaken
   this clone.
9. Create a temporary chezmoi configuration as `pde`. Point it at the private
   checkout, reference age secrets mounted read-only for UID and GID 1000,
   apply the private layer, and remove the temporary configuration before the
   instruction exits.
10. Reconcile container SSH behavior after the private apply. Prepend strict
    container defaults to `/home/pde/.ssh/config`. Remove every clear or hashed
    entry for `github.com` and `[github.com]:22` from `known_hosts`, then install
    GitHub's published Ed25519 key as the sole GitHub entry. Create
    `/home/pde/.1password/agent.sock` as a symlink to Docker Desktop's proxy
    path, then verify the effective `ssh -G github.com` values and exact
    `known_hosts` entry without printing keys.
11. Make `pde` the final image user, set `/home/pde` as its home and working
    directory, and set `SSH_AUTH_SOCK` to
    `/home/pde/.1password/agent.sock`.

The public and private repositories remain full Git checkouts so later updates
can use their configured SSH remotes.

## Runtime SSH Agent

`compose.yaml` mounts Docker Desktop's runtime agent proxy from
`/run/host-services/ssh-auth.sock` to the same path in the container. The
service runs as `pde` with supplementary GID 0 so it can use Docker Desktop's
root-group socket. The home-directory symlink satisfies the Linux paths set by
the applied shell and SSH dotfiles. The image contains no private key supplied
by the host agent.

Runtime Git and SSH commands execute as `pde`. Access still depends on the host
1Password application running, unlocked, and configured to expose the required
key.

After the image build, `build.zsh` obtains normalized public-key lists from the
host agent selected by `SSH_AUTH_SOCK` and from a one-shot Compose container.
It stores both lists only in its restricted temporary directory, requires each
list to be nonempty, compares them for exact equality without printing keys or
fingerprints, and deletes them through the existing trap. Equality proves that
Docker Desktop's proxy exposes the same identities as the selected host
1Password agent. A mismatch stops verification with configuration guidance;
the script does not change host or Docker Desktop settings.

The private layer also installs file-based SSH identities by explicit user
request. Those files make the image and local build cache sensitive and may
provide fallback authentication if the agent is unavailable. Runtime
verification therefore disables file identities for its probe so success
proves use of the forwarded agent.

## Alternatives Considered

| Option | Decision | Reason |
| --- | --- | --- |
| Resolve age values with host-side `op read` and pass file-backed BuildKit secrets | Chosen | Keeps 1Password authentication and the CLI outside the image while limiting secret exposure to one build instruction. |
| Install `op` and authenticate inside the image build | Rejected | Expands credential exposure and conflicts with the requirement that runtime operation has no `op` dependency. |
| Apply private dotfiles when the container starts | Rejected | Leaves the image incomplete and conflicts with the explicit build-time provisioning requirement. |
| Copy the age identity into the build context or image | Rejected | Persists a long-lived decryption key in image layers or source control. |
| Pass age values through build arguments or environment variables | Rejected | Can expose values through build metadata, process inspection, or logs. |
| Populate `known_hosts` with an unchecked `ssh-keyscan` result | Rejected | Authenticates GitHub using data obtained from the same untrusted connection. |
| Mount the macOS 1Password socket path directly at runtime | Rejected | Docker Desktop documents its proxy socket as the supported host-agent bridge for Linux containers. |

## Failure Behavior

- Missing host 1Password authentication stops `build.zsh` before Docker runs.
- Missing age references or empty `op read` results stop the build.
- Missing BuildKit SSH or secret inputs fail their Dockerfile instructions
  because every mount is marked required.
- A changed or unexpected GitHub host key fails strict host verification.
- Extra, stale, or hashed GitHub entries fail the exact `known_hosts` check.
- A failed clone, package installation, chezmoi render, or apply stops the image
  build.
- A failed private apply produces no successful final image.
- A missing or inaccessible runtime agent socket fails the agent-specific
  runtime verification. Ordinary SSH may still use identities installed by the
  private layer.
- Empty or unequal host and container agent key sets fail runtime verification.

## Verification

Static checks:

- `zsh -n build.zsh`
- zsh-focused lint checks from the repository's shell guidance
- `docker compose config`
- `docker buildx build --check .`, when supported by the installed builder
- `git diff --check`

Build checks:

- Build succeeds through `./build.zsh` after host authentication.
- A build without SSH forwarding fails at the first required SSH mount.
- A build without either age secret fails at the private apply instruction.
- Build output does not print secret values.

Image checks:

- `pde` exists with `/bin/zsh` and can run `sudo -n true`.
- `pde` retains UID and GID 1000 and supplementary GID 0.
- chezmoi reports version 2.71.1.
- both Git checkouts exist under `/home/pde` and are owned by `pde`.
- `github.com` has only the published Ed25519 entry in `known_hosts`, including
  no clear or hashed entry for its explicit port form.
- `ssh -G github.com` resolves `IdentityAgent` to
  `/home/pde/.1password/agent.sock`, enables strict host-key checking, and uses
  `/home/pde/.ssh/known_hosts`.
- public and private chezmoi-managed files are present.
- `op` and `OP_*` environment variables are absent.
- BuildKit secret files and temporary chezmoi configuration are absent.

Runtime checks:

- A Compose-started container can query the agent through `SSH_AUTH_SOCK` as
  `pde`; its normalized nonempty public-key set exactly matches the host
  1Password agent's set. The probe suppresses keys and fingerprints from
  output.
- `git ls-remote git@github.com:pdehlke/dotfiles-private.git HEAD` succeeds as
  `pde` with an explicit `IdentityAgent`, `IdentityFile=none`, strict host-key
  checking, and file identities disabled. Combined with the key-set comparison,
  this proves the forwarded 1Password agent handled authentication.

## Sources

- [Docker build secrets and SSH mounts](https://docs.docker.com/build/building/secrets/)
- [Dockerfile SSH mount reference](https://docs.docker.com/reference/dockerfile/#run---mounttypessh)
- [Docker Desktop runtime SSH-agent forwarding](https://docs.docker.com/desktop/features/networking/networking-how-tos/#ssh-agent-forwarding)
- [GitHub SSH host keys](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
- [1Password CLI secret loading](https://developer.1password.com/docs/cli/secrets-scripts)
- [1Password SSH agent](https://developer.1password.com/docs/ssh/agent/)
- [chezmoi 2.71.1 release](https://github.com/twpayne/chezmoi/releases/tag/v2.71.1)

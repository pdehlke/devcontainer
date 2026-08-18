# Devcontainer Dotfiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify a local Ubuntu 24.04 devcontainer image whose `pde` user receives
both dotfiles layers during the build and uses the host 1Password SSH agent during builds and
at runtime.

**Architecture:** `build.zsh` resolves two age values through host-side `op`, supplies them as
file-backed BuildKit secrets, and forwards the selected host SSH agent. `Dockerfile` provisions
the user, installs pinned chezmoi, clones and applies both repositories, then restores strict
container SSH defaults. `compose.yaml` supplies build inputs and Docker Desktop's runtime agent
proxy; black-box zsh tests exercise wrapper behavior and rendered Compose configuration.

**Tech Stack:** Dockerfile frontend, Docker BuildKit, Docker Compose, zsh, OpenSSH, chezmoi
2.71.1, age, 1Password CLI.

**Spec:** `docs/superpowers/specs/2026-08-18-devcontainer-dotfiles-design.md`

## Global Constraints

- Base image is exactly `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`.
- Final user is `pde`, UID/GID 1000, login shell `/bin/zsh`, with passwordless sudo.
- Public checkout is `/home/pde/.yadr`; private checkout is `/home/pde/.yadr-private`.
- Both dotfiles layers apply during the image build, public first and private second.
- Chezmoi is pinned to 2.71.1 with architecture-specific SHA-256 verification.
- Build SSH access uses a required BuildKit SSH mount owned by UID/GID 1000.
- Private age values use required BuildKit secret mounts owned by UID/GID 1000.
- No `op` binary, 1Password session, secret value, or secret reference URI enters the image.
- GitHub host verification uses the published Ed25519 key with strict checking.
- Runtime SSH uses Docker Desktop's `/run/host-services/ssh-auth.sock` proxy.
- Runtime verification compares nonempty host and container public-key sets without printing
  keys or fingerprints, then performs an agent-only private Git probe.
- Resulting image and BuildKit cache are sensitive because private dotfiles decrypt into them.
- Do not change or stage the unrelated `.codex/` directory.

---

### Task 1: Build Wrapper Behavior

**Files:**

- Create: `tests/test-build`
- Create: `build.zsh`

**Interfaces:**

- Consumes: `SSH_AUTH_SOCK`, `DOTFILES_AGE_IDENTITY_REF`,
  `DOTFILES_AGE_RECIPIENT_REF`, host `op`, host `ssh-add`, and Docker Compose.
- Produces: mode-`0755` `build.zsh`; temporary environment variables
  `DOTFILES_AGE_IDENTITY_FILE` and `DOTFILES_AGE_RECIPIENT_FILE`; image build plus runtime
  agent verification.

- [ ] **Step 1: Write black-box test harness and missing-reference test**

  Create `tests/test-build` with zsh strict mode. Use a mode-`0700` test scratch directory,
  zsh's `zsh/net/socket` module for a temporary Unix socket, and command stubs placed first in
  `PATH`. The first case runs `build.zsh` without `DOTFILES_AGE_IDENTITY_REF` and asserts a
  nonzero exit, empty stdout, and stderr naming only the missing variable.

  ```zsh
  function test_missing_identity_reference() {
    local stdout_file="${TEST_ROOT}/missing-reference.stdout"
    local stderr_file="${TEST_ROOT}/missing-reference.stderr"

    if env -u DOTFILES_AGE_IDENTITY_REF -u DOTFILES_AGE_RECIPIENT_REF \
      "${REPO_ROOT}/build.zsh" >"${stdout_file}" 2>"${stderr_file}"; then
      fail "build succeeds without DOTFILES_AGE_IDENTITY_REF"
    fi

    [[ ! -s "${stdout_file}" ]] || fail "missing-reference failure writes stdout"
    grep -Fq 'DOTFILES_AGE_IDENTITY_REF' "${stderr_file}" || \
      fail "missing-reference failure omits variable name"
  }
  ```

- [ ] **Step 2: Run test and verify RED**

  Run: `zsh tests/test-build`

  Expected: FAIL because `build.zsh` does not exist.

- [ ] **Step 3: Implement environment and tool preflight**

  Create `build.zsh` with `#!/usr/bin/env zsh`, `ERR_EXIT`, `NO_UNSET`, `PIPE_FAIL`,
  `WARN_CREATE_GLOBAL`, a source-safe `main`, and private helpers. Validate required commands,
  both nonempty `op://` references, a real SSH agent socket with at least one public key,
  authenticated `op whoami`, Docker Compose availability, and Docker daemon availability.
  Validate references before commands or external services so missing-input failures stay
  deterministic. Error messages go to stderr and never include reference values.

  ```zsh
  function _require_secret_reference() {
    local variable_name="${1}"
    local reference="${(P)variable_name:-}"

    [[ -n "${reference}" ]] || _die "${variable_name} is required"
    [[ "${reference}" == op://* ]] || _die "${variable_name} must be a 1Password reference"
    (( ${#reference} <= 2048 )) || _die "${variable_name} is too long"
    [[ "${reference}" != *$'\n'* ]] || _die "${variable_name} contains a newline"
  }
  ```

- [ ] **Step 4: Run missing-reference test and verify GREEN**

  Run: `zsh tests/test-build`

  Expected: PASS for missing-reference behavior.

- [ ] **Step 5: Add successful build and cleanup test**

  Extend command stubs so `op read` returns fixed fake age values, host and container
  `ssh-add -L` return the same fixed fake public key, `docker compose build` validates both
  secret files exist with mode `0600`, and the Git probe exits zero. Run with `TMPDIR` inside
  the test scratch directory. Assert exit zero, empty stdout, and no remaining temporary build
  directory.

  ```zsh
  function test_success_cleans_secret_files() {
    local case_tmp="${TEST_ROOT}/success-tmp"
    mkdir -m 0700 "${case_tmp}"

    TMPDIR="${case_tmp}" PATH="${STUB_PATH}:${ORIGINAL_PATH}" \
      SSH_AUTH_SOCK="${TEST_AGENT_SOCKET}" \
      DOTFILES_AGE_IDENTITY_REF='op://test/item/identity' \
      DOTFILES_AGE_RECIPIENT_REF='op://test/item/recipient' \
      TEST_AGENT_KEYS='ssh-ed25519 AAAATEST build-test' \
      "${REPO_ROOT}/build.zsh" >"${TEST_ROOT}/success.stdout"

    [[ ! -s "${TEST_ROOT}/success.stdout" ]] || fail "successful build exposes key data"
    local remaining_files
    remaining_files=$(find "${case_tmp}" -mindepth 1 -print -quit)
    [[ -z "${remaining_files}" ]] || fail "successful build leaves secret files"
  }
  ```

- [ ] **Step 6: Run success test and verify RED**

  Run: `zsh tests/test-build`

  Expected: FAIL because `build.zsh` does not yet resolve secrets, invoke Compose, or clean up.

- [ ] **Step 7: Implement secret staging and Compose build**

  Create a restricted `mktemp -d` directory, install an exit trap before writing files, run
  quoted `op read` calls into mode-`0600` files, reject empty results, export only temporary
  file paths for Compose, and run `docker compose build`. Cleanup validates the scratch path
  prefix before recursive removal.

  ```zsh
  DOTFILES_AGE_IDENTITY_FILE="${identity_file}" \
    DOTFILES_AGE_RECIPIENT_FILE="${recipient_file}" \
    docker compose build
  ```

- [ ] **Step 8: Run success test and verify GREEN**

  Run: `zsh tests/test-build`

  Expected: PASS for missing-reference and successful-cleanup cases.

- [ ] **Step 9: Add mismatched-agent test**

  Configure host `ssh-add` stub to return key A and Compose runtime stub to return key B.
  Assert nonzero exit, generic mismatch error, no key material in stdout or stderr, and complete
  scratch cleanup.

- [ ] **Step 10: Run mismatch test and verify RED**

  Run: `zsh tests/test-build`

  Expected: FAIL because `build.zsh` does not compare agent identities.

- [ ] **Step 11: Implement runtime agent and Git verification**

  Normalize host and container `ssh-add -L` output with `LC_ALL=C sort -u` into restricted
  files, require both files to be nonempty, compare with `cmp --silent`, then run the private
  `git ls-remote` probe in a one-shot Compose container. Use `ssh -F /dev/null`, explicit
  `IdentityAgent`, `IdentityFile=none`, strict host checking, and the pinned user known-hosts
  file. Suppress probe output.

- [ ] **Step 12: Run wrapper tests and verify GREEN**

  Run: `zsh tests/test-build`

  Expected: all wrapper cases PASS with no key or secret output.

- [ ] **Step 13: Commit wrapper and tests**

  ```bash
  git add build.zsh tests/test-build
  git commit -m "build: add secure image build wrapper" \
    -m "Resolve age values on host and clean temporary secret files." \
    -m "Verify Docker Desktop forwards selected SSH agent."
  ```

### Task 2: Compose Build and Runtime Contract

**Files:**

- Create: `tests/test-compose`
- Create: `compose.yaml`

**Interfaces:**

- Consumes: `DOTFILES_AGE_IDENTITY_FILE`, `DOTFILES_AGE_RECIPIENT_FILE`, and BuildKit SSH ID
  `default`.
- Produces: service `devcontainer`, local image `pde-devcontainer:local`, build secrets, build
  SSH forwarding, runtime user/group settings, and Docker Desktop runtime socket mount.

- [ ] **Step 1: Write rendered-configuration test**

  Create two mode-`0600` fake secret files. Run `docker compose config --format json` with both
  file variables set, then use `jq -e` to assert the service's build context, SSH input, two
  build secrets, image name, user `1000:1000`, supplementary group `0`, runtime
  `SSH_AUTH_SOCK`, and bind mount source and target.

  Add a second case with both build-secret file variables unset. Assert that Compose still
  renders the runtime service and defaults both unused file sources to `/dev/null`.

  ```zsh
  rendered_config=$(DOTFILES_AGE_IDENTITY_FILE="${identity_file}" \
    DOTFILES_AGE_RECIPIENT_FILE="${recipient_file}" \
    docker compose --file "${REPO_ROOT}/compose.yaml" config --format json)

  jq -e '
    .services.devcontainer.user == "1000:1000" and
    .services.devcontainer.environment.SSH_AUTH_SOCK ==
      "/home/pde/.1password/agent.sock"
  ' <<<"${rendered_config}" >/dev/null
  ```

- [ ] **Step 2: Run Compose test and verify RED**

  Run: `zsh tests/test-compose`

  Expected: FAIL because `compose.yaml` does not exist.

- [ ] **Step 3: Implement Compose configuration**

  Define one `devcontainer` service. Configure `build.context: .`, `build.ssh: [default]`, both
  external file-backed build secrets, image `pde-devcontainer:local`, user `1000:1000`,
  `group_add: ["0"]`, interactive zsh defaults, and Docker Desktop's runtime socket bind mount.
  Default absent secret-file variables to `/dev/null` so runtime commands need no build-only
  environment. The wrapper supplies real files during builds, and the Dockerfile's required,
  nonempty secret use makes direct builds without them fail closed.

- [ ] **Step 4: Run Compose test and verify GREEN**

  Run: `zsh tests/test-compose`

  Expected: PASS and no warning about missing variables.

- [ ] **Step 5: Commit Compose configuration and test**

  ```bash
  git add compose.yaml tests/test-compose
  git commit -m "build: add compose agent forwarding" \
    -m "Pass scoped build secrets to BuildKit." \
    -m "Mount Docker Desktop's SSH-agent proxy for pde at runtime."
  ```

### Task 3: Dotfiles Image

**Files:**

- Create: `Dockerfile`

**Interfaces:**

- Consumes: BuildKit SSH ID `default`; secrets `dotfiles_age_identity` and
  `dotfiles_age_recipient`; target architecture `amd64` or `arm64`.
- Produces: image user `pde`; `/home/pde/.yadr`; `/home/pde/.yadr-private`; applied public and
  private dotfiles; strict GitHub SSH configuration; runtime agent symlink.

- [ ] **Step 1: Start Docker Desktop and verify daemon availability**

  Run: `open -a Docker` followed by `docker info` once Docker Desktop finishes starting.

  Expected: `docker info` exits zero. If Docker Desktop cannot start, continue with static
  tests and report full build verification as blocked by the daemon.

- [ ] **Step 2: Run Dockerfile check and verify RED**

  Run: `docker buildx build --check .`

  Expected: FAIL because `Dockerfile` does not exist.

- [ ] **Step 3: Implement base packages, pinned chezmoi, and user conversion**

  Start with the approved base image. Install `age`, `ca-certificates`, `curl`, `git`,
  `openssh-client`, `sudo`, and `zsh` without recommendations, then remove apt lists. Select
  the pinned chezmoi digest by `TARGETARCH`, reject unsupported architectures, verify with
  `sha256sum --check`, and install only the `chezmoi` binary. Verify `vscode` is UID/GID 1000,
  rename user and group to `pde`, move the home directory, set `/bin/zsh`, add group 0, install
  `/etc/sudoers.d/pde` at mode `0440`, and validate it with `visudo --check`.

- [ ] **Step 4: Implement strict GitHub setup and both clones**

  Install GitHub's published Ed25519 key before network access. Switch to `USER pde`. Clone
  each exact SSH URL with a separate required SSH mount using `uid=1000,gid=1000,mode=0600`.
  For both clones set `GIT_SSH_COMMAND` to `ssh -F /dev/null` with batch mode, strict host
  checking, explicit known-hosts file, and `IdentityFile=none`. Run the public repository's
  installer with `DEBIAN_FRONTEND=noninteractive` before cloning the private repository.

- [ ] **Step 5: Implement private chezmoi apply**

  Mount both age values only on the private apply instruction at mode `0400`. Create a
  mode-`0700` temporary directory and mode-`0600` chezmoi YAML config, point it at
  `/home/pde/.yadr-private/root`, refer to the mounted identity path, insert the recipient
  without logging it, run `chezmoi apply --verbose --no-pager`, and remove the temporary config
  before the instruction exits.

- [ ] **Step 6: Reconcile SSH configuration**

  Prepend a `Host github.com` block whose first values select the home-directory agent symlink,
  strict host checking, and the user's known-hosts file. Remove clear and hashed entries for
  `github.com` and `[github.com]:22`, preserve unrelated hosts, then append only the published
  Ed25519 GitHub entry. Create `/home/pde/.1password/agent.sock` as a symlink to Docker
  Desktop's proxy. Verify effective `ssh -G github.com` values and exact known-hosts lookup
  without printing key material.

- [ ] **Step 7: Finalize image defaults**

  Set `USER pde`, `HOME=/home/pde`, `WORKDIR /home/pde`, and default command
  `/bin/zsh -l`. Keep runtime `SSH_AUTH_SOCK` in Compose, which owns the corresponding
  Docker Desktop socket mount.

- [ ] **Step 8: Run Dockerfile check and verify GREEN**

  Run: `docker buildx build --check .`

  Expected: PASS with no Dockerfile warnings.

- [ ] **Step 9: Commit Dockerfile**

  ```bash
  git add Dockerfile
  git commit -m "build: provision dotfiles image" \
    -m "Create pde user and apply both chezmoi layers." \
    -m "Scope BuildKit mounts and restore strict runtime SSH settings."
  ```

### Task 4: Integrated Verification

**Files:**

- Modify only if a verified defect requires it: `Dockerfile`, `build.zsh`, `compose.yaml`,
  `tests/test-build`, `tests/test-compose`

**Interfaces:**

- Consumes: all artifacts from Tasks 1 through 3 plus authenticated host Docker Desktop,
  1Password CLI, 1Password SSH agent, and the two required reference variables.
- Produces: static, build, image, and runtime evidence against the approved design.

- [ ] **Step 1: Run zsh behavior tests**

  Run: `zsh tests/test-build && zsh tests/test-compose`

  Expected: all cases PASS and no secret or key material appears.

- [ ] **Step 2: Run zsh analysis**

  Run these available checks against `build.zsh`, `tests/test-build`, and
  `tests/test-compose`:

  ```bash
  zsh -n build.zsh tests/test-build tests/test-compose
  zsh -c 'zcompile "$@"' _ build.zsh tests/test-build tests/test-compose
  shellcheck --shell=bash --exclude=SC1090,SC2039,SC2154,SC2168,SC2296,SC2299 \
    build.zsh tests/test-build tests/test-compose
  shellharden --check build.zsh tests/test-build tests/test-compose
  shfmt -ln zsh -d build.zsh tests/test-build tests/test-compose
  ```

  Expected: native syntax and compile checks PASS. Review limited-zsh-tool findings and fix only
  genuine issues. Remove generated `.zwc` files after the compile check.

- [ ] **Step 3: Run configuration checks**

  Run: `zsh tests/test-compose`, `docker buildx build --check .`, and `git diff --check`.

  Expected: all exit zero.

- [ ] **Step 4: Run full build wrapper**

  With `DOTFILES_AGE_IDENTITY_REF` and `DOTFILES_AGE_RECIPIENT_REF` already set in the host
  environment and `op whoami` succeeding, run: `./build.zsh`.

  Expected: image build completes, host/container agent key sets match silently, and agent-only
  private Git probe succeeds.

- [ ] **Step 5: Verify required BuildKit inputs fail closed**

  Run direct Buildx builds once without `--ssh`, once without the identity secret, and once
  without the recipient secret. Keep all other inputs identical to the successful build.

  Expected: missing SSH fails at the first clone instruction; each missing age value fails at
  the private apply instruction. No successful replacement image is produced.

- [ ] **Step 6: Verify image invariants**

  Run a one-shot Compose container and check UID/GID, supplementary group 0, `/bin/zsh`,
  `sudo -n true`, chezmoi 2.71.1, checkout ownership, applied files, strict `ssh -G` values,
  exact GitHub host entry, absent `op`, absent `OP_*`, and absent temporary secret/config files.

- [ ] **Step 7: Run secret scan and inspect repository state**

  Run the repository gitleaks hook through the final commit, then inspect `git status --short`
  and commit contents. Keep `.codex/` untracked and untouched.

- [ ] **Step 8: Commit verified fixes only if needed**

  Use a focused Conventional Commit with a wrapped body. Do not amend unrelated work or push.

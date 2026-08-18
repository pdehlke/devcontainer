# Container Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adapt nicwolff/claude-container's launcher script into `scripts/claude-container`, installable via `make install` as `claude-container`/`codex-container`/`gemini-container`, matching this repo's image, account, and credential model.

**Architecture:** A single bash script picks its CLI flavor from `argv[0]`'s basename (matching how `make install`'s hardlinks work), builds a `docker run` invocation mounting the current directory plus host credentials, and execs it. A `Makefile` installs the hardlinks. Tests stub `docker` (extending the existing `tests/fixtures/bin/docker` fixture) to capture the constructed `docker run` argv instead of actually invoking Docker.

**Tech Stack:** bash (the launcher itself, matching upstream), zsh (tests, `Makefile`, matching `tests/test-build`/`tests/test-compose`), POSIX sh (the shared docker stub, already sh).

**Spec:** [docs/superpowers/specs/2026-08-18-container-launcher-design.md](../specs/2026-08-18-container-launcher-design.md)

## Global Constraints

- Container-side paths use `/home/pde`, never upstream's `/home/dev`.
- Image stays `claude-code-dev:latest` (already matches `compose.yaml`).
- SSH agent forwarding: mount `/run/host-services/ssh-auth.sock` to the same path, and set `SSH_AUTH_SOCK=/home/pde/.1password/agent.sock` (resolved by the in-image symlink the Dockerfile already creates), mirroring `compose.yaml`.
- Docker socket mount: dropped after the final review found no consumer in this image (no docker CLI installed anywhere) — pure added blast radius for zero benefit. See the design spec's decision table for the full rationale. Don't re-add without a real use case.
- `~/.claude` and `~/.claude.json` mount read-write when present, for the claude flavor (matches upstream, supersedes container-setup.md's more cautious credentials-only option for this launcher).
- No `--dangerously-skip-permissions` auto-injection for the `claude` flavor (deferred; codex/gemini keep their existing `--yolo` auto-injection unchanged).
- Drop `ALLOWED_MOUNT_BASE`/`ALLOWED_RW_BASE` and the separate `~/.claude-plugins` mount entirely — nothing in this repo consumes them.
- Existing test convention (`tests/test-build`, `tests/test-compose`): zsh script, `PATH="${STUB_PATH}:${ORIGINAL_PATH}"` to substitute `tests/fixtures/bin/docker`, a `fail()` helper, `TRAPEXIT`/`TRAPZERR` cleanup of a `mktemp -d` scratch root, `test_*` functions driven by `main()`, `print -r -- "PASS: ..."` after each.

---

### Task 1: Extend the shared docker test fixture

**Files:**
- Modify: `tests/fixtures/bin/docker`

**Interfaces:**
- Consumes: nothing new.
- Produces: a top-level `docker run <args...>` mode that writes each argument to `${TEST_DOCKER_RUN_ARGS_FILE}` (one per line) and exits `${TEST_DOCKER_RUN_STATUS:-0}`; a `docker image inspect <name>` mode that exits `${TEST_DOCKER_IMAGE_INSPECT_STATUS:-0}`. Both are consumed by Task 2's tests.

- [ ] **Step 1: Add the `run` and `image` cases to the stub**

The file has two `case` statements: the outer one on `"${1:-}"` (branches: `info`, `compose`,
`*)`), and a nested one inside `compose)` on `"${2:-}"` for `docker compose run` (branches:
`version`, `build`, `run`, `*)`). The new branches below are for plain `docker run`/`docker
image inspect`, so they belong in the **outer** case, not the nested `compose` one — don't
confuse this new `run)` with the existing `compose) ... run)` branch.

The file currently ends with:

```sh
*)
  exit 64
  ;;
esac
```

That final block is the outer case's fallback. Replace it with:

```sh
image)
  case "${2:-}" in
  inspect)
    exit "${TEST_DOCKER_IMAGE_INSPECT_STATUS:-0}"
    ;;
  *)
    exit 64
    ;;
  esac
  ;;
run)
  shift
  : >"${TEST_DOCKER_RUN_ARGS_FILE:?run args file is required}"
  for arg in "$@"; do
    printf '%s\n' "${arg}" >>"${TEST_DOCKER_RUN_ARGS_FILE}"
  done
  exit "${TEST_DOCKER_RUN_STATUS:-0}"
  ;;
*)
  exit 64
  ;;
esac
```

This adds the two new branches immediately before the outer case's `*)` fallback, which stays
last. The nested `compose) ... esac ;;` block above it is untouched.

- [ ] **Step 2: Confirm the existing tests still pass**

Run: `./tests/test-build && ./tests/test-compose`
Expected: both scripts print their `PASS:` lines and exit 0. This stub is shared, so this step guards against a typo breaking the `compose`/`info` branches those tests rely on.

- [ ] **Step 3: Commit**

```bash
git add tests/fixtures/bin/docker
git commit -m "test(fixtures): add run and image inspect modes to the docker stub"
```

---

### Task 2: Write `scripts/claude-container` with its test

**Files:**
- Create: `scripts/claude-container`
- Create: `tests/test-claude-container`

**Interfaces:**
- Consumes: `tests/fixtures/bin/docker`'s `run`/`image inspect`/`info` modes from Task 1.
- Produces: `scripts/claude-container`, an executable bash script, consumed by Task 3's `Makefile` (installed as-is) and Task 4's docs (referenced by path).

- [ ] **Step 1: Write the failing test**

Create `tests/test-claude-container`:

```zsh
#!/usr/bin/env zsh
# test-claude-container -- Exercise scripts/claude-container through controlled command boundaries.
# Author: Pete Ehlke
# Date: 2026-08-18

setopt ERR_EXIT NO_UNSET PIPE_FAIL WARN_CREATE_GLOBAL

readonly REPO_ROOT="${0:A:h:h}"
readonly ORIGINAL_PATH="${PATH}"
readonly STUB_PATH="${REPO_ROOT}/tests/fixtures/bin"
readonly LAUNCHER="${REPO_ROOT}/scripts/claude-container"
typeset -g TEST_ROOT=""
typeset -g BIN_ROOT=""

function fail() {
  local message="${1}"

  print -u2 -r -- "FAIL: ${message}"
  return 1
}

# Remove only the restricted directory created by this test process.
function _cleanup() {
  if [[ -n "${TEST_ROOT}" && -d "${TEST_ROOT}" ]]; then
    command rm -rf -- "${TEST_ROOT}"
  fi
}

function TRAPEXIT() {
  local exit_code="${?}"

  _cleanup
  return "${exit_code}"
}

# ERR_EXIT can bypass TRAPEXIT when a command fails inside a zsh function.
function TRAPZERR() {
  local exit_code="${?}"

  _cleanup
  return "${exit_code}"
}

function test_default_flavor_mounts_and_forwards_ssh_agent() {
  local case_home="${TEST_ROOT}/default-home"
  local run_args="${case_home}/run-args"

  mkdir -p "${case_home}/.claude"
  : >"${case_home}/.gitconfig"
  : >"${case_home}/.claude.json"

  ( cd "${case_home}" && env -i \
    PATH="${STUB_PATH}:${ORIGINAL_PATH}" \
    HOME="${case_home}" \
    TEST_DOCKER_RUN_ARGS_FILE="${run_args}" \
    "${BIN_ROOT}/claude-container" )

  grep --fixed-strings --quiet -- "${case_home}:${case_home}" "${run_args}" || \
    fail "current directory is not mounted at its own path"
  grep --fixed-strings --quiet -- \
    '/run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock' "${run_args}" || \
    fail "SSH agent proxy socket is not mounted"
  grep --fixed-strings --line-regexp --quiet -- \
    'SSH_AUTH_SOCK=/home/pde/.1password/agent.sock' "${run_args}" || \
    fail "SSH_AUTH_SOCK does not point at the in-image 1Password symlink"
  grep --fixed-strings --quiet -- '/var/run/docker.sock:/var/run/docker.sock' "${run_args}" || \
    fail "Docker socket is not mounted straight through"
  grep --fixed-strings --quiet -- "${case_home}/.gitconfig:/home/pde/.gitconfig:ro" "${run_args}" || \
    fail ".gitconfig is not mounted read-only"
  grep --fixed-strings --quiet -- "${case_home}/.claude:/home/pde/.claude:rw" "${run_args}" || \
    fail "~/.claude is not mounted read-write"
  grep --fixed-strings --quiet -- "${case_home}/.claude.json:/home/pde/.claude.json:rw" "${run_args}" || \
    fail "~/.claude.json is not mounted read-write"
  grep --fixed-strings --line-regexp --quiet -- 'claude-code-dev:latest' "${run_args}" || \
    fail "image name does not match compose.yaml"
  if grep --fixed-strings --quiet -- 'dangerously-skip-permissions' "${run_args}"; then
    fail "claude flavor auto-injects skip-permissions, which was explicitly deferred"
  fi
  if grep --fixed-strings --quiet -- "${case_home}/.codex" "${run_args}"; then
    fail "claude flavor mounts codex config"
  fi
}

function test_codex_flavor_injects_yolo_and_mounts_codex_config() {
  local case_home="${TEST_ROOT}/codex-home"
  local run_args="${case_home}/run-args"

  mkdir -p "${case_home}/.codex"

  ( cd "${case_home}" && env -i \
    PATH="${STUB_PATH}:${ORIGINAL_PATH}" \
    HOME="${case_home}" \
    OPENAI_API_KEY="test-key" \
    TEST_DOCKER_RUN_ARGS_FILE="${run_args}" \
    "${BIN_ROOT}/codex-container" )

  grep --fixed-strings --line-regexp --quiet -- 'codex' "${run_args}" || \
    fail "codex is not invoked"
  grep --fixed-strings --line-regexp --quiet -- '--yolo' "${run_args}" || \
    fail "--yolo is not auto-injected for codex"
  grep --fixed-strings --quiet -- "${case_home}/.codex:/home/pde/.codex:rw" "${run_args}" || \
    fail "~/.codex is not mounted read-write"
  if grep --fixed-strings --quiet -- "${case_home}/.claude:" "${run_args}"; then
    fail "codex flavor mounts claude config"
  fi
}

function test_gemini_flavor_injects_yolo_and_mounts_gemini_config() {
  local case_home="${TEST_ROOT}/gemini-home"
  local run_args="${case_home}/run-args"

  mkdir -p "${case_home}/.gemini" "${case_home}/.config/gcloud"

  ( cd "${case_home}" && env -i \
    PATH="${STUB_PATH}:${ORIGINAL_PATH}" \
    HOME="${case_home}" \
    TEST_DOCKER_RUN_ARGS_FILE="${run_args}" \
    "${BIN_ROOT}/gemini-container" )

  grep --fixed-strings --line-regexp --quiet -- 'gemini' "${run_args}" || \
    fail "gemini is not invoked"
  grep --fixed-strings --line-regexp --quiet -- '--yolo' "${run_args}" || \
    fail "--yolo is not auto-injected for gemini"
  grep --fixed-strings --quiet -- "${case_home}/.gemini:/home/pde/.gemini:rw" "${run_args}" || \
    fail "~/.gemini is not mounted read-write"
  grep --fixed-strings --quiet -- \
    "${case_home}/.config/gcloud:/home/pde/.config/gcloud:rw" "${run_args}" || \
    fail "~/.config/gcloud is not mounted read-write"
}

function test_explicit_command_skips_yolo_injection() {
  local case_home="${TEST_ROOT}/explicit-home"
  local run_args="${case_home}/run-args"

  mkdir -p "${case_home}"

  ( cd "${case_home}" && env -i \
    PATH="${STUB_PATH}:${ORIGINAL_PATH}" \
    HOME="${case_home}" \
    TEST_DOCKER_RUN_ARGS_FILE="${run_args}" \
    "${BIN_ROOT}/codex-container" bash )

  grep --fixed-strings --line-regexp --quiet -- 'bash' "${run_args}" || \
    fail "explicit command is not passed through"
  if grep --fixed-strings --line-regexp --quiet -- '--yolo' "${run_args}"; then
    fail "--yolo is injected even with an explicit command"
  fi
}

function test_container_help_does_not_require_docker() {
  local case_home="${TEST_ROOT}/help-home"
  local stdout_file="${case_home}/stdout"

  mkdir -p "${case_home}"
  env -i PATH="/usr/bin:/bin" HOME="${case_home}" \
    "${BIN_ROOT}/claude-container" --container-help >"${stdout_file}"

  grep --fixed-strings --quiet -- 'Usage:' "${stdout_file}" || fail "--container-help prints no usage"
}

function test_missing_image_errors_with_build_hint() {
  local case_home="${TEST_ROOT}/missing-image-home"
  local stderr_file="${case_home}/stderr"
  local exit_code=0

  mkdir -p "${case_home}"
  if env -i \
    PATH="${STUB_PATH}:${ORIGINAL_PATH}" \
    HOME="${case_home}" \
    TEST_DOCKER_IMAGE_INSPECT_STATUS=1 \
    "${BIN_ROOT}/claude-container" >/dev/null 2>"${stderr_file}"; then
    exit_code=0
  else
    exit_code="${?}"
  fi

  (( exit_code != 0 )) || fail "launcher succeeds with no image built"
  grep --fixed-strings --quiet -- 'build.zsh' "${stderr_file}" || \
    fail "missing-image error omits the build hint"
}

function main() {
  local test_root

  test_root=$(mktemp -d "${TMPDIR:-/tmp}/devcontainer-test-claude-container.XXXXXXXX")
  typeset -g TEST_ROOT="${test_root}"
  chmod 0700 "${TEST_ROOT}"

  typeset -g BIN_ROOT="${TEST_ROOT}/bin"
  mkdir -p "${BIN_ROOT}"
  ln -s "${LAUNCHER}" "${BIN_ROOT}/claude-container"
  ln -s "${LAUNCHER}" "${BIN_ROOT}/codex-container"
  ln -s "${LAUNCHER}" "${BIN_ROOT}/gemini-container"

  test_default_flavor_mounts_and_forwards_ssh_agent
  print -r -- "PASS: default flavor mounts claude config and forwards the SSH agent"
  test_codex_flavor_injects_yolo_and_mounts_codex_config
  print -r -- "PASS: codex flavor injects --yolo and mounts codex config"
  test_gemini_flavor_injects_yolo_and_mounts_gemini_config
  print -r -- "PASS: gemini flavor injects --yolo and mounts gemini config"
  test_explicit_command_skips_yolo_injection
  print -r -- "PASS: an explicit command skips --yolo injection"
  test_container_help_does_not_require_docker
  print -r -- "PASS: --container-help works without Docker"
  test_missing_image_errors_with_build_hint
  print -r -- "PASS: a missing image fails with a build hint"
}

main "${@}"
```

Make it executable: `chmod 0755 tests/test-claude-container`

- [ ] **Step 2: Run it to verify it fails**

Run: `./tests/test-claude-container`
Expected: fails immediately — `scripts/claude-container` doesn't exist yet, so the `ln -s` in `main()` either errors or the first test's invocation errors with "no such file or directory".

- [ ] **Step 3: Write `scripts/claude-container`**

```bash
#!/usr/bin/env bash
# claude-container — launch the devcontainer image from any repo, running Claude Code, Codex,
# or Gemini CLI depending on the name it's invoked as (see the `install` target in ../Makefile).
# Adapted from https://github.com/nicwolff/claude-container; see
# docs/superpowers/specs/2026-08-18-container-launcher-design.md for what changed and why.

set -euo pipefail

IMAGE="claude-code-dev:latest"
SELF="$(basename "$0")"
TOOL_FLAVOR="claude"

if [[ "${1:-}" == "--container-help" || "${1:-}" == "-H" ]]; then
  cat <<HELP
Usage: $SELF [ARGS...] | [COMMAND...]

Launch ${SELF%%-container} in the devcontainer image with your current directory mounted.

  claude-container                Launch Claude Code interactively
  claude-container --model opus   Pass flags to Claude Code
  codex-container                 Launch Codex CLI (--yolo added automatically)
  gemini-container                Launch Gemini CLI (--yolo added automatically)
  <any> bash                      Run an arbitrary command in the container
  <any> gh pr list                Use container tools directly
  <any> --container-help          Show this help

Environment variables (passed through when set):
  AWS_PROFILE               AWS profile to use
  AWS_REGION                AWS region for API calls
  CLAUDE_CODE_USE_BEDROCK   Set to 1 for AWS Bedrock
  CLAUDE_GITHUB_TOKEN       GitHub personal access token for gh CLI
  GOOGLE_CLOUD_PROJECT      Google Cloud project ID for Gemini CLI Vertex usage
  GOOGLE_CLOUD_LOCATION     Google Cloud region for Gemini CLI Vertex usage
  OPENAI_API_KEY             OpenAI API key for Codex (falls back to macOS Keychain)
HELP
  exit 0
fi

# Prerequisite checks
if ! docker info >/dev/null 2>&1; then
  echo "Error: Docker is not running" >&2
  exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Error: Image $IMAGE not found. Build it from the devcontainer repo:" >&2
  echo "  ./build.zsh" >&2
  exit 1
fi

# When invoked as an alternate launcher, inject the CLI command only when the user is launching
# the CLI itself rather than an arbitrary container command.
if [[ "$SELF" == "codex-container" ]]; then
  TOOL_FLAVOR="codex"
  if [ $# -eq 0 ] || [[ "${1:0:1}" == "-" ]]; then
    if [ -z "${OPENAI_API_KEY:-}" ]; then
      OPENAI_API_KEY="$(security find-generic-password -s OPENAI_API_KEY -w 2>/dev/null)" || {
        echo "Error: OPENAI_API_KEY not found in environment or macOS Keychain" >&2
        echo "  Store it with: security add-generic-password -s OPENAI_API_KEY -a openai -w 'sk-...'" >&2
        exit 1
      }
    fi
    set -- codex --yolo "$@"
  fi
elif [[ "$SELF" == "gemini-container" ]]; then
  TOOL_FLAVOR="gemini"
  if [ $# -eq 0 ] || [[ "${1:0:1}" == "-" ]]; then
    set -- gemini --yolo "$@"
  fi
fi

# Get absolute path of current directory
PWD_ABS="$(pwd)"

# Build volume mounts; skip optional paths that don't exist on the host. The current directory,
# the SSH agent proxy socket, and the Docker socket are not optional.
VOLUMES=(
  -v "${PWD_ABS}:${PWD_ABS}"
  -v "/run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock"
  -v "/var/run/docker.sock:/var/run/docker.sock"
)
if [ -f "${HOME}/.gitconfig" ]; then
  VOLUMES+=(-v "${HOME}/.gitconfig:/home/pde/.gitconfig:ro")
else
  echo "Warning: ~/.gitconfig not found; git identity will be unavailable in the container" >&2
fi
[ -d "${HOME}/.aws" ] && VOLUMES+=(-v "${HOME}/.aws:/home/pde/.aws:ro")
[ -d "${HOME}/.config/gh" ] && VOLUMES+=(-v "${HOME}/.config/gh:/home/pde/.config/gh:ro")

if [ "$TOOL_FLAVOR" = "codex" ]; then
  [ -d "${HOME}/.codex" ] && VOLUMES+=(-v "${HOME}/.codex:/home/pde/.codex:rw")
elif [ "$TOOL_FLAVOR" = "gemini" ]; then
  [ -d "${HOME}/.gemini" ] && VOLUMES+=(-v "${HOME}/.gemini:/home/pde/.gemini:rw")
  [ -d "${HOME}/.config/gcloud" ] && VOLUMES+=(-v "${HOME}/.config/gcloud:/home/pde/.config/gcloud:rw")
else
  [ -d "${HOME}/.claude" ] && VOLUMES+=(-v "${HOME}/.claude:/home/pde/.claude:rw")
  [ -f "${HOME}/.claude.json" ] && VOLUMES+=(-v "${HOME}/.claude.json:/home/pde/.claude.json:rw")
fi

# Run the dev container. SSH_AUTH_SOCK points at the in-image symlink the Dockerfile creates
# to /run/host-services/ssh-auth.sock, matching compose.yaml's forwarding setup.
exec docker run --rm -it \
  "${VOLUMES[@]}" -w "${PWD_ABS}" \
  -e "SSH_AUTH_SOCK=/home/pde/.1password/agent.sock" \
  ${AWS_PROFILE:+-e "AWS_PROFILE=${AWS_PROFILE}"} \
  ${AWS_REGION:+-e "AWS_REGION=${AWS_REGION}"} \
  ${CLAUDE_CODE_USE_BEDROCK:+-e "CLAUDE_CODE_USE_BEDROCK=${CLAUDE_CODE_USE_BEDROCK}"} \
  ${CLAUDE_GITHUB_TOKEN:+-e "GITHUB_TOKEN=${CLAUDE_GITHUB_TOKEN}"} \
  ${GOOGLE_CLOUD_PROJECT:+-e "GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT}"} \
  ${GOOGLE_CLOUD_LOCATION:+-e "GOOGLE_CLOUD_LOCATION=${GOOGLE_CLOUD_LOCATION}"} \
  ${OPENAI_API_KEY:+-e "OPENAI_API_KEY=${OPENAI_API_KEY}"} \
  "$IMAGE" "$@"
```

Make it executable: `chmod 0755 scripts/claude-container`

- [ ] **Step 4: Run the test to verify it passes**

Run: `./tests/test-claude-container`
Expected: six `PASS:` lines, one per `test_*` function, then exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/claude-container tests/test-claude-container
git commit -m "feat(scripts): add claude-container launcher for claude/codex/gemini

Adapts nicwolff/claude-container to this repo's image, /home/pde
account, and credential model — SSH-agent forwarding on top of the
upstream host-config mounts, a straight (unproxied) Docker socket
mount, and no --dangerously-skip-permissions auto-injection for the
claude flavor (deferred; see the design spec).
"
```

---

### Task 3: Add the `Makefile` install target

**Files:**
- Create: `Makefile`

**Interfaces:**
- Consumes: `scripts/claude-container` from Task 2.
- Produces: an `install` target referenced by Task 4's docs.

- [ ] **Step 1: Write the Makefile**

```makefile
PREFIX ?= $(HOME)/.local/bin

.PHONY: install
install:
	install -d $(PREFIX)
	install -m 0755 scripts/claude-container $(PREFIX)/claude-container
	ln -f $(PREFIX)/claude-container $(PREFIX)/codex-container
	ln -f $(PREFIX)/claude-container $(PREFIX)/gemini-container
```

- [ ] **Step 2: Verify the install target against a scratch prefix**

Run:
```zsh
scratch_prefix="$(mktemp -d)"
make install PREFIX="${scratch_prefix}"
ls -l "${scratch_prefix}"
stat -f '%i' "${scratch_prefix}/claude-container" "${scratch_prefix}/codex-container" "${scratch_prefix}/gemini-container"
rm -rf "${scratch_prefix}"
```
Expected: `ls -l` lists all three files at mode `-rwxr-xr-x`; `stat -f '%i'` prints the same inode number three times, confirming `codex-container`/`gemini-container` are hard links to `claude-container`, not copies.

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -m "feat(scripts): add make install target for the container launchers"
```

---

### Task 4: Document the launcher

**Files:**
- Modify: `docs/agents/building.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 2's `scripts/claude-container`, Task 3's `make install`, and the already-committed design spec at `docs/superpowers/specs/2026-08-18-container-launcher-design.md`.
- Produces: nothing consumed by later tasks (this is the last task).

- [ ] **Step 1: Add a "Launch from another repo" section to `docs/agents/building.md`**

Insert this new section between the existing `## Run` section and `## Troubleshooting` section:

```markdown
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

Unlike `docker compose run`, this launcher mounts the current directory, `~/.gitconfig`, and
per-tool config directories (`~/.claude`, `~/.codex`, `~/.gemini`, `~/.config/gcloud`,
`~/.config/gh`, `~/.aws`) read-write where noted, on top of the same 1Password SSH-agent
forwarding `compose.yaml` uses. See
[the launcher design](../superpowers/specs/2026-08-18-container-launcher-design.md) for the full
mount table and the reasoning behind the Docker-socket and credential-mount decisions.
```

- [ ] **Step 2: Update `README.md`'s Designs section**

In the `### Designs` section, after the existing "Dotfiles implementation plan" entry, add:

```markdown
- [Container launcher design](docs/superpowers/specs/2026-08-18-container-launcher-design.md)

  Adapting a third-party launcher script to this repo's image, account, and credential model:
  SSH-agent forwarding, Docker-socket and Claude-auth mount decisions, and what wasn't carried
  over from upstream.

- [Container launcher implementation plan](docs/superpowers/plans/2026-08-18-container-launcher.md)

  Test-first tasks for the launcher script, its Makefile install target, and documentation.
```

Also update the existing `docs/agents/building.md` bullet's description (in the `### Meta` section)
to mention the launcher. Change:

```markdown
  Host prerequisites, secure build procedure, runtime command, and troubleshooting for the
  dotfiles-backed development image.
```

to:

```markdown
  Host prerequisites, secure build procedure, runtime command, launching the image from another
  repo, and troubleshooting for the dotfiles-backed development image.
```

- [ ] **Step 3: Commit**

```bash
git add docs/agents/building.md README.md
git commit -m "docs(container-launcher): document the launcher script and update the README"
```

# Multi-repo Mounts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `scripts/claude-container` mount one or more extra host paths alongside the current directory, so a project with a sibling checkout it cross-references (e.g. `homeassistant` and its `homie-dashboard` fork) can have both mounted in one launch.

**Architecture:** A new `CONTAINER_EXTRA_MOUNTS` env var (colon-separated absolute host paths) is read the same way the script already reads `AWS_PROFILE`/`AWS_REGION`. Each existing path is appended to the `VOLUMES` array as `-v path:path` (read-write, identical container path, matching the current-directory mount); each missing path prints a warning to stderr and is skipped. Then a `.envrc` in the separate `homeassistant` repo sets that var so the pairing is automatic on `cd`, needing no new parsing code in this repo.

**Tech Stack:** bash (the launcher itself), zsh (tests, matching `tests/test-claude-container`'s existing convention), direnv (already installed on the host, for the `homeassistant/.envrc`).

**Spec:** [docs/superpowers/specs/2026-08-19-multi-repo-mounts-design.md](../specs/2026-08-19-multi-repo-mounts-design.md)

## Global Constraints

- Env var name: `CONTAINER_EXTRA_MOUNTS`, colon-separated absolute host paths (`$PATH`-style).
- Each path is mounted read-write at the identical container path: `-v "${path}:${path}"`, no `:ro`/`:rw` suffix, matching the existing `-v "${PWD_ABS}:${PWD_ABS}"` line's format.
- A path that fails a `[ -d "${path}" ]` check prints `Warning: CONTAINER_EXTRA_MOUNTS path not found, skipping: ${path}` to stderr and is skipped — not a fatal error.
- Unset or empty `CONTAINER_EXTRA_MOUNTS` must leave the constructed `docker run` argv byte-for-byte identical to today's (no new flags at all).
- `-w "${PWD_ABS}"` is unchanged — extra mounts never change the container's working directory.
- This applies identically to all three flavors (claude/codex/gemini): the code goes in the shared mount-building section, not inside any `if [ "$TOOL_FLAVOR" = ... ]` branch.
- `homeassistant/.envrc` content is exactly:
  ```sh
  # Mount the homie-dashboard fork alongside homeassistant in claude-container/codex-container/
  # gemini-container, since homeassistant's docs cross-reference it at this path.
  export CONTAINER_EXTRA_MOUNTS=/Users/pde/src/github.com/pdehlke/homie-dashboard
  ```
  That file lives in the `homeassistant` repo (`/Users/pde/src/github.com/pdehlke/homeassistant/.envrc`), not this one.

---

### Task 1: Add `CONTAINER_EXTRA_MOUNTS` to the launcher

**Files:**
- Modify: `scripts/claude-container`
- Modify: `tests/test-claude-container`

**Interfaces:**
- Consumes: the existing `docker` test stub's `run` mode (`tests/fixtures/bin/docker`), which already captures every argument of a `docker run` invocation to `${TEST_DOCKER_RUN_ARGS_FILE}`, one per line — no fixture changes needed, since arbitrary extra `-v` flags are already captured generically.
- Produces: `CONTAINER_EXTRA_MOUNTS` support in `scripts/claude-container`, consumed by Task 2 (docs) and Task 3 (the `homeassistant/.envrc`, verified manually against a real launch).

- [ ] **Step 1: Write the failing tests**

In `tests/test-claude-container`, insert four new test functions immediately after
`test_ambient_github_token_is_not_forwarded_without_opt_in` (the function ends at line 355 with
its closing `}`) and immediately before `test_container_help_does_not_require_docker`:

```zsh
function test_extra_mount_is_added_read_write() {
  local case_home="${TEST_ROOT}/extra-mount-home"
  local run_args="${case_home}/run-args"
  local sibling="${TEST_ROOT}/sibling-repo"

  mkdir -p "${case_home}" "${sibling}"

  ( cd "${case_home}" && env -i \
    PATH="${STUB_PATH}:${ORIGINAL_PATH}" \
    HOME="${case_home}" \
    TEST_KEYCHAIN_CLAUDE_CODE_OAUTH_TOKEN="test-oauth-token" \
    CONTAINER_EXTRA_MOUNTS="${sibling}" \
    TEST_DOCKER_RUN_ARGS_FILE="${run_args}" \
    "${BIN_ROOT}/claude-container" )

  grep --fixed-strings --line-regexp --quiet -- "${sibling}:${sibling}" "${run_args}" || \
    fail "CONTAINER_EXTRA_MOUNTS path is not mounted read-write at its own path"
}

function test_extra_mounts_multiple_paths_each_added() {
  local case_home="${TEST_ROOT}/extra-mounts-multi-home"
  local run_args="${case_home}/run-args"
  local sibling_one="${TEST_ROOT}/sibling-repo-one"
  local sibling_two="${TEST_ROOT}/sibling-repo-two"

  mkdir -p "${case_home}" "${sibling_one}" "${sibling_two}"

  ( cd "${case_home}" && env -i \
    PATH="${STUB_PATH}:${ORIGINAL_PATH}" \
    HOME="${case_home}" \
    TEST_KEYCHAIN_CLAUDE_CODE_OAUTH_TOKEN="test-oauth-token" \
    CONTAINER_EXTRA_MOUNTS="${sibling_one}:${sibling_two}" \
    TEST_DOCKER_RUN_ARGS_FILE="${run_args}" \
    "${BIN_ROOT}/claude-container" )

  grep --fixed-strings --line-regexp --quiet -- "${sibling_one}:${sibling_one}" "${run_args}" || \
    fail "first CONTAINER_EXTRA_MOUNTS path is not mounted"
  grep --fixed-strings --line-regexp --quiet -- "${sibling_two}:${sibling_two}" "${run_args}" || \
    fail "second CONTAINER_EXTRA_MOUNTS path is not mounted"
}

function test_extra_mount_missing_path_is_skipped_with_warning() {
  local case_home="${TEST_ROOT}/extra-mount-missing-home"
  local run_args="${case_home}/run-args"
  local stderr_file="${case_home}/stderr"
  local missing="${TEST_ROOT}/does-not-exist"

  mkdir -p "${case_home}"

  ( cd "${case_home}" && env -i \
    PATH="${STUB_PATH}:${ORIGINAL_PATH}" \
    HOME="${case_home}" \
    TEST_KEYCHAIN_CLAUDE_CODE_OAUTH_TOKEN="test-oauth-token" \
    CONTAINER_EXTRA_MOUNTS="${missing}" \
    TEST_DOCKER_RUN_ARGS_FILE="${run_args}" \
    "${BIN_ROOT}/claude-container" 2>"${stderr_file}" )

  grep --fixed-strings --quiet -- \
    "CONTAINER_EXTRA_MOUNTS path not found, skipping: ${missing}" "${stderr_file}" || \
    fail "a missing CONTAINER_EXTRA_MOUNTS path warns without naming the path"
  if grep --fixed-strings --quiet -- "${missing}:${missing}" "${run_args}"; then
    fail "a missing CONTAINER_EXTRA_MOUNTS path is mounted anyway"
  fi
}

# The current directory and the SSH agent proxy socket are the only two unconditional mounts
# (scripts/claude-container's own comment says so); an unset CONTAINER_EXTRA_MOUNTS must not add
# a third.
function test_extra_mounts_unset_adds_no_extra_volume() {
  local case_home="${TEST_ROOT}/extra-mounts-unset-home"
  local run_args="${case_home}/run-args"

  mkdir -p "${case_home}"

  ( cd "${case_home}" && env -i \
    PATH="${STUB_PATH}:${ORIGINAL_PATH}" \
    HOME="${case_home}" \
    TEST_KEYCHAIN_CLAUDE_CODE_OAUTH_TOKEN="test-oauth-token" \
    TEST_DOCKER_RUN_ARGS_FILE="${run_args}" \
    "${BIN_ROOT}/claude-container" )

  local volume_count
  volume_count="$(grep --count --fixed-strings --line-regexp -- '-v' "${run_args}")"
  [[ "${volume_count}" -eq 2 ]] || \
    fail "an unset CONTAINER_EXTRA_MOUNTS changes the -v flag count from the baseline of 2"
}
```

Wire all four into `main()`: insert the matching calls right before the existing
`test_container_help_does_not_require_docker` call (around line 428, immediately after the
`test_ambient_github_token_is_not_forwarded_without_opt_in` / its `PASS:` line):

```zsh
  test_extra_mount_is_added_read_write
  print -r -- "PASS: CONTAINER_EXTRA_MOUNTS path is mounted read-write"
  test_extra_mounts_multiple_paths_each_added
  print -r -- "PASS: multiple CONTAINER_EXTRA_MOUNTS paths are each mounted"
  test_extra_mount_missing_path_is_skipped_with_warning
  print -r -- "PASS: a missing CONTAINER_EXTRA_MOUNTS path is skipped with a warning"
  test_extra_mounts_unset_adds_no_extra_volume
  print -r -- "PASS: an unset CONTAINER_EXTRA_MOUNTS adds no extra volume"
```

- [ ] **Step 2: Run the suite and confirm the new assertions fail**

Run: `./tests/test-claude-container`

Expected: `test_extra_mount_is_added_read_write` and
`test_extra_mounts_multiple_paths_each_added` fail (`CONTAINER_EXTRA_MOUNTS` is set but nothing
reads it yet, so no matching `-v` line exists). `test_extra_mount_missing_path_is_skipped_with_warning`
fails on the warning-text assertion (nothing warns yet). `test_extra_mounts_unset_adds_no_extra_volume`
passes already — that's expected, since it's a regression guard for behavior that doesn't exist
yet to break; it stays in the suite so Step 4 proves the implementation doesn't change the unset
case.

- [ ] **Step 3: Implement `CONTAINER_EXTRA_MOUNTS` in `scripts/claude-container`**

Find this block (currently the last two lines of the shared credential-mount section, right
before the flavor-specific `if [ "$TOOL_FLAVOR" = "codex" ]` branch):

```bash
[ -d "${HOME}/.aws" ] && VOLUMES+=(-v "${HOME}/.aws:/home/pde/.aws:ro")
[ -d "${HOME}/.config/gh" ] && VOLUMES+=(-v "${HOME}/.config/gh:/home/pde/.config/gh:ro")
```

Insert immediately after it, still before `if [ "$TOOL_FLAVOR" = "codex" ]; then`:

```bash

# Extra sibling-repo mounts: CONTAINER_EXTRA_MOUNTS is a colon-separated list of absolute host
# paths, for a project whose own docs cross-reference a paired checkout (a fork, a companion
# repo). Each is mounted read-write at its own path, same as the current directory above. A path
# that doesn't exist gets a warning, not a hard failure, matching the ~/.gitconfig pattern above.
if [ -n "${CONTAINER_EXTRA_MOUNTS:-}" ]; then
  IFS=':' read -ra EXTRA_MOUNTS <<<"${CONTAINER_EXTRA_MOUNTS}"
  for extra_mount in "${EXTRA_MOUNTS[@]}"; do
    [ -n "${extra_mount}" ] || continue
    if [ -d "${extra_mount}" ]; then
      VOLUMES+=(-v "${extra_mount}:${extra_mount}")
    else
      echo "Warning: CONTAINER_EXTRA_MOUNTS path not found, skipping: ${extra_mount}" >&2
    fi
  done
fi
```

- [ ] **Step 4: Add `CONTAINER_EXTRA_MOUNTS` to the `--container-help` text**

Find this line in the `HELP` heredoc:

```
  CLAUDE_GITHUB_TOKEN       GitHub personal access token for gh CLI
```

Insert immediately after it:

```
  CONTAINER_EXTRA_MOUNTS    Colon-separated extra host paths to mount read-write (e.g. a sibling
                            repo a project's docs cross-reference)
```

- [ ] **Step 5: Run the suite and confirm everything passes**

Run: `./tests/test-claude-container`

Expected: every `PASS:` line prints, including the four new ones, with no `FAIL:` output and exit
0. This also confirms every pre-existing test (which never sets `CONTAINER_EXTRA_MOUNTS`) still
passes unchanged.

- [ ] **Step 6: Commit**

```bash
git add scripts/claude-container tests/test-claude-container
git commit -m "feat(scripts): mount extra sibling repos via CONTAINER_EXTRA_MOUNTS

Reads a new colon-separated env var the same way the script already reads
AWS_PROFILE, and appends a read-write -v mount per existing path, at the
same host path inside the container. A path that doesn't exist warns and
is skipped rather than failing the launch. Applies to all three flavors,
since it lives in the shared mount-building section rather than any
flavor-specific branch."
```

---

### Task 2: Document `CONTAINER_EXTRA_MOUNTS`

**Files:**
- Modify: `docs/agents/building.md`

**Interfaces:**
- Consumes: Task 1's `CONTAINER_EXTRA_MOUNTS` support.
- Produces: nothing consumed by a later task in this repo (Task 3 is a separate, external repo).

- [ ] **Step 1: Extend the "Launch from another repo" section**

Find this paragraph (the last paragraph of the "Launch from another repo" section, immediately
before the "Sign Claude Code in to the container" subsection):

```markdown
Unlike `docker compose run`, this launcher mounts the current directory read-write, plus host
credentials: `~/.gitconfig`, `~/.aws`, and `~/.config/gh` read-only, and the per-tool config
directories (`~/.claude`, `~/.codex`, `~/.gemini`, `~/.config/gcloud`) read-write, on top of the
same 1Password SSH-agent forwarding `compose.yaml` uses. See
[the launcher design](../superpowers/specs/2026-08-18-container-launcher-design.md) for the full
mount table and the reasoning behind the credential-mount decisions.
```

Insert a new paragraph immediately after it:

```markdown
A project that cross-references a sibling checkout — a fork, a paired repo, docs with hardcoded
absolute paths into it — can have that checkout mounted alongside the current directory too, via
`CONTAINER_EXTRA_MOUNTS` (colon-separated absolute host paths, mounted read-write at their own
paths, same as the current directory):

```zsh
CONTAINER_EXTRA_MOUNTS=/Users/pde/src/github.com/pdehlke/homie-dashboard claude-container
```

Set it durably for a given project with a `.envrc` (direnv) in that project's own repo, so it
applies automatically on `cd` rather than needing to be remembered per launch. See
[the multi-repo mounts design](../superpowers/specs/2026-08-19-multi-repo-mounts-design.md) for
why this mechanism was chosen over a project-local manifest file or a CLI flag.
```

- [ ] **Step 2: Commit**

```bash
git add docs/agents/building.md
git commit -m "docs(building): document CONTAINER_EXTRA_MOUNTS for sibling-repo launches"
```

---

### Task 3: Add `homeassistant/.envrc`

**Files:**
- Create: `/Users/pde/src/github.com/pdehlke/homeassistant/.envrc` (a different repo — not
  tracked by this plan's git history, and outside this repo's normal scope; included because the
  user asked for it in the same pass as this change).

**Interfaces:**
- Consumes: Task 1's `CONTAINER_EXTRA_MOUNTS`.
- Produces: nothing consumed by a later task; this is the last task.

- [ ] **Step 1: Write the file**

Create `/Users/pde/src/github.com/pdehlke/homeassistant/.envrc`:

```sh
# Mount the homie-dashboard fork alongside homeassistant in claude-container/codex-container/
# gemini-container, since homeassistant's docs cross-reference it at this path.
export CONTAINER_EXTRA_MOUNTS=/Users/pde/src/github.com/pdehlke/homie-dashboard
```

- [ ] **Step 2: Trust it with direnv**

Run, from inside `/Users/pde/src/github.com/pdehlke/homeassistant`:

```zsh
direnv allow
```

Expected: direnv prints nothing on success (or a brief confirmation depending on version); a
subsequent `cd` into that directory (or `direnv reload` from inside it) exports
`CONTAINER_EXTRA_MOUNTS`. Verify with:

```zsh
cd /Users/pde/src/github.com/pdehlke/homeassistant && echo "${CONTAINER_EXTRA_MOUNTS}"
```

Expected output: `/Users/pde/src/github.com/pdehlke/homie-dashboard`.

- [ ] **Step 3: Verify a real launch mounts both repos**

From inside `/Users/pde/src/github.com/pdehlke/homeassistant`, with Docker Desktop running and
the image already built (`docker image inspect claude-code-dev:latest` succeeds):

```zsh
claude-container bash -c 'ls /Users/pde/src/github.com/pdehlke/homeassistant >/dev/null && ls /Users/pde/src/github.com/pdehlke/homie-dashboard >/dev/null && echo BOTH_MOUNTED'
```

Expected output: `BOTH_MOUNTED`. This is a manual check, not part of the automated suite — it
needs a real Docker Desktop session and the built image, the same manual-verification carve-out
`docs/agents/building.md` already documents for SSH-agent forwarding.

- [ ] **Step 4: Commit in the `homeassistant` repo**

This commit is in a different repository from every other task in this plan.

```zsh
cd /Users/pde/src/github.com/pdehlke/homeassistant
git add .envrc
git commit -m "chore: mount homie-dashboard alongside homeassistant in claude-container"
```

Follow that repo's own commit conventions if they differ from this one's; check its `CLAUDE.md`/
`AGENTS.md` before committing if unsure.

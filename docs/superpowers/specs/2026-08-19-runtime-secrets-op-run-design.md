# Runtime secrets design

## Context

A project's coding-agent session sometimes needs a secret that isn't SSH or Git auth: a JWT for
an internal API, a database password, a site login. `build.zsh` already resolves two specific
1Password references at build time (`docs/agents/building.md:28-31`), but nothing in this repo
addresses secrets a project itself needs at runtime, whether that session runs on the host or in
the container `scripts/claude-container` launches.

A conversation with another agent (kept outside this repo) proposed 1Password's `op run` for
this, and separately proposed making it work for a containerized session by bind-mounting
1Password's desktop-app integration socket into the container, alongside the SSH-agent socket
this repo already forwards.

## Prior art checked

The desktop-app socket idea was checked against current 1Password documentation and community
discussion before building anything on it. It doesn't work: unlike the SSH-agent socket (which
speaks a generic protocol Docker Desktop already proxies at
`/run/host-services/ssh-auth.sock`, see `docs/agents/building.md:48-50`), the desktop-app
integration socket has no supported path into a Linux container. 1Password's own guidance for
containers is [Connect](https://developer.1password.com/docs/connect/) or a [Service
Account](https://developer.1password.com/docs/service-accounts/), and Service Accounts explicitly
cannot read Private vaults, which is where these secrets already live (the same vault
`build.zsh`'s two references come from). Running `op` inside the container was dropped for this
reason, which also meant not reversing the documented "`op` stays on host" decision
(`docs/agents/building.md:37-39`).

`op run`, invoked with no flags, was then confirmed (against [1Password's CLI
reference](https://developer.1password.com/docs/cli/reference/commands/run)) to scan its own
process environment for `op://vault/item/field` values and resolve them for the wrapped
subprocess, not just values named in an `--env-file`. That's the mechanism both facilities below
use.

## Approaches considered

| Approach | Verdict |
| --- | --- |
| Host and container launchers wrap the target process in `op run --`; a project sets `VARNAME=op://...` in its own `.envrc`/mise config | **Chosen.** No new file format in this repo. Reuses the same durability pattern `CONTAINER_EXTRA_MOUNTS` already established (`docs/superpowers/specs/2026-08-19-multi-repo-mounts-design.md:35`), and `op run`'s own environment scan does the resolution. |
| Project-local manifest file (e.g. `.env.1password`) parsed by this repo's scripts | Rejected. Same reasoning already recorded for `CONTAINER_EXTRA_MOUNTS`: a new format and parser to maintain here for a capability plain env vars already provide. |
| Install `op` in the image, resolve secrets inside the container | Rejected. Reverses a documented decision and doesn't solve the socket problem above; host-side resolution needs neither. |
| Service Account token for in-container `op` | Rejected. Cannot read the Private vault these secrets already live in. |

## Mechanism

**Host**: `scripts/op-claude` (with `op-codex`/`op-gemini` hardlinks, installed by `make install`
alongside `claude-container`'s) execs `op run -- claude "$@"` (or `codex`/`gemini`), using the
same `$SELF`-based flavor dispatch and arbitrary-command passthrough as `claude-container`. No
Keychain fallback, no `--yolo` injection, no mounts: those exist in `claude-container` to bridge
macOS-only state into Linux, and none of that applies on bare host.

**Container**: `scripts/claude-container` scans its own environment (`compgen -e`) for exported
variables whose *value* starts with `op://`, skipping names it already forwards explicitly
(`OPENAI_API_KEY` and the rest) so a var handled both ways doesn't produce a duplicate `-e` flag.
Each match's name (never its value) becomes a bare `-e VARNAME`, matching the existing
`CLAUDE_CODE_OAUTH_TOKEN`/`GITHUB_TOKEN` pattern for keeping secrets off the argv `ps` exposes.
The whole `docker run` invocation is wrapped in `op run --` only when at least one match was
found, so a project that never uses this facility never gains a new dependency on `op` being
installed or authenticated on the host.

Neither facility touches `compose.yaml`, the `Dockerfile`, or installs `op` in the image.

**Confirmed by real use, not just design**: an early run of `op-claude` against a real vault item
(`HA_TOKEN` in the `homeassistant` repo) failed immediately with Claude Code demanding `--print`.
Root cause, confirmed against [1Password's own community
thread](https://www.1password.community/discussions/developers/op-run-changes-stdout-and-stderr-to-not-be-ttys-when-masking/26040):
`op run`'s secret masking makes stdout and stderr non-TTY streams by default (stdin stays a TTY),
and Claude Code's REPL requires a real TTY on stdout to start interactively. `--no-masking`
restores it. Both launchers now pass `--no-masking` only when the invocation is genuinely
interactive (`stdin` and `stdout` both TTYs), so the masking safety net stays intact for
piped/redirected use, where there's no TTY to lose anyway. Confirmed working after the fix for
both interactive `op-claude` and interactive `claude-container` sessions.

A second rough edge surfaced the same way, in the same session, and was deliberately left
undocumented-as-a-bug rather than fixed: `claude-container zsh` in the `homeassistant` repo, which
also manages its environment with mise-en-place, lost the resolved `HA_TOKEN` value again once
mise's own shell hook fired, replacing it with mise's own (unresolved) view of that variable from
its config file. `op` isn't installed in the image for mise to resolve the reference itself. Not
worth chasing unless it becomes a real annoyance; see `docs/agents/building.md`'s "Runtime secrets
with `op run`" section for the full note.

## Docs touched

- `docs/agents/building.md`: new "Runtime secrets with `op run`" section near "Launch from
  another repo", covering both launchers, the `.envrc` durability pattern, and the argv-safety
  property.
- `scripts/claude-container`'s `--container-help` text: a paragraph on the `op://` scan.
- `README.md`: add this spec to the Designs list.

## Testing

- `tests/fixtures/bin/op`: a `run` case that captures its own argv to `TEST_OP_RUN_ARGS_FILE`,
  then either `exec`s the wrapped command (`TEST_OP_RUN_EXEC=1`, used when the target is another
  stub, e.g. `docker`) or exits, since `claude`/`codex`/`gemini` have no fixture of their own.
- `tests/test-claude-container`: an `op://`-valued var wraps `docker run` in `op run` and forwards
  only its name; no such var leaves `docker run`'s argv unchanged from today; a var already
  forwarded by name produces exactly one `-e` flag, not two.
- New `tests/test-op-claude`: flavor dispatch, flag forwarding, the arbitrary-command case, the
  missing-`op` error path, and `--container-help`.

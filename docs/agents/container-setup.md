# Running a coding agent in a container for this repo and homie-dashboard

Prospective, not built yet. This records what a Docker container would need to hold, in order
for a coding agent to work on this repo (`pdehlke/homeassistant`) and its sibling checkout
`pdehlke/homie-dashboard` the way work has actually been done from this machine. Facts below were
verified against the live host on 2026-08-18: CLI versions, `~/.claude` config, the repo's own
skill, and the homie-dashboard checkout itself. The one thing not verified is whether a container
can actually reach the internal LAN; see [Network reachability](#network-reachability).

## Runtimes and CLIs

| Tool | Verified detail | Why it's needed |
| --- | --- | --- |
| Claude Code | `2.1.234`, native installer (`installMethod: native`) | The agent itself. Use the native install script in the image, not npm-global, to match how updates behave on the host. |
| Node.js | `v24.13.0` / npm `11.6.2` | Runs `npx playwright`, and is sufficient on its own for homie-dashboard's tests. |
| Python 3 | ambient `python3` has no `aiohttp` | `.claude/skills/home-assistant/scripts/haws.py` (the WebSocket client used for Lovelace and registry edits) imports `aiohttp`. It must be installed explicitly (`pip install aiohttp`); it is not present by default even on the host. |
| git + SSH | git protocol for `gh` is `ssh` | Clone, push, and sign commits. |
| gh | `2.92.0`, keyring-backed OAuth, scopes `admin:public_key, gist, read:org, repo` | Issue tracker work (`docs/agents/issue-tracker.md`) and PRs against the homie-dashboard fork. |
| Playwright | not installed globally on the host; pulled on demand via `npx playwright` | Live visual verification of Homie Dashboard changes, per this repo's "Reviewing code changes" convention in [CLAUDE.md](../../CLAUDE.md). In a Linux container, run `npx playwright install --with-deps chromium` at build or first run. |
| semgrep | Homebrew install on host, `1.170.0` | Backs the Semgrep Guardian plugin's findings tools. `pip install semgrep` on Linux. |

homie-dashboard has no `package.json` and no npm build step. Its test suite
(`test/screen-a.test.cjs`) runs on Node's built-in test runner:

```
node --test test/screen-a.test.cjs
```

Node alone covers it; there is nothing to `npm install`.

## Repo layout

Mount both repos as siblings, at the exact paths used on the host:

```
/Users/pde/src/github.com/pdehlke/homeassistant/
/Users/pde/src/github.com/pdehlke/homie-dashboard/
```

This repo's `CLAUDE.md` handoff instructions and the home-assistant skill's "Homie Dashboard
fork" section hardcode those absolute paths. Remapping to something like `/workspace/...` would
break every cross-reference.

homie-dashboard carries two remotes worth preserving: `origin` (`pdehlke/homie-dashboard`, the
fork) and `upstream` (`Big-Edge2297/homie-dashboard`).

## Identity, git, GitHub

- `user.name` / `user.email` (`Pete Ehlke` / `pde@rfc822.net`) are set at repo scope on the host,
  not `--global`. Set them however the container is provisioned; don't assume a global config
  supplies them.
- Commits are SSH-signed (`commit.gpgsign=true`, `gpg.format=ssh`), with `user.signingkey` set to
  an SSH **public** key. The matching private key is not a plain file to copy; it is backed by an
  SSH agent (Secretive, 1Password, or similar), not `~/.ssh/id_*` in cleartext. The clean
  container answer is SSH agent forwarding (mount the host's `SSH_AUTH_SOCK`), not placing key
  material in the image.
- `gh` is authenticated via the OS keyring on the host. That doesn't travel. Run `gh auth login`
  fresh inside the container, or pass a scoped `GH_TOKEN`.
- Because `gh`'s git protocol is `ssh`, cloning and pushing homie-dashboard also needs that same
  forwarded agent, holding a key GitHub recognizes for the `pdehlke` account.

## Home Assistant and Homie access

- `$HA_TOKEN`: a full-admin long-lived HA access token, read from the environment by every skill
  script and by the "HA" MCP server. Inject at container run time (`-e HA_TOKEN=...` or a mounted
  secret file), never baked into an image layer. See the home-assistant skill's "Never leak the
  token" section (`.claude/skills/home-assistant/SKILL.md`) for the handling rules that apply
  equally inside a container.
- The user-level MCP server is named `HA`: `type: http`, `url: http://hass.ehlke.net:8123/api/mcp`,
  with an `Authorization` header. Reproduce that entry in the container's Claude config (via
  `claude mcp add` or an equivalent `mcpServers` block), sourcing the header value from an
  environment variable rather than a literal.
- Homie's live deploy path is `ssh -p 2222 root@hass.ehlke.net` (SFTP/rsync, the add-on account
  only), using a key normally kept at `/Users/pde/tmp/homie-ha-edit-key`, a credential-handoff
  file that deliberately lives outside both repos. That key, plus
  `/Users/pde/tmp/homie-dashboard-password` and `/Users/pde/tmp/homie-dashboard-token`, need to
  land somewhere the container can read (a mounted secrets directory) and nowhere else.

## Network reachability

**Not verified.** `hass.ehlke.net` and `mass.ehlke.net` are internal-LAN-only DNS names with no
public internet path (see [CLAUDE.md](../../CLAUDE.md)'s "Context worth knowing" section). A
container needs actual routing to the home LAN, not just outbound internet, for the MCP server,
REST/WebSocket calls, and the port-2222 SSH deploy. On Docker Desktop for Mac this usually works
without extra configuration, because the VM shares the Mac's route to the LAN and forwards DNS,
but that is an assumption based on how Docker Desktop networking generally behaves, not something
tested from a container on this machine. Confirm it explicitly before relying on it:

```
curl http://hass.ehlke.net:8123/api/ -H "Authorization: Bearer $HA_TOKEN"
```

If that fails, host networking, a macvlan, or a VPN sidecar would be the next things to try, but
none of that has been evaluated here.

## Claude Code config and skills

- The `home-assistant` skill and its scripts ship inside this repo
  (`.claude/skills/home-assistant/`), so mounting the repo is enough to get it. No extra copying.
- Everything else visible from a normal session on the host (superpowers, `home-assistant-skills`,
  `semgrep`, `chezmoi`, `frontend-design`, the LSP plugins) comes from `~/.claude/settings.json`'s
  `enabledPlugins` and `extraKnownMarketplaces`, each pulled from a separate GitHub repo. To match
  that, either reinstall the plugins inside the container (needs GitHub network access, and
  `claude plugin install` per marketplace) or copy `~/.claude/plugins` wholesale into the
  container's `~/.claude`.
- Global personal skills (`security`, `commenting`, `python`, `typescript`, `playwright-cli`, and
  the rest) are plain directories under `~/.claude/skills`. Copying that directory in is the whole
  mechanism.
- The host's global `settings.json` is chezmoi-managed (a symlink into `~/.yadr-private`) and
  wires `workmux`/tmux-resurrect hooks (`Notification`, `PostToolUse`, `Stop`, `SessionStart`,
  `SessionEnd`) that assume a host tmux session. Those will fail or no-op in a headless container;
  strip them for a container-specific settings profile instead of porting them as-is. Keep the
  `permissions.deny` list (it blocks reading `.env`, `~/.ssh/**`, credential files, and similar)
  and the `autoMode` block, since those are the same guardrails around `$HA_TOKEN` handling that
  this repo's skill assumes are in effect.
- Auth for Claude Code itself lives in `~/.claude/.credentials.json` (an OAuth session). Either
  mount that file read-only, treating it like any other bearer credential, or run `claude login`
  fresh inside the container.

## What to keep out of the image entirely

`$HA_TOKEN`, the SSH deploy key and the two Homie handoff files under `/Users/pde/tmp`, the
git-signing agent socket, `~/.claude/.credentials.json`, and any `gh`/GitHub token. All of these
belong as runtime mounts or environment variables on `docker run`, never `COPY`'d into a layer,
for the same reason this repo's own skill forbids letting `$HA_TOKEN` enter a printed command.

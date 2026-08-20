# Container requirements for running a coding agent

Prospective, not built yet. This records what a Docker container needs to hold for Claude
Code, Codex, or Gemini CLI to work the way work has actually been done from this machine, independent
of whichever project repo ends up mounted into it. CLI versions and `~/.claude` config below
were verified against the live host on 2026-08-18. The one thing not verified is whether the
container can actually reach a private network some project depends on; see
[Network reachability](#network-reachability).

## Runtimes and CLIs

| Tool | Verified detail | Why it's needed |
| --- | --- | --- |
| Claude Code | `2.1.234`, native installer (`installMethod: native`) | The agent itself. Use the native install script in the image, not npm-global, to match how updates behave on the host. |
| Node.js | `v24.13.0` / npm `11.6.2` | Runs `npx`-based tooling (Playwright, and most JS project tests). |
| Python 3 | ambient `python3` is stdlib-only, no extra packages | Skill scripts and MCP servers commonly need packages beyond stdlib (e.g. `aiohttp` for a WebSocket client). Install what a given project needs explicitly; don't assume it's present. |
| git + SSH | `gh`'s git protocol is `ssh` | Clone, push, and sign commits. |
| gh | `2.92.0`, keyring-backed OAuth, scopes `admin:public_key, gist, read:org, repo` | Issue tracker work (see [docs/agents/issue-tracker.md](issue-tracker.md)) and PRs. |
| Playwright | not installed globally on the host; pulled on demand via `npx playwright` | Live visual verification of UI changes, for projects whose review convention calls for it. In a Linux container, run `npx playwright install --with-deps chromium` at build or first run. |
| semgrep | Homebrew install on host, `1.170.0` | Backs the Semgrep Guardian plugin's findings tools. `pip install semgrep` on Linux. |
| ccstatusline | `2.2.22`, installed as a global npm package under mise's Node | Renders Claude Code's status line. Its own installer is an interactive TUI, so the container installs the pinned npm package directly rather than running it; the rendered config comes along for free because `~/.config/ccstatusline/settings.json` is chezmoi-managed in the public dotfiles repo and `~/.claude/settings.json`'s `statusLine` entry is carried in by the `~/.claude` bind mount (see [Claude Code config and skills](#claude-code-config-and-skills)). |

Whether a project needs an `npm install` or has its own build step is project-specific; check
that project's own docs rather than assuming one pattern here.

## Repo layout

Project repos mount as bind mounts at whatever path the container is given. If a project's own
docs or `CLAUDE.md`/`AGENTS.md` hardcode absolute host paths in cross-references (a handoff
note pointing at `/Users/you/src/...`, for instance), keep the container's mount path identical
to the host path rather than remapping to something like `/workspace/...`. Remapping breaks
every such cross-reference silently, and there's no general way to detect that it happened.

When a project depends on a sibling checkout (a fork of an upstream project, a paired
repo), mount both at the paths their own cross-references assume, and preserve whatever
remotes that project's workflow relies on (e.g. `origin` pointing at a fork, `upstream`
pointing at the project it was forked from).

## Identity, git, GitHub

- `user.name` / `user.email` are commonly set at repo scope on a host, not `--global`. Set them
  however the container is provisioned; don't assume a global config supplies them.
- Commits may be SSH-signed (`commit.gpgsign=true`, `gpg.format=ssh`), with `user.signingkey`
  set to an SSH **public** key. The matching private key is not a plain file to copy; it's
  typically backed by an SSH agent (Secretive, 1Password, or similar), not `~/.ssh/id_*` in
  cleartext. The clean container answer is SSH agent forwarding (mount the host's
  `SSH_AUTH_SOCK`), not placing key material in the image.
- Verified on this host: `user.signingkey` and `gpg.ssh.program` live in `~/.gitconfig.user`, a
  file `~/.gitconfig` pulls in via `include.path` rather than setting directly. A launcher that
  mounts only `~/.gitconfig` doesn't carry those two settings in; git ignores the missing include
  silently rather than erroring, so the gap shows up only as signing failing, not as a broken
  `git` invocation. `gpg.ssh.program` here is also set to
  `/Applications/1Password.app/Contents/MacOS/op-ssh-sign`, a macOS app binary that cannot run in
  a Linux image regardless of what gets mounted. Read the host's effective `user.signingkey` at
  launch time instead (a public key, safe to forward) and force `gpg.ssh.program` to the
  container's own `ssh-keygen`, git's default SSH signer, which resolves a bare public key
  against whatever agent `SSH_AUTH_SOCK` points to, over the same forwarded agent socket plain
  SSH auth already uses.
- `gh` is commonly authenticated via the OS keyring on a host. That doesn't travel. Run
  `gh auth login` fresh inside the container, or pass a scoped `GH_TOKEN`.
- Because `gh`'s git protocol is `ssh`, cloning and pushing over that protocol also needs that
  same forwarded agent, holding a key GitHub recognizes for the account being used.

## Project-specific service credentials

Some projects need access to an external service the agent has to authenticate against: an
internal API, an admin panel, a deploy target reached over SSH. None of that is generic to this
container, and it doesn't belong documented here; it belongs in that project's own repo. The
pattern that does generalize: inject the credential at container run time, as an environment
variable or a mounted secret file, never baked into an image layer, and follow whatever MCP
server or skill-script wiring that project already uses to get the credential to the tool that
needs it.

## Network reachability

**Not verified for any specific target.** If a project depends on a private network resource
(an internal LAN service, a VPN-gated endpoint, anything with no public internet path), the
container needs actual routing to that network, not just outbound internet access. On Docker
Desktop for Mac this usually works without extra configuration, because the VM shares the Mac's
route to the LAN and forwards DNS, but that's an assumption based on how Docker Desktop
networking generally behaves, not something tested from a container on this machine. Confirm
reachability explicitly for whatever endpoint a project actually needs, for example:

```
curl <health-check-or-status-endpoint>
```

If that fails, host networking, a macvlan, or a VPN sidecar would be the next things to try, but
none of that has been evaluated here.

## Claude Code config and skills

- A repo-scoped skill (living in a project's own `.claude/skills/`) ships with that project;
  mounting the repo is enough to get it, no extra copying.
- Everything else visible from a normal session on the host (installed plugins such as
  superpowers, semgrep, chezmoi, frontend-design, and any LSP plugins) comes from
  `~/.claude/settings.json`'s `enabledPlugins` and `extraKnownMarketplaces`, each pulled from a
  separate GitHub repo. To match that, either reinstall the plugins inside the container (needs
  GitHub network access, and `claude plugin install` per marketplace) or copy
  `~/.claude/plugins` wholesale into the container's `~/.claude`.
- Global personal skills (`security`, `commenting`, `python`, `typescript`, `playwright-cli`,
  and the rest) are plain directories under `~/.claude/skills`. Copying that directory in is the
  whole mechanism.
- A host's global `settings.json` may be dotfile-managed (a symlink into a separate dotfiles
  repo) and wire hooks (`Notification`, `PostToolUse`, `Stop`, `SessionStart`, `SessionEnd`)
  that assume a host terminal-multiplexer session. Those will fail or no-op in a headless
  container; strip them for a container-specific settings profile instead of porting them as-is.
  Keep the `permissions.deny` list and the `autoMode` block, since those are the same guardrails
  around credential handling that a project's own skills and scripts assume are in effect.
- Auth for Claude Code itself lives in `~/.claude/.credentials.json` (an OAuth session). Either
  mount that file read-only, treating it like any other bearer credential, or run `claude login`
  fresh inside the container.

## What to keep out of the image entirely

Any project-specific service credential (API token, deploy key, admin password), the
git-signing agent socket, `~/.claude/.credentials.json`, and any `gh`/GitHub token. All of these
belong as runtime mounts or environment variables on `docker run`, never `COPY`'d into a layer.

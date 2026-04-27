# claude-docker

Run [Claude Code](https://docs.claude.com/en/docs/claude-code) inside a minimal Docker container as a tmux session, with credentials roaming through an [rclone](https://rclone.org) remote so you don't re-authenticate on every machine.

## What this gives you

- A `claude-code` Docker image with `tmux`, `git`, `ripgrep`, `rclone`, and Claude Code pre-installed
- A non-root user `claude-runner` (UID 1000) so `claude --dangerously-skip-permissions` works (it's blocked as root)
- An entrypoint that opens a named tmux session `claude` with three windows:
  - **agent** — pane running `claude --dangerously-skip-permissions`
  - **shell** — bash for `git`/`rg`/etc.
  - **logs** — tail of `~/.claude/history.jsonl`
- A `cdocker` wrapper that bind-mounts your local rclone config into the container; the container itself runs `rclone copy` to pull credentials at startup and push rotated tokens back on exit

## Architecture

```
host                                 container
─────────────                        ─────────────────────────────────
~/.config/rclone/  ──bind-mount──►  /home/claude-runner/.config/rclone/
                                    └─► entrypoint runs:
                                        rclone copy <remote>/.credentials.json …
                                        tmux new-session -d -s claude …
                                        tmux attach
                                    └─► trap on EXIT pushes rotated
                                        .credentials.json back to remote
$PWD              ──bind-mount──►  same path inside (so trust prompts and
                                    history align with the host)
```

The container has **no** `~/.claude/` bind-mount from the host — credentials come from rclone, and any session/history state inside `~/.claude/` is ephemeral by design.

## Prerequisites

- Docker (daemon running)
- An rclone remote already configured on your host (`rclone config`) pointing at the storage backend you want to keep credentials on (Google Drive, S3, B2, WebDAV — anything rclone supports)
- A working Claude Code login on at least one machine, so `~/.claude/.credentials.json` exists to seed the remote

## Setup

```bash
git clone <this-repo> ~/projects/claude-docker
cd ~/projects/claude-docker

cp .env.template .env
$EDITOR .env                       # set CDOCKER_REMOTE at minimum

# Seed the remote with your live credentials (run on the host where 'claude'
# is logged in). cdocker-push handles the rclone mkdir + uploads.
./cdocker-push

# Build the image (does NOT need to be re-run on subsequent launches)
./cdocker --build-only
# ^ equivalent to:  docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) -t $CDOCKER_IMAGE .
```

## Usage

```bash
cd ~/some/project
~/projects/claude-docker/cdocker
```

That's it — tmux opens, the agent pane is already running Claude. Detach with `Ctrl-b d` (or just exit Claude); the container pushes rotated tokens back to the remote and exits.

### Per-invocation overrides

```bash
# Different rclone config (e.g., a work account)
cdocker --rclone-conf ~/.config/rclone/rclone-work.conf

# Different remote/path
cdocker --remote work-drive:/team-claude/deploy

# Both
cdocker --rclone-conf ~/.config/rclone-work.conf --remote work-drive:/team/deploy

# Force a rebuild before running (after Dockerfile or entrypoint changes)
cdocker --build

# Build only, don't run (CI / first-time setup)
cdocker --build-only
```

### Why `--build` injects UID/GID automatically

`./cdocker --build` passes `--build-arg UID=$(id -u) --build-arg GID=$(id -g)` to `docker build`. The image's `claude-runner` user is created with whatever UID/GID the calling user has on that host. This means:

- Files written by the container (via the `$PWD` bind-mount) end up owned by *you*, not by some random UID 1000 that may not exist on this machine.
- The same image works correctly on hosts where your user is UID 1001, 1500, or anything else — without the wrapper's mount needing a `--user` override at runtime.

## Unknown-host workflow (the design point)

The default mode is built for "I want to run Claude on a host I don't control" — a borrowed laptop, a CI runner, a friend's machine. The remote host needs only Docker plus an rclone config that can read/write the credential remote. It does **not** need Claude Code installed or pre-authenticated.

Anthropic rotates refresh tokens server-side on every successful refresh, so the *only* host with a valid refresh token at any moment is the host whose container last ran. If you run on host A, then on host B without first refreshing, B starts with the token A already invalidated. The fix is the two-step push-then-pull:

```bash
#  step 1 — on a host you trust, where 'claude' is authenticated:
~/projects/claude-docker/cdocker-push

#  step 2 — on the unknown host:
~/projects/claude-docker/cdocker
```

`cdocker-push` uploads this host's live `~/.claude/.credentials.json` and `~/.claude.json` to the remote. The next `cdocker` launch on any host pulls those tokens. Re-run `cdocker-push` whenever a remote-host launch fails to authenticate, or whenever you re-auth `claude` on the trusted host.

### Verifying auth without committing to tmux

```bash
cdocker --verify
```

Skips tmux and runs `claude -p "respond with: PONG"` non-interactively against the pulled credentials. Exits 0 on success, non-zero with a hint to run `cdocker-push` if auth fails. Use this on the unknown host as the first sanity check after `cdocker-push` finishes on the trusted host.

## Caveats

- **Don't run on two machines simultaneously.** rclone has no atomic compare-and-swap; the last machine to push wins on token rotation. Refresh tokens are long-lived enough that you usually won't get hard-bounced to OAuth, but you can lose an access-token rotation.
- **Single point of failure.** If you delete the remote credentials by accident, every host loses access until you re-authenticate from somewhere with `claude` and re-bootstrap the remote.
- **No state persistence.** Sessions, MCP server registrations, and `history.jsonl` are not synced. Add them to the entrypoint's `push_back` if you want them to roam, at the cost of more Drive I/O per launch.
- **`--dangerously-skip-permissions` lives up to its name.** Inside the container, Claude can do anything the `claude-runner` user can — read your project files, run shell commands, talk to the internet. The container is a bag of trust around `$PWD`. Don't bind-mount paths you don't want Claude to touch.

## File layout

| File | Role |
|---|---|
| `Dockerfile` | Image recipe (node:22-slim base, claude-runner user, COPY of entrypoint + tmux.conf) |
| `cdocker` | Host-side launcher: parses flags/env, mounts rclone config, runs the image |
| `cdocker-push` | Host-side credential refresher: uploads this host's live `~/.claude/` to the rclone remote (run on a trusted host before launching cdocker on an unknown one) |
| `cdocker-entrypoint` | In-container PID 1: rclone-pulls creds, builds tmux session, traps EXIT to push back |
| `tmux.conf` | tmux options — pane border on top so titled panes render |
| `.env.template` | Variables the wrapper reads — copy to `.env` (gitignored) |
| `.gitignore`, `.dockerignore` | Keep `.env` out of git history and image layers |

## Override a different host UID

If your host UID isn't 1000:

```bash
docker build \
  --build-arg UID=$(id -u) \
  --build-arg GID=$(id -g) \
  -t claude-code .
```

## License

MIT — see your fork's LICENSE if you add one.

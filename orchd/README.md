# gt-orch-server — autonomous orchestration daemon (hq-orchd-deploy)

Runs the gt-core orchestration daemon **on the nixos host** (not containerized): it spawns
polecats via `tmux` running `claude`, which the slim mcp-server image can't host. Shares the
docker `gt-app_gt-eventlog` volume with the containerized `gt-mcp-server` so both read/write the
same per-workspace event log.

## Status — code complete, daemon NOT running (awaiting the .5 GO)
- `gt-orch-server` binary built (`cargo build --release -p gt-composition --bin gt-orch-server`)
  and staged here. Boot is OFF-safe (anchors actors, `/metrics` 200, clean SIGTERM drain, no
  polecat slung without a `scheduling.dispatched.v1`).
- All code beads landed on main: deploy .1–.4, .7, .8; agent-provisioning .1–.4, .6, **.7**
  (predictive account rotation), and **.9** (per-polecat git worktrees). Staged binary includes them.
- Host = this nixos host (`tmux` ✓, `claude` ✓).

## What each new knob does (see orchd.env)
- `GT_DISPATCH_CHANNEL` (.4) — drop `{"bead","priority"}` → a polecat is slung for that bead.
- `GT_QUOTA_FEED_CHANNEL` (.7 input) — drop `{"account","headers"|"sample"}` → feeds the predictor
  so it rotates the active claude account BEFORE the session limit.
- `GT_CLAUDE_ACCOUNTS` (.7) — `acct=CLAUDE_CONFIG_DIR,…` (first active). ≥2 ⇒ rotation works.
- `GT_POLECAT_WORKTREE_ROOT` (.9) — each polecat gets its own git worktree (branch = bead) off
  `GT_RIG_PATH`; without it, concurrent polecats race on a shared HEAD (only `GT_POOL_SIZE=1` safe).
- `GT_JWT_RS256_PRIVATE_KEY_FILE` (.3) — daemon mints each polecat a least-privilege `GT_TOKEN`.

## The .5 GO runbook (explicit operator decision — spawns REAL paid claude)
Each polecat = a real claude process = cost. Do NOT enable without an explicit decision.

ALREADY PREPARED (no-secret, by the assistant):
- ✅ Rig checkout cloned at `/home/nixos/gt-rig-hq` (on main, has all merged work).
- ✅ `.mcp.json` placed at `/home/nixos/gt-rig-hq/.mcp.json` — provisioning copies it into each
  polecat worktree (hq-orchd-deploy.10), so per-worktree MCP is automatic now.
- ✅ Worktree root `/home/nixos/gt-rig-hq-wt` created (GT_POLECAT_WORKTREE_ROOT).
- ✅ Release binary (A+B: rotation + worktrees) staged here; `orchd.env` filled.

OPERATOR STILL MUST (secrets / sudo / cost):
1. **RS256 key**: place the signing key, set `GT_JWT_RS256_PRIVATE_KEY_FILE` (the same key whose
   public half the gt-mcp-server verifies), else polecats can't drive the tracker.
2. **Claude accounts**: log in ≥2 accounts into separate `CLAUDE_CONFIG_DIR`s and set
   `GT_CLAUDE_ACCOUNTS=acctA=dirA,acctB=dirB` (else a long run hits the session limit).
3. **Volume dirs (sudo)**: `sudo mkdir -p` the channel + heartbeat dirs on the root-owned volume:
   `$GT_CHANNEL_ROOT` and `$GT_HEARTBEAT_DIR` (the shell hooks `touch` the heartbeat; the dir must
   exist). The daemon runs as root so it can read/write them.
4. **Start** (OFF→ON): `sudo ./run.sh` (reads orchd.env; needs the root-owned eventlog volume).
5. **Dispatch one real bead**: drop `{"bead":"<id>","priority":1}` into
   `$GT_CHANNEL_ROOT/dispatch/`. Watch the loop: `scheduling.dispatched.v1` → `agent.spawned.v1` →
   fresh heartbeat → work → merge-ready → `merge.merged.v1` → slot freed.
6. **Off-switch** = kill the process. Monitor `GT_METRICS_BIND` (127.0.0.1:9099).

Sustained multi-bead operation needs the .7 feed actually fed with real ratelimit headers (a
claude-session hook/proxy reporting `anthropic-ratelimit-*` into `GT_QUOTA_FEED_CHANNEL`).

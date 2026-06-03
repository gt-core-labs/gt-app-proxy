# gt-app

Deploy stack for the **gt-core MCP server**. Pulls the published
[`codecsrayo/gt-core-mcp-server`](https://hub.docker.com/r/codecsrayo/gt-core-mcp-server)
image and wires it to Dolt + Postgres.

The surface is **MCP** — consumed via `gt-mcp-cli` and Claude agents against
`http://127.0.0.1:8765/mcp`. No web frontend.

## Stack

| Service | Image | Role |
|---------|-------|------|
| `gt-app-dolt` | `dolthub/dolt-sql-server` | Issues/meta tracking (`hq`) |
| `gt-app-pg` | `postgres:16-alpine` | Durable MCP audit + table dispatch domains |
| `gt-app-mcp-server` | `codecsrayo/gt-core-mcp-server:latest` | gt-core MCP surface |

## Quick start

```bash
cp .env.example .env        # edit secrets
docker compose up -d
curl -s http://127.0.0.1:8765/healthz
```

The MCP endpoint is published on `127.0.0.1:8765` (loopback only). Point an MCP
client at `http://127.0.0.1:8765/mcp`.

## Configuration

- **`.env`** — Postgres credentials, MCP host port, default actor, log level.
  See [`.env.example`](.env.example).
- **`mcp-scope.toml`** — per-actor MCP allow-list (deny-by-default). The default
  `mcp-local` actor has full access for dev; tighten before production.

## Domains

Domain dispatch is live: `agent, convoy, graph, merge, quota, rig, workspace`
(PG-backed + event-sourced under `GT_EVENTLOG_ROOT`) plus `issues`/`meta` on
Dolt `hq`. Domain handler descriptors are not surfaced in `tools/list` (only
issues+meta are) but dispatch works:

```bash
gt-mcp-cli call workspace.list
```

## Updates

The image is rebuilt + pushed by gt-core's `docker-publish` GitHub Actions
workflow on every push to `main`. `pull_policy: always` means a plain
`docker compose up -d` pulls the latest. To redeploy:

```bash
docker compose pull gt-mcp-server && docker compose up -d gt-mcp-server
```

Old image stays cached for rollback; pin a specific build with the immutable
`:sha-<7>` tag if needed.

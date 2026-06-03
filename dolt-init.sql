-- Boot seed for the gt-app Dolt server.
--
-- A fresh dolt-data volume ships no databases. gt-mcp-server connects to `hq` and
-- expects the `issues` table to pre-exist (it is `bd`-owned upstream; this deploy
-- has no `bd`, so the stack seeds the base table itself). gt-mcp-server's
-- ensure_schema then layers the taxonomy columns + phase_frontier on top
-- idempotently. Re-running is safe: every statement is IF NOT EXISTS.
CREATE DATABASE IF NOT EXISTS hq;
USE hq;

CREATE TABLE IF NOT EXISTS issues (
    id                  VARCHAR(255) PRIMARY KEY,
    content_hash        VARCHAR(64),
    title               VARCHAR(500) NOT NULL,
    description         TEXT NOT NULL,
    design              TEXT NOT NULL,
    acceptance_criteria TEXT NOT NULL,
    notes               TEXT NOT NULL,
    status              VARCHAR(32) NOT NULL DEFAULT 'open',
    priority            INT NOT NULL DEFAULT 2,
    issue_type          VARCHAR(32) NOT NULL DEFAULT 'task',
    assignee            VARCHAR(255),
    estimated_minutes   INT,
    created_at          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255) DEFAULT '',
    owner               VARCHAR(255) DEFAULT '',
    updated_at          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at           DATETIME,
    closed_by_session   VARCHAR(255) DEFAULT '',
    external_ref        VARCHAR(255),
    spec_id             VARCHAR(1024)
);

CALL DOLT_COMMIT('-A', '-m', 'gt-app boot seed: hq.issues base table');

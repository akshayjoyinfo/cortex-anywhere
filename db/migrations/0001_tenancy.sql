-- 0001_tenancy.sql
-- Run as cortex_owner (owns tables). The app connects as cortex_app.
-- Fail closed: no tenant set means zero rows; a bad value means an error.

BEGIN;

CREATE EXTENSION IF NOT EXISTS vector;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cortex_app') THEN
    CREATE ROLE cortex_app LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS cortex;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA cortex TO cortex_app;

-- The only way any policy learns the tenant. Set per transaction with
-- set_config('app.tenant_id', $1, true). Empty string after reuse -> NULL.
CREATE OR REPLACE FUNCTION cortex.current_tenant() RETURNS uuid
  LANGUAGE sql STABLE AS
$$ SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid $$;

-- Customers: the contracting company. Platform data, operators only.
-- RLS forced with no policy and no grant: the app role sees zero rows.
CREATE TABLE cortex.customers (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legal_name    text NOT NULL,
  dpa_signed_at timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE cortex.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE cortex.customers FORCE ROW LEVEL SECURITY;

-- Tenants: the isolation unit. One customer may own several tenants
-- (e.g. two business units); they are isolated from each other too.
CREATE TABLE cortex.tenants (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES cortex.customers (id),
  name       text NOT NULL,
  tier       text NOT NULL DEFAULT 'pooled' CHECK (tier IN ('pooled', 'silo')),
  status     text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'quarantined', 'offboarded')),
  -- Runs and episodic memory older than this are purged nightly. Hard cap 180 days.
  run_retention_days int NOT NULL DEFAULT 90 CHECK (run_retention_days BETWEEN 1 AND 180),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE cortex.tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE cortex.tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_self ON cortex.tenants USING (id = cortex.current_tenant());
GRANT SELECT ON cortex.tenants TO cortex_app;

-- Example tenant table: agent definitions -----------------------------
CREATE TABLE cortex.agents (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL DEFAULT cortex.current_tenant() REFERENCES cortex.tenants (id),
  name              text NOT NULL,
  system_prompt     text NOT NULL,
  model             text NOT NULL DEFAULT 'qwen3-14b',
  tools             text[] NOT NULL DEFAULT '{}',
  memory_namespaces text[] NOT NULL DEFAULT '{default}',
  max_steps         int  NOT NULL DEFAULT 8,
  token_budget      int  NOT NULL DEFAULT 20000,
  external_share    boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- Memory: content is ciphertext from Vault Transit (tenant key) -------
CREATE TABLE cortex.memory_item (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL DEFAULT cortex.current_tenant() REFERENCES cortex.tenants (id),
  namespace  text NOT NULL,
  content    bytea NOT NULL,
  embedding  vector(1024) NOT NULL,          -- dimension depends on embedding model (unverified)
  run_id     uuid,
  agent_id   uuid,
  source     text NOT NULL CHECK (source IN ('run', 'mcp:n8n', 'mcp:assistant', 'admin')),
  source_ref text,
  trust      text NOT NULL CHECK (trust IN ('user', 'retrieved')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX memory_item_tenant ON cortex.memory_item (tenant_id, namespace);
CREATE INDEX memory_item_hnsw   ON cortex.memory_item USING hnsw (embedding vector_cosine_ops);

CREATE TABLE cortex.memory_episode (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL DEFAULT cortex.current_tenant() REFERENCES cortex.tenants (id),
  run_id     uuid NOT NULL,
  agent_id   uuid NOT NULL,
  content    bytea NOT NULL,
  source     text NOT NULL,
  source_ref text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Append only audit ---------------------------------------------------
CREATE TABLE cortex.audit_event (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id  uuid NOT NULL DEFAULT cortex.current_tenant() REFERENCES cortex.tenants (id),
  kind       text NOT NULL,
  actor      text NOT NULL,
  detail     jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);

-- One fail closed policy for every tenant table -----------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['agents', 'memory_item', 'memory_episode', 'audit_event'] LOOP
    EXECUTE format('ALTER TABLE cortex.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE cortex.%I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON cortex.%I
         USING (tenant_id = cortex.current_tenant())
         WITH CHECK (tenant_id = cortex.current_tenant())', t);
  END LOOP;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON cortex.agents, cortex.memory_item, cortex.memory_episode TO cortex_app;
GRANT SELECT, INSERT ON cortex.audit_event TO cortex_app;   -- append only

COMMIT;

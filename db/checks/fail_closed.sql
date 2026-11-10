-- CI leak test at the database layer. Seeds two canary tenants as superuser,
-- then acts as cortex_app. Any RAISE EXCEPTION fails the pipeline.
\set ON_ERROR_STOP on

-- Both canaries belong to ONE customer: same customer must still not leak.
INSERT INTO cortex.customers (id, legal_name) VALUES ('00000000-0000-0000-0000-0000000000c1', 'canary-customer');
INSERT INTO cortex.tenants (id, customer_id, name) VALUES
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000c1', 'canary-a'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000c1', 'canary-b');
INSERT INTO cortex.agents (tenant_id, name, system_prompt) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'agent-a', 'CANARY_A'),
  ('00000000-0000-0000-0000-00000000000b', 'agent-b', 'CANARY_B');

SET ROLE cortex_app;

-- 1. No tenant set: zero rows, not all rows.
DO $$ BEGIN
  IF (SELECT count(*) FROM cortex.agents) <> 0 THEN RAISE EXCEPTION 'LEAK: rows visible without tenant'; END IF;
END $$;

-- 2. Tenant A sees exactly its own row and cannot write into B.
BEGIN;
SELECT set_config('app.tenant_id', '00000000-0000-0000-0000-00000000000a', true);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM cortex.agents WHERE system_prompt = 'CANARY_B') THEN RAISE EXCEPTION 'LEAK: A sees B'; END IF;
  IF (SELECT count(*) FROM cortex.agents) <> 1 THEN RAISE EXCEPTION 'A should see exactly one row'; END IF;
  BEGIN
    INSERT INTO cortex.agents (tenant_id, name, system_prompt)
    VALUES ('00000000-0000-0000-0000-00000000000b', 'x', 'x');
    RAISE EXCEPTION 'LEAK: A wrote into B';
  EXCEPTION WHEN insufficient_privilege THEN NULL;   -- RLS WITH CHECK refused it
  END;
END $$;
COMMIT;

-- 3. Customers table is invisible to the app role.
DO $$ BEGIN
  IF (SELECT count(*) FROM cortex.customers) <> 0 THEN RAISE EXCEPTION 'LEAK: app sees customers'; END IF;
EXCEPTION WHEN insufficient_privilege THEN NULL;   -- no grant at all is also fine
END $$;

-- 4. Same session after commit (pooled connection reuse): setting is '' now.
DO $$ BEGIN
  IF (SELECT count(*) FROM cortex.agents) <> 0 THEN RAISE EXCEPTION 'LEAK: stale tenant after commit'; END IF;
END $$;

\echo 'fail closed: OK'

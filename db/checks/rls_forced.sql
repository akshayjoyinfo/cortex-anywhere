-- CI gate: must return zero rows. Any tenant table without FORCED RLS fails the build.
SELECT c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'cortex'
  AND c.relkind = 'r'
  AND NOT (c.relrowsecurity AND c.relforcerowsecurity);

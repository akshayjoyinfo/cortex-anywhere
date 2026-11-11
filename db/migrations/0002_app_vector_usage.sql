-- 0002_app_vector_usage.sql
-- 0001 revoked schema public from PUBLIC. pgvector lives in public, so cortex_app
-- lost the vector type ("type vector does not exist"; field test 2026-11-11).
-- Grant USAGE only: the app resolves the type and operators, but cannot create objects.
BEGIN;
GRANT USAGE ON SCHEMA public TO cortex_app;
COMMIT;

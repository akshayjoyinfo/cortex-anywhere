-- The app role must be able to use the vector type and its operators.
-- Guards against schema privileges that hide the extension from cortex_app.
\set ON_ERROR_STOP on
SET ROLE cortex_app;
SELECT '[1,2,3]'::vector <=> '[1,2,4]'::vector AS cosine_distance;
RESET ROLE;

-- Listing of what the migration actually created: constraints and indexes per table.
\pset footer off
\echo '=== tables'
\dt
\echo
\echo '=== constraints (PK / UNIQUE / FK / CHECK), excluding NOT NULL'
SELECT c.conrelid::regclass AS "table",
       CASE c.contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'u' THEN 'UNIQUE' WHEN 'f' THEN 'FOREIGN KEY' WHEN 'c' THEN 'CHECK' END AS kind,
       c.conname AS name,
       pg_get_constraintdef(c.oid) AS definition
  FROM pg_constraint c
 WHERE c.connamespace = 'public'::regnamespace AND c.contype IN ('p','u','f','c')
 ORDER BY 1::text, 2, 3;
\echo
\echo '=== indexes'
SELECT tablename AS "table", indexname AS name, indexdef AS definition
  FROM pg_indexes WHERE schemaname = 'public' ORDER BY tablename, indexname;
\echo
\echo '=== triggers'
SELECT event_object_table AS "table", trigger_name, event_manipulation AS event, action_timing AS timing
  FROM information_schema.triggers WHERE trigger_schema = 'public'
 ORDER BY 1, 2, 3;

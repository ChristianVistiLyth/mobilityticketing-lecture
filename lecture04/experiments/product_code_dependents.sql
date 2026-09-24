-- Read-only. What in the database still depends on tickets.product_code.
-- Run before 030, to check the lecture 3 reporting objects, and again before
-- remove_legacy.sql.

\echo '== Views and materialized views that use tickets.product_code (tracked by PostgreSQL)'
select distinct c.relname as dependent_view, c.relkind
from pg_depend d
join pg_rewrite r on r.oid = d.objid
join pg_class c on c.oid = r.ev_class
join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
where d.refobjid = 'tickets'::regclass
  and a.attname = 'product_code'
  and c.oid <> 'tickets'::regclass;

\echo '== Constraints on the column (dropped together with it)'
select c.conname, c.contype
from pg_constraint c
join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
where c.conrelid = 'tickets'::regclass
  and a.attname = 'product_code'
order by c.conname;

\echo '== Functions whose body mentions product_code (function bodies are not tracked)'
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.prosrc ilike '%product_code%';

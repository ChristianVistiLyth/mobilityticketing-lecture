-- Everything one INSERT INTO payments causes. Rolled back at the end.
--
--   sh scripts/db-reset.sh 022
--   docker compose exec -T postgres psql -U mobility -d mobility < lecture03/experiments/payment_side_effects.sql

set timezone = 'UTC';

\echo '== Triggers on payments. The internal ones are how PostgreSQL checks foreign keys.'
select t.tgname as trigger_name,
       t.tgisinternal as internal,
       coalesce(c.conname, '-') as for_constraint
from pg_trigger t
left join pg_constraint c on c.oid = t.tgconstraint
where t.tgrelid = 'payments'::regclass
order by t.tgisinternal, c.conname, t.tgname;

begin;
select pg_current_xact_id() as this_transaction;

\echo '== EXPLAIN ANALYZE executes the insert and lists every trigger that fired'
explain (analyze, costs off, timing off, summary off)
insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status, created_utc)
values ('PAY-TRACE-1', 'USER-1', 'TICKET-1', 'gateway-trace-0001', 36.00, 'DKK', 'Captured', '2026-04-29 10:00:00+00');

\echo '== Table locks now held by this transaction'
select c.relname as relation, l.mode
from pg_locks l
join pg_class c on c.oid = l.relation
join pg_namespace n on n.oid = c.relnamespace
where l.pid = pg_backend_pid()
  and l.locktype = 'relation'
  and n.nspname = 'public'
  and c.relkind in ('r', 'm')
order by c.relname, l.mode;

\echo '== Rows this transaction wrote (xmin) or locked (xmax)'
select 'payments' as table_name, id as row_key, xmin::text as xmin, xmax::text as xmax
from payments where id = 'PAY-TRACE-1'
union all
select 'daily_revenue_by_operator', operator_id || ' ' || revenue_date, xmin::text, xmax::text
from daily_revenue_by_operator
union all
select 'tickets', id, xmin::text, xmax::text from tickets where id = 'TICKET-1'
union all
select 'users', id, xmin::text, xmax::text from users where id = 'USER-1'
union all
select 'operators', id, xmin::text, xmax::text from operators where id = 'OP-METRO';

\echo '== What each report shows before commit, inside this transaction'
select 'direct query' as approach, captured_amount, captured_payments
from captured_revenue_for_day('OP-METRO', '2026-04-29')
union all
select 'trigger table', captured_amount, captured_payments
from daily_revenue_by_operator where operator_id = 'OP-METRO' and revenue_date = '2026-04-29';

rollback;

\echo '== After rollback: the payment and its summary row are gone together'
select (select count(*) from payments where id = 'PAY-TRACE-1') as trace_payments,
       (select count(*) from daily_revenue_by_operator) as summary_rows;

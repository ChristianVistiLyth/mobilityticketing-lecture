-- For the review meeting: one stale and one incorrect revenue result, compared
-- with the base-table query, and how each stored copy is corrected.
-- Both copies start correct, so the only change is one payment correction.
-- Rolled back at the end.
--
--   sh scripts/db-reset.sh 022
--   docker compose exec -T postgres psql -U mobility -d mobility < database/postgres/experiments/lecture03/stale_report_demo.sql

set timezone = 'UTC';
begin;

\echo '== Start: refresh the view and fill the trigger table from payments, so both are correct'
refresh materialized view daily_captured_revenue;
insert into daily_revenue_by_operator (operator_id, revenue_date, captured_amount, captured_payments)
select r.operator_id, p.created_utc::date, sum(p.amount), count(*)
from payments p
join tickets t on t.id = p.ticket_id
join trips tr on tr.id = t.trip_id
join routes r on r.id = tr.route_id
where p.status = 'Captured'
group by r.operator_id, p.created_utc::date;

\echo '== A failed 50 DKK metro payment is corrected to Captured'
insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status, created_utc)
values ('PAY-DEMO-1', 'USER-1', 'TICKET-1', 'gateway-demo-1', 50.00, 'DKK', 'Failed', '2026-04-29 10:05:00+00');
update payments set status = 'Captured' where id = 'PAY-DEMO-1';

\echo '== Base-table query (queries/base_revenue.sql): the authority'
select r.operator_id, p.created_utc::date as revenue_date,
       sum(p.amount) as captured_amount, count(*) as captured_payments
from payments p
join tickets t on t.id = p.ticket_id
join trips tr on tr.id = t.trip_id
join routes r on r.id = tr.route_id
where p.status = 'Captured'
group by r.operator_id, p.created_utc::date
order by r.operator_id, revenue_date;

\echo '== Materialized view: stale, changes only when refreshed'
select * from daily_captured_revenue order by operator_id, revenue_date;

\echo '== Trigger table: wrong, changes only when a captured payment is inserted'
select * from daily_revenue_by_operator order by operator_id, revenue_date;

\echo '== Refresh the view. The trigger table is still wrong'
refresh materialized view concurrently daily_captured_revenue;
select 'materialized view' as source, * from daily_captured_revenue
union all
select 'trigger table', * from daily_revenue_by_operator
order by operator_id, source;

\echo '== Rebuild the trigger table from payments'
truncate daily_revenue_by_operator;
insert into daily_revenue_by_operator (operator_id, revenue_date, captured_amount, captured_payments)
select r.operator_id, p.created_utc::date, sum(p.amount), count(*)
from payments p
join tickets t on t.id = p.ticket_id
join trips tr on tr.id = t.trip_id
join routes r on r.id = tr.route_id
where p.status = 'Captured'
group by r.operator_id, p.created_utc::date;
select * from daily_revenue_by_operator order by operator_id, revenue_date;

rollback;

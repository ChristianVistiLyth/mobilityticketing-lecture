-- All four approaches find the reporting day with created_utc::date, and that
-- cast uses the time zone of the session that runs it. 22:30 UTC on 29 April is
-- 00:30 on 30 April in Copenhagen (summer time). Rolled back at the end.
--
--   sh scripts/db-reset.sh 022
--   docker compose exec -T postgres psql -U mobility -d mobility < database/postgres/experiments/lecture03/timezone_day_boundary.sql

begin;

\echo '== Payment inserted by a session with TimeZone = Europe/Copenhagen'
set local timezone = 'Europe/Copenhagen';
insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status, created_utc)
values ('PAY-TZ-1', 'USER-1', 'TICKET-1', 'gateway-tz-0001', 36.00, 'DKK', 'Captured', '2026-04-29 22:30:00+00');

\echo '== Materialized view refreshed by a session with TimeZone = UTC'
set local timezone = 'UTC';
refresh materialized view daily_captured_revenue;

\echo '== Where each approach puts OP-METRO revenue'
select 'trigger table (Copenhagen insert)' as source, revenue_date, captured_amount, captured_payments
from daily_revenue_by_operator where operator_id = 'OP-METRO'
union all
select 'materialized view (UTC refresh)', revenue_date, captured_amount, captured_payments
from daily_captured_revenue where operator_id = 'OP-METRO'
order by source, revenue_date;

\echo '== The same function call in two sessions'
set local timezone = 'UTC';
select 'UTC' as session_time_zone, * from captured_revenue_for_day('OP-METRO', '2026-04-30');
set local timezone = 'Europe/Copenhagen';
select 'Europe/Copenhagen' as session_time_zone, * from captured_revenue_for_day('OP-METRO', '2026-04-30');

rollback;

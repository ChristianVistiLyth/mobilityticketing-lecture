-- The six cases from reporting_cases.sql, with all four approaches printed side by
-- side after each one. Values are "captured amount (captured payments)".
-- One transaction, rolled back at the end, so it can be repeated.
--
--   sh scripts/db-reset.sh 022
--   docker compose exec -T postgres psql -U mobility -d mobility < database/postgres/experiments/lecture03/reporting_comparison.sql
--
-- Do not pass ON_ERROR_STOP: steps 0a and 6 are expected to fail.

\set ON_ERROR_ROLLBACK on
set timezone = 'UTC';
begin;

create temp view revenue_comparison as
with base as (
    select r.operator_id, p.created_utc::date as revenue_date,
           sum(p.amount) as captured_amount, count(*) as captured_payments
    from payments p
    join tickets t on t.id = p.ticket_id
    join trips tr on tr.id = t.trip_id
    join routes r on r.id = tr.route_id
    where p.status = 'Captured'
    group by r.operator_id, p.created_utc::date
),
report_keys as (
    select o.id as operator_id, date '2026-04-29' as revenue_date from operators o
    union select operator_id, revenue_date from base
    union select operator_id, revenue_date from daily_captured_revenue
    union select operator_id, revenue_date from daily_revenue_by_operator
)
select k.operator_id,
       k.revenue_date,
       format('%s (%s)', to_char(coalesce(b.captured_amount, 0), 'FM99990.00'), coalesce(b.captured_payments, 0)) as direct_query,
       format('%s (%s)', to_char(f.captured_amount, 'FM99990.00'), f.captured_payments) as sql_function,
       format('%s (%s)', to_char(coalesce(m.captured_amount, 0), 'FM99990.00'), coalesce(m.captured_payments, 0)) as materialized_view,
       format('%s (%s)', to_char(coalesce(s.captured_amount, 0), 'FM99990.00'), coalesce(s.captured_payments, 0)) as trigger_table
from report_keys k
left join base b using (operator_id, revenue_date)
cross join lateral captured_revenue_for_day(k.operator_id, k.revenue_date) f
left join daily_captured_revenue m using (operator_id, revenue_date)
left join daily_revenue_by_operator s using (operator_id, revenue_date)
order by k.operator_id, k.revenue_date;

\echo '== 0a. Materialized view before its first refresh'
select * from daily_captured_revenue;

\echo '== 0b. Baseline, after one refresh of the materialized view'
refresh materialized view daily_captured_revenue;
table revenue_comparison;

\echo '== 1. Captured payment insert: PAY-CASE-CAPTURED, 36 DKK on TICKET-1 (metro)'
insert into payments (
    id, user_id, ticket_id, external_payment_reference,
    amount, currency, status, created_utc
) values (
    'PAY-CASE-CAPTURED', 'USER-1', 'TICKET-1', 'gateway-case-captured',
    36, 'DKK', 'Captured', '2026-04-29 10:00:00+00'
);
table revenue_comparison;

\echo '== 2. Failed payment insert: PAY-CASE-FAILED, 50 DKK'
insert into payments (
    id, user_id, ticket_id, external_payment_reference,
    amount, currency, status, created_utc
) values (
    'PAY-CASE-FAILED', 'USER-1', 'TICKET-1', 'gateway-case-failed',
    50, 'DKK', 'Failed', '2026-04-29 10:05:00+00'
);
table revenue_comparison;

\echo '== 3. Correction Failed -> Captured: PAY-CASE-FAILED'
update payments
set status = 'Captured'
where id = 'PAY-CASE-FAILED';
table revenue_comparison;

\echo '== 4. Correction Captured -> Refunded: PAY-CASE-CAPTURED'
update payments
set status = 'Refunded'
where id = 'PAY-CASE-CAPTURED';
table revenue_comparison;

\echo '== 5. Delete test data: PAY-CASE-FAILED'
delete from payments
where id = 'PAY-CASE-FAILED';
table revenue_comparison;

\echo '== 6. Duplicate delivery of gateway-capture-0001'
insert into payments (
    id, user_id, ticket_id, external_payment_reference,
    amount, currency, status, created_utc
) values (
    'PAY-CASE-DUPLICATE', 'USER-1', 'TICKET-1', 'gateway-capture-0001',
    36, 'DKK', 'Captured', '2026-04-29 10:10:00+00'
);
table revenue_comparison;

\echo '== 7. Rebuild both stored copies from payments'
refresh materialized view daily_captured_revenue;
truncate daily_revenue_by_operator;
insert into daily_revenue_by_operator (operator_id, revenue_date, captured_amount, captured_payments)
select r.operator_id, p.created_utc::date, sum(p.amount), count(*)
from payments p
join tickets t on t.id = p.ticket_id
join trips tr on tr.id = t.trip_id
join routes r on r.id = tr.route_id
where p.status = 'Captured'
group by r.operator_id, p.created_utc::date;
table revenue_comparison;

\echo '== 8. Case 6 again without the lecture 2 index payments_captured_reference_unique'
drop index payments_captured_reference_unique;
insert into payments (
    id, user_id, ticket_id, external_payment_reference,
    amount, currency, status, created_utc
) values (
    'PAY-CASE-DUPLICATE', 'USER-1', 'TICKET-1', 'gateway-capture-0001',
    36, 'DKK', 'Captured', '2026-04-29 10:10:00+00'
);
table revenue_comparison;

rollback;

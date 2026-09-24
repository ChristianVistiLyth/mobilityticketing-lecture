-- The obvious one-step change: swap product_code for a required product_id.
-- Disposable lab database only. Prediction and result: docs/evidence/lecture04/README.md.
-- ON_ERROR_ROLLBACK keeps the transaction going after each expected error, and
-- everything is rolled back at the end.

\set ON_ERROR_ROLLBACK on
begin;

\echo '== 1. Give products an id, then replace the ticket reference in one go'
alter table products add column id uuid not null default gen_random_uuid() unique;
alter table tickets drop column product_code;
alter table tickets add column product_id uuid not null references products (id);

\echo '== 2. Get past NOT NULL with a default'
alter table tickets add column product_id uuid not null default gen_random_uuid() references products (id);

\echo '== 3. The old application after the drop'
select id, product_code, price, currency from tickets order by id;
insert into tickets
    (id, user_id, trip_id, ticket_code, status, product_code,
     valid_from_utc, valid_to_utc, price, currency)
values
    ('LAB04-UNSAFE-1', 'USER-1', 'TRIP-M2-20260429-0800', 'LAB04-CODE-UNSAFE-1', 'Active', 'SINGLE',
     '2026-04-29 07:45:00+00', '2026-04-29 10:00:00+00', 36.00, 'DKK');

\echo '== 4. What is left to rebuild the ticket-product links from'
select * from tickets order by id;

rollback;

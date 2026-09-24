-- A ticket whose product_code says SINGLE while its product_id points at DAY,
-- written directly in SQL instead of through new_writer.sql. Run after 031.
-- Rolled back at the end.

\set ON_ERROR_ROLLBACK on
begin;

\echo '== 1. With tickets_product_pair_fk in place'
insert into tickets
    (id, user_id, trip_id, ticket_code, status, product_code, product_id,
     valid_from_utc, valid_to_utc, price, currency)
values
    ('LAB04-MISMATCH', 'USER-1', 'TRIP-M2-20260429-1200', 'LAB04-CODE-MISMATCH', 'Active', 'SINGLE',
     (select id from products where code = 'DAY'),
     '2026-04-29 11:45:00+00', '2026-04-29 14:00:00+00', 36.00, 'DKK');

\echo '== 2. With only the two single-column foreign keys'
alter table tickets drop constraint tickets_product_pair_fk;
insert into tickets
    (id, user_id, trip_id, ticket_code, status, product_code, product_id,
     valid_from_utc, valid_to_utc, price, currency)
values
    ('LAB04-MISMATCH', 'USER-1', 'TRIP-M2-20260429-1200', 'LAB04-CODE-MISMATCH', 'Active', 'SINGLE',
     (select id from products where code = 'DAY'),
     '2026-04-29 11:45:00+00', '2026-04-29 14:00:00+00', 36.00, 'DKK');

\echo '== 3. The first check in verify.sql finds it'
select t.id, t.product_code, t.product_id, p.code as code_of_product_id
from tickets t
left join products p on p.id = t.product_id
where t.product_id is null
   or p.id is null
   or t.product_code is distinct from p.code
order by t.id;

rollback;

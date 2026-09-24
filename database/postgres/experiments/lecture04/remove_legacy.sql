-- Rehearses removing tickets.product_code after 032. Run product_code_dependents.sql
-- first. Rolled back at the end.
-- products.code stays: it is still the business-facing product code.

\set ON_ERROR_ROLLBACK on
begin;
set local lock_timeout = '3s';

\echo '== 1. What leaving out CASCADE protects against: a view that still needs the column'
create view legacy_ticket_codes as select id, product_code from tickets;
alter table tickets drop column product_code;
drop view legacy_ticket_codes;

\echo '== 2. Drop the column once nothing depends on it'
alter table tickets drop column product_code;
select column_name, is_nullable
from information_schema.columns
where table_name = 'tickets' and column_name like 'product%';

\echo '== 3. The unique key that only served tickets_product_pair_fk can go too'
alter table products drop constraint products_id_code_unique;

rollback;

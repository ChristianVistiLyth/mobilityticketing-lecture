-- products.id has a default, but a default does not stop an UPDATE from changing it.
-- Run after 032. Rolled back at the end, including the role it creates.

\set ON_ERROR_ROLLBACK on
begin;

\echo '== 1. Changing the id of a product that tickets reference'
update products set id = gen_random_uuid() where code = 'DAY';

\echo '== 2. Changing the id of a product that nothing references yet'
insert into products (code, name, price, currency) values ('CHILD', 'Child single trip', 18.00, 'DKK');
update products set id = gen_random_uuid() where code = 'CHILD';

\echo '== 3. Column privileges: an application role that may edit the catalogue but not ids'
create role lab04_app nologin;
grant select, insert on products to lab04_app;
grant update (name, price, currency) on products to lab04_app;
set local role lab04_app;
update products set price = 20.00 where code = 'CHILD';
update products set id = gen_random_uuid() where code = 'CHILD';
reset role;

rollback;

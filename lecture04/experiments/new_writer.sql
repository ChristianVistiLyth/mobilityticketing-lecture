-- New application writer, used while both references exist.
-- Takes a product id and the agreed price. The product code and currency come
-- from the product row, so a caller cannot supply a code for another product.
--   -v ticket_id=... -v ticket_code=... -v product_id=<uuid> -v agreed_price=70.00
\if :{?ticket_id}
\else
\set ticket_id 'LAB04-NEW-1'
\endif
\if :{?ticket_code}
\else
\set ticket_code 'LAB04-CODE-NEW-1'
\endif
\if :{?product_id}
\else
select id as product_id from products where code = 'DAY' \gset
\endif
\if :{?agreed_price}
\else
\set agreed_price 70.00
\endif

insert into tickets
    (id, user_id, trip_id, ticket_code, status, product_id, product_code,
     valid_from_utc, valid_to_utc, price, currency)
values
    (:'ticket_id', 'USER-2', 'TRIP-5C-20260429-1700', :'ticket_code', 'Active',
     :'product_id',
     (select code from products where id = :'product_id'),
     '2026-04-29 00:00:00+00', '2026-04-30 00:00:00+00',
     :agreed_price,
     (select currency from products where id = :'product_id'));

-- Read-only checks before requiring product_id. Both queries should return no rows.

\echo '== 1. Tickets with no product id, an unknown product id, or an id and code for different products'
select t.id, t.product_code, t.product_id, p.code as code_of_product_id
from tickets t
left join products p on p.id = t.product_id
where t.product_id is null
   or p.id is null
   or t.product_code is distinct from p.code
order by t.id;

\echo '== 2. Original tickets whose product, price or currency changed (values from baseline.sql)'
with original (id, product_code, price, currency) as (
    values ('TICKET-1', 'SINGLE', 36.00, 'DKK'),
           ('TICKET-2', 'SINGLE', 36.00, 'DKK'),
           ('TICKET-3', 'DAY', 65.00, 'DKK')
)
select o.id,
       o.product_code as original_product, p.code as product_by_id,
       o.price as original_price, t.price as current_price,
       o.currency as original_currency, t.currency as current_currency
from original o
left join tickets t on t.id = o.id
left join products p on p.id = t.product_id
where t.id is null
   or p.code is distinct from o.product_code
   or t.price <> o.price
   or t.currency <> o.currency
order by o.id;

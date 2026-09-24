-- Reader after the cut-over: joins products through product_id only, so it keeps
-- working when tickets.product_code is removed.
select t.id, t.product_id, p.code as product_code, t.price, t.currency
from tickets t
join products p on p.id = t.product_id
order by t.id;

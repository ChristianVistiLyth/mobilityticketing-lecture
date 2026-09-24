-- Lecture 4, backfill: resolve product_id from product_code where it is missing.
-- Only null references are touched, so a second run changes zero rows and an id
-- that is already set is never overwritten. Prices and currencies are not read
-- or written. Safe to repeat.

update tickets t
set product_id = p.id
from products p
where t.product_id is null
  and p.code = t.product_code;

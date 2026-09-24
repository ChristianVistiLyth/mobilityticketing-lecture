-- Old application reader: uses the product code stored on the ticket.
select id, product_code, price, currency
from tickets
order by id;

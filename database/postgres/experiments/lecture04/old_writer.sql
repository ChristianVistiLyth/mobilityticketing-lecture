-- Old application writer: stores the product by code only.
-- Use new ids for each ticket: -v ticket_id=... -v ticket_code=...
\if :{?ticket_id}
\else
\set ticket_id 'LAB04-OLD-1'
\endif
\if :{?ticket_code}
\else
\set ticket_code 'LAB04-CODE-OLD-1'
\endif

insert into tickets
    (id, user_id, trip_id, ticket_code, status, product_code,
     valid_from_utc, valid_to_utc, price, currency)
values
    (:'ticket_id', 'USER-1', 'TRIP-M2-20260429-0800', :'ticket_code', 'Active', 'SINGLE',
     '2026-04-29 07:45:00+00', '2026-04-29 10:00:00+00', 36.00, 'DKK');

-- Deliberately discounted historical price, different from the catalogue.
insert into tickets
(id,user_id,trip_id,ticket_code,status,product_code,valid_from_utc,valid_to_utc,price,currency)
values ('TICKET-3','USER-1','TRIP-M2-20260429-1200','CODE-DAY-0001','Active','DAY',
'2026-04-29 00:00:00+00','2026-04-30 00:00:00+00',65.00,'DKK');

-- Read-only. Compares the stored seat counter with the tickets that hold a seat.
-- trips_reserved_seats_within_capacity only sees one trips row, so nothing keeps
-- these two numbers equal.
select tr.id as trip_id,
       tr.capacity,
       tr.reserved_seats,
       count(t.id) filter (where t.status in ('Pending', 'Active', 'Validated')) as seat_holding_tickets
from trips tr
left join tickets t on t.trip_id = tr.id
group by tr.id, tr.capacity, tr.reserved_seats
order by tr.id;

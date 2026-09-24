-- Queries 1 and 3 on a date where one route has no scheduled trips. LINE-5C's
-- trips are cancelled inside a transaction that is rolled back.
--
--   docker compose exec -T postgres psql -U mobility -d mobility < database/postgres/experiments/lecture01/zero_trip_routes.sql

\set route_id 'LINE-5C'
\set after_utc '2026-04-29T00:00:00Z'
\set service_date '2026-04-29'
begin;
update trips set status = 'Cancelled' where route_id = 'LINE-5C';

\echo '== Query 1 for LINE-5C: cancelled trips are not upcoming trips'
select t.id, t.scheduled_departure_utc, t.status
from trips t
where t.route_id = :'route_id'
  and t.status = 'Scheduled'
  and t.scheduled_departure_utc >= :'after_utc'
order by t.scheduled_departure_utc
limit 20;

\echo '== Date and status filters in the ON clause, as in queries/003_queries.sql.example'
select r.id, r.short_name, count(t.id) as scheduled_trip_count
from routes r
left join trips t
    on t.route_id = r.id
   and t.service_date = :'service_date'
   and t.status = 'Scheduled'
group by r.id, r.short_name
order by r.short_name;

\echo '== The same filters moved to WHERE'
select r.id, r.short_name, count(t.id) as scheduled_trip_count
from routes r
left join trips t
    on t.route_id = r.id
where t.service_date = :'service_date'
  and t.status = 'Scheduled'
group by r.id, r.short_name
order by r.short_name;

rollback;

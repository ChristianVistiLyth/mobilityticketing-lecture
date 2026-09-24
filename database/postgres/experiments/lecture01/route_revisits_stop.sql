-- The route_stops key identifies a position on a route, not a stop. A loop route
-- may pass the same stop twice; two stops may not share one position.
-- Rolled back at the end.
--
--   docker compose exec -T postgres psql -U mobility -d mobility < database/postgres/experiments/lecture01/route_revisits_stop.sql

\set ON_ERROR_ROLLBACK on
begin;

\echo '== LINE-5C returns to Copenhagen Central Station as its fourth stop'
insert into route_stops (route_id, stop_id, stop_sequence) values ('LINE-5C', 'STOP-CENTRAL', 4);
select * from route_stops where route_id = 'LINE-5C' order by stop_sequence;

\echo '== A second stop at the same position'
insert into route_stops (route_id, stop_id, stop_sequence) values ('LINE-5C', 'STOP-AIRPORT', 4);

rollback;
